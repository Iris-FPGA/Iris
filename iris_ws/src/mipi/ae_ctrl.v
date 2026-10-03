//=====================================================================
// ae_ctrl: auto exposure for SC431HAI (the sensor has no on-chip AEC)
//   with P-mode style EXPOSURE COMPENSATION on the board keys.
//
//   Statistics: per-frame R/G/B sums from awb_stats (74.375 MHz).
//   A toggle in the stats clock domain marks "sums latched at VS";
//   this module (27 MHz, same domain as the I2C core) re-synchronises
//   the toggle (2FF) and samples the sums (quasi-static all frame).
//
//   Mean luma  = sum3 / (4*NPX),  sum3 = sum_r + 2*sum_g + sum_b.
//   Compared against thr_r = target * 4 * NPX without a divider.
//
//   Control law (guide 8.4: exposure first, gain only at the limit):
//     too dark : exp += step   (until EXP_MAX, then gain index +1)
//     too bright: exp -= step   (until EXP_MIN, then gain index -1)
//   step = clamp(exp>>4, 8, 128)  (~6.25% of current exposure,
//   below 2x the 5% dead-band -> no limit-cycle flicker).
//
//   Exposure compensation (keys, like camera P-mode EV):
//     i_tgt_up -> target_q += 4   (brighter image target)
//     i_tgt_dn -> target_q -= 4
//   target_q in [16,200] (init TARGET=72); thr_r mirrors it via
//   +/-THR_STEP so no multiplier is needed at runtime.
//
//   Writes go through the shared I2C byte engine as a 3rd requester
//   (i2c_subsystem): group-hold wrapped sequences
//     exposure: 0x3812=00 | 3e00,3e01,3e02 | 0x3812=30   (5 writes)
//     gain    : 0x3812=00 | 3e08,3e09      | 0x3812=30   (4 writes)
//   After boot an explicit 1.0x gain write runs once (sensor gain
//   defaults are not published, so make them known).
//
//   Write results take effect frame N+2 (datasheet 2.4.2); HOLDOFF
//   skips that many stats events after each sequence before re-evaluating.
//=====================================================================

module ae_ctrl #(
    parameter [31:0] NPX       = 640 * 720,  // DE pixels per frame
    parameter [7:0]  TARGET    = 8'd72,       // INITIAL target mean luma (0..255);
                                              // runtime EV-comp via i_tgt_up/dn
    parameter [3:0]  HOLDOFF   = 4'd3,        // stats events skipped after a write
    parameter [11:0] EXP_INIT  = 12'd512,     // matches ROM 0x3e00-02 = 00/20/00
    parameter [11:0] EXP_MAX   = 12'd2289,    // 2*VTS-11, VTS = 1150
    parameter [11:0] EXP_MIN   = 12'd4
)(
    input  wire        clk,          // 27 MHz (I2C / gpio_clk_27m domain)
    input  wire        rst_n,
    input  wire        init_done,    // ROM table done && sensor id ok

    // statistics from awb_stats domain (74.375 MHz)
    input  wire        stats_tgl,    // toggles once per frame at VS
    input  wire [31:0] sum_r,
    input  wire [31:0] sum_g,
    input  wire [31:0] sum_b,

    // register-write port into i2c_subsystem (3rd requester)
    output reg         ae_req,       // held high for the whole sequence
    output reg         ae_wr_en,     // 1-cycle pulse per register write
    output wire [15:0] ae_addr,      // stable while ae_req
    output wire [7:0]  ae_data,      // stable while ae_req
    input  wire        ae_busy,      // ROM / ID transaction in flight
    input  wire        ae_done,      // one write completed (pulse)

    // exposure-compensation adjust (debounced key pulses)
    input  wire        i_tgt_up,     // 1-cycle: raise target by TGT_STEP
    input  wire        i_tgt_dn,     // 1-cycle: lower target by TGT_STEP

    // debug / OSD outputs (this clock domain, quasi-static)
    output wire [1:0]  dbg_state,    // S_INIT/S_EVAL/S_ISSUE/S_WAIT
    output wire [11:0] dbg_exp,      // current exposure (half-lines)
    output wire [3:0]  dbg_gain,     // gain LUT index
    output wire [31:0] dbg_sum,      // last latched sum3
    output wire [7:0]  dbg_writes,   // completed write sequences
    output wire [7:0]  dbg_touts,    // sequence timeouts
    output wire [7:0]  dbg_target    // current exposure-comp target luma
);

//---------------------------------------------------------------------
// thresholds: runtime-adjustable (EV comp keys), thr_r updated by
// +/-THR_STEP so no runtime multiplier is needed
//   THR_UNIT = 4*NPX, thr_r = target * 4 * NPX
//   (reset value folds TARGET * THR_UNIT at elaboration time)
//---------------------------------------------------------------------
localparam [31:0] THR_UNIT = 32'd4 * NPX;
localparam [31:0] THR_STEP = THR_UNIT * 32'd4;   // +/-4 target units / press
localparam [7:0]  TGT_STEP = 8'd4;
localparam [7:0]  TGT_MIN  = 8'd16;
localparam [7:0]  TGT_MAX  = 8'd200;

reg [7:0]  target_q;                // current target luma (EV comp value)
reg [31:0] thr_r;                   // target * 4 * NPX

assign dbg_target = target_q;

reg [31:0] luma_sum;               // sum3 latched per frame
wire [31:0] dead_r = thr_r >> 5;    // dead-band = 5% of target
wire too_dark   = luma_sum < (thr_r - dead_r);
wire too_bright = luma_sum > (thr_r + dead_r);

//---------------------------------------------------------------------
// sequence / FSM state
//---------------------------------------------------------------------
localparam [1:0] S_INIT  = 2'd0;   // wait for sensor bring-up, then gain 1.0x
localparam [1:0] S_EVAL  = 2'd1;   // decide next action
localparam [1:0] S_ISSUE = 2'd2;   // wait bus idle, pulse ae_wr_en
localparam [1:0] S_WAIT  = 2'd3;   // wait ae_done / timeout

reg [1:0]  st;
reg [2:0]  seq_pos;                // current entry within the sequence
reg [2:0]  seq_len;                // 5 (exposure) or 4 (gain)
reg        seq_gain;               // 1 = gain sequence
reg [19:0] to_cnt;                 // ~19.4 ms write timeout @27 MHz

reg        pending;                // fresh stats available
reg [3:0]  holdoff;
reg [2:0]  tgl_sync;

reg [11:0] exp_val;                // current exposure, half-lines
reg [3:0]  gain_idx;               // index into the ANA gain LUT
reg [7:0]  n_writes;               // completed sequences
reg [7:0]  n_touts;                // timed-out sequences

wire stats_evt = tgl_sync[2] ^ tgl_sync[1];

assign dbg_state  = st;
assign dbg_exp    = exp_val;
assign dbg_gain   = gain_idx;
assign dbg_sum    = luma_sum;
assign dbg_writes = n_writes;
assign dbg_touts  = n_touts;

// step = clamp(exp>>4, 8, 128)  (6.25% of current exposure)
wire [11:0] step_raw = exp_val >> 4;
wire [11:0] step     = (step_raw < 12'd8)   ? 12'd8 :
                       (step_raw > 12'd128) ? 12'd128 : step_raw;

//---------------------------------------------------------------------
// ANA gain LUT (datasheet table 2-7, ~x1.3-1.5 per step)
//---------------------------------------------------------------------
reg [7:0] lut_ana, lut_fine;
always @* begin
    case (gain_idx)
        4'd0:  begin lut_ana = 8'h00; lut_fine = 8'h20; end //  1.000x
        4'd1:  begin lut_ana = 8'h00; lut_fine = 8'h30; end //  1.500x
        4'd2:  begin lut_ana = 8'h80; lut_fine = 8'h2A; end //  2.021x
        4'd3:  begin lut_ana = 8'h80; lut_fine = 8'h34; end //  2.503x
        4'd4:  begin lut_ana = 8'h81; lut_fine = 8'h20; end //  3.080x
        4'd5:  begin lut_ana = 8'h81; lut_fine = 8'h2A; end //  4.043x
        4'd6:  begin lut_ana = 8'h81; lut_fine = 8'h3F; end //  6.064x
        4'd7:  begin lut_ana = 8'h83; lut_fine = 8'h2A; end //  8.085x
        4'd8:  begin lut_ana = 8'h83; lut_fine = 8'h3F; end // 12.128x
        4'd9:  begin lut_ana = 8'h87; lut_fine = 8'h2A; end // 16.170x
        4'd10: begin lut_ana = 8'h8F; lut_fine = 8'h20; end // 24.640x
        4'd11: begin lut_ana = 8'h8F; lut_fine = 8'h2A; end // 32.340x
        4'd12: begin lut_ana = 8'h8F; lut_fine = 8'h3F; end // 48.510x
        default: begin lut_ana = 8'h00; lut_fine = 8'h20; end
    endcase
end
localparam [3:0] GAIN_MAX = 4'd12;

//---------------------------------------------------------------------
// sequence entry decode (combinational; the inputs only change at
// safe points, so ae_addr/ae_data are stable for the whole transaction)
//---------------------------------------------------------------------
reg [15:0] wr_addr_c;
reg [7:0]  wr_data_c;
always @* begin
    if (seq_pos == 3'd0) begin
        wr_addr_c = 16'h3812;
        wr_data_c = 8'h00;                        // group hold start
    end else if (seq_gain) begin
        if (seq_pos == 3'd1) begin
            wr_addr_c = 16'h3e08;
            wr_data_c = lut_ana;
        end else if (seq_pos == 3'd2) begin
            wr_addr_c = 16'h3e09;
            wr_data_c = lut_fine;
        end else begin                            // seq_pos == 3
            wr_addr_c = 16'h3812;
            wr_data_c = 8'h30;                    // group hold release
        end
    end else begin
        case (seq_pos)
            3'd1: begin wr_addr_c = 16'h3e00; wr_data_c = 8'h00; end
            3'd2: begin wr_addr_c = 16'h3e01; wr_data_c = exp_val[11:4];          end
            3'd3: begin wr_addr_c = 16'h3e02; wr_data_c = {exp_val[3:0], 4'h0};   end
            default: begin wr_addr_c = 16'h3812; wr_data_c = 8'h30;              end
        endcase
    end
end
assign ae_addr = wr_addr_c;
assign ae_data = wr_data_c;

//---------------------------------------------------------------------
// main FSM (single block owns pending/holdoff/target_q/thr_r:
// no multi-driver)
//---------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st       <= S_INIT;
        ae_req   <= 1'b0;
        ae_wr_en <= 1'b0;
        exp_val  <= EXP_INIT;
        gain_idx <= 4'd0;
        n_writes <= 8'd0;
        n_touts  <= 8'd0;
        seq_pos  <= 3'd0;
        seq_len  <= 3'd4;
        seq_gain <= 1'b1;
        to_cnt   <= 20'd0;
        luma_sum <= 32'd0;
        pending  <= 1'b0;
        holdoff  <= 4'd0;
        tgl_sync <= 3'b000;
        target_q <= TARGET;
        thr_r    <= TARGET * THR_UNIT;           // constant-folded
    end else begin
        //--- stats CDC (2FF toggle sync) ---
        tgl_sync <= {tgl_sync[1:0], stats_tgl};
        if (stats_evt) begin
            luma_sum <= sum_r + {sum_g, 1'b0} + sum_b;
            pending  <= 1'b1;
            if (holdoff != 4'd0) holdoff <= holdoff - 4'd1;
        end

        //--- exposure compensation (key pulses): thr_r mirrors target_q ---
        if (i_tgt_up && (target_q <= TGT_MAX - TGT_STEP)) begin
            target_q <= target_q + TGT_STEP;
            thr_r    <= thr_r + THR_STEP;
        end else if (i_tgt_dn && (target_q >= TGT_MIN + TGT_STEP)) begin
            target_q <= target_q - TGT_STEP;
            thr_r    <= thr_r - THR_STEP;
        end

        ae_wr_en <= 1'b0;                          // default: 1-cycle pulse

        case (st)
        //---------------------------------------------------------
        S_INIT: begin
            // explicit 1.0x gain write once the sensor is up
            if (init_done) begin
                ae_req   <= 1'b1;
                seq_gain <= 1'b1;
                seq_len  <= 3'd4;
                seq_pos  <= 3'd0;
                to_cnt   <= 20'd0;
                st       <= S_ISSUE;
            end
        end

        //---------------------------------------------------------
        S_EVAL: begin
            if (init_done && pending && holdoff == 4'd0) begin
                if (too_dark) begin
                    if (exp_val < EXP_MAX) begin
                        exp_val  <= (exp_val > EXP_MAX - step) ? EXP_MAX
                                                               : exp_val + step;
                        seq_gain <= 1'b0;
                        seq_len  <= 3'd5;
                        seq_pos  <= 3'd0;
                        ae_req   <= 1'b1;
                        pending  <= 1'b0;
                        to_cnt   <= 20'd0;
                        st       <= S_ISSUE;
                    end else if (gain_idx < GAIN_MAX) begin
                        gain_idx <= gain_idx + 4'd1;
                        seq_gain <= 1'b1;
                        seq_len  <= 3'd4;
                        seq_pos  <= 3'd0;
                        ae_req   <= 1'b1;
                        pending  <= 1'b0;
                        to_cnt   <= 20'd0;
                        st       <= S_ISSUE;
                    end
                end else if (too_bright) begin
                    if (exp_val > EXP_MIN) begin
                        exp_val  <= (exp_val < EXP_MIN + step) ? EXP_MIN
                                                               : exp_val - step;
                        seq_gain <= 1'b0;
                        seq_len  <= 3'd5;
                        seq_pos  <= 3'd0;
                        ae_req   <= 1'b1;
                        pending  <= 1'b0;
                        to_cnt   <= 20'd0;
                        st       <= S_ISSUE;
                    end else if (gain_idx > 4'd0) begin
                        gain_idx <= gain_idx - 4'd1;
                        seq_gain <= 1'b1;
                        seq_len  <= 3'd4;
                        seq_pos  <= 3'd0;
                        ae_req   <= 1'b1;
                        pending  <= 1'b0;
                        to_cnt   <= 20'd0;
                        st       <= S_ISSUE;
                    end
                end
                // inside the dead-band: keep pending, re-check next frame
            end
        end

        //---------------------------------------------------------
        S_ISSUE: begin
            if (!ae_busy) begin
                ae_wr_en <= 1'b1;                  // 1-cycle pulse
                to_cnt   <= 20'd0;
                st       <= S_WAIT;
            end
        end

        //---------------------------------------------------------
        S_WAIT: begin
            to_cnt <= to_cnt + 20'd1;
            if (ae_done) begin
                if (seq_pos + 3'd1 >= seq_len) begin
                    ae_req  <= 1'b0;
                    holdoff <= HOLDOFF;
                    n_writes <= n_writes + 8'd1;
                    st      <= S_EVAL;
                end else begin
                    seq_pos <= seq_pos + 3'd1;
                    st      <= S_ISSUE;
                end
            end else if (to_cnt == 20'hFFFFF) begin
                // ~19.4 ms without completion: give up on this sequence
                ae_req  <= 1'b0;
                holdoff <= HOLDOFF;
                n_touts <= n_touts + 8'd1;
                st      <= S_EVAL;
            end
        end

        default: st <= S_INIT;
        endcase
    end
end

endmodule
