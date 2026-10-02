//=====================================================================
// ae_ctrl: MANUAL (fixed) exposure control for SC431HAI.
//
//   No automatic loop: exposure is a fixed register value that the
//   user raises / lowers with two board keys (active-low, debounced
//   pulses from key_pulse):
//     i_exp_up -> exp_val += EXP_STEP   (clamped to EXP_MAX)
//     i_exp_dn -> exp_val -= EXP_STEP   (clamped to EXP_MIN)
//   Gain is written once to a known 1.0x at bring-up and never touched
//   again (sensor gain defaults are not published).
//
//   Key pulses that arrive while a write sequence is in flight are
//   latched (req_up/req_dn) and consumed on the next S_EVAL, so no
//   press is lost. At a clamped limit the request is dropped without
//   touching the bus (no pointless writes while holding the key).
//
//   Writes go through the shared I2C byte engine as a 3rd requester
//   (i2c_subsystem): group-hold wrapped sequences
//     exposure: 0x3812=00 | 3e00,3e01,3e02 | 0x3812=30   (5 writes)
//     gain    : 0x3812=00 | 3e08,3e09      | 0x3812=30   (4 writes, boot)
//   Write results take effect frame N+2 (datasheet 2.4.2).
//
//   The per-frame luma sum from awb_stats is still sampled (2FF toggle
//   handshake from the 74.375 MHz display domain) and exported via
//   dbg_sum purely as a brightness readout for OSD / UART logging.
//=====================================================================

module ae_ctrl #(
    parameter [31:0] NPX       = 640 * 720,  // frame size (docs only)
    parameter [11:0] EXP_INIT  = 12'd512,    // matches ROM 0x3e00-02 = 00/20/00
    parameter [11:0] EXP_STEP  = 12'd32,     // half-lines per key press
    parameter [11:0] EXP_MAX   = 12'd2289,   // 2*VTS-11, VTS = 1150
    parameter [11:0] EXP_MIN   = 12'd4
)(
    input  wire        clk,          // 27 MHz (I2C / gpio_clk_27m domain)
    input  wire        rst_n,
    input  wire        init_done,    // ROM table done && sensor id ok

    // statistics from awb_stats domain (74.375 MHz) -- readout only
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

    // manual exposure adjust (debounced key pulses)
    input  wire        i_exp_up,     // 1-cycle: raise exposure by EXP_STEP
    input  wire        i_exp_dn,     // 1-cycle: lower exposure by EXP_STEP

    // debug / OSD outputs (this clock domain, quasi-static)
    output wire [1:0]  dbg_state,    // S_INIT/S_EVAL/S_ISSUE/S_WAIT
    output wire [11:0] dbg_exp,      // current exposure (half-lines)
    output wire [3:0]  dbg_gain,     // gain LUT index (fixed at 0 = 1.0x)
    output wire [31:0] dbg_sum,      // last latched sum3 (brightness)
    output wire [7:0]  dbg_writes,   // completed write sequences
    output wire [7:0]  dbg_touts     // sequence timeouts
);

//---------------------------------------------------------------------
// sequence / FSM state
//---------------------------------------------------------------------
localparam [1:0] S_INIT  = 2'd0;   // wait for sensor bring-up, then gain 1.0x
localparam [1:0] S_EVAL  = 2'd1;   // consume pending key requests
localparam [1:0] S_ISSUE = 2'd2;   // wait bus idle, pulse ae_wr_en
localparam [1:0] S_WAIT  = 2'd3;   // wait ae_done / timeout

reg [1:0]  st;
reg [2:0]  seq_pos;                // current entry within the sequence
reg [2:0]  seq_len;                // 5 (exposure) or 4 (gain)
reg        seq_gain;               // 1 = gain sequence
reg [19:0] to_cnt;                 // ~19.4 ms write timeout @27 MHz

reg [31:0] luma_sum;               // sum3 latched per frame (readout)
reg [2:0]  tgl_sync;

reg [11:0] exp_val;                // current exposure, half-lines
reg [3:0]  gain_idx;               // index into the ANA gain LUT
reg [7:0]  n_writes;               // completed sequences
reg [7:0]  n_touts;                // timed-out sequences
reg        req_up, req_dn;         // latched key requests

wire stats_evt = tgl_sync[2] ^ tgl_sync[1];

assign dbg_state  = st;
assign dbg_exp    = exp_val;
assign dbg_gain   = gain_idx;
assign dbg_sum    = luma_sum;
assign dbg_writes = n_writes;
assign dbg_touts  = n_touts;

//---------------------------------------------------------------------
// ANA gain LUT (datasheet table 2-7) -- only index 0 (1.0x) is ever
// used in manual mode; the rest kept for future manual-gain support.
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
            // Sensor exposure is {3e00[3:0],3e01,3e02[7:4]} in half-lines.
            // exp_val is 12 bits: its upper nibble belongs in 3e01,
            // while 3e00 must be zero. The old packing multiplied it by 16.
            3'd1: begin wr_addr_c = 16'h3e00; wr_data_c = 8'h00;              end
            3'd2: begin wr_addr_c = 16'h3e01; wr_data_c = exp_val[11:4];       end
            3'd3: begin wr_addr_c = 16'h3e02; wr_data_c = {exp_val[3:0], 4'h0};   end
            default: begin wr_addr_c = 16'h3812; wr_data_c = 8'h30;              end
        endcase
    end
end
assign ae_addr = wr_addr_c;
assign ae_data = wr_data_c;

//---------------------------------------------------------------------
// main FSM (single block owns req_up/req_dn: no multi-driver)
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
        tgl_sync <= 3'b000;
        req_up   <= 1'b0;
        req_dn   <= 1'b0;
    end else begin
        //--- stats CDC (2FF toggle sync); readout only ---
        tgl_sync <= {tgl_sync[1:0], stats_tgl};
        if (stats_evt)
            luma_sum <= sum_r + {sum_g, 1'b0} + sum_b;

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
            // consume a pending key request (up has priority)
            if (req_up) begin
                req_up <= 1'b0;
                if (exp_val < EXP_MAX) begin
                    exp_val  <= (exp_val > EXP_MAX - EXP_STEP) ? EXP_MAX
                                                               : exp_val + EXP_STEP;
                    seq_gain <= 1'b0;
                    seq_len  <= 3'd5;
                    seq_pos  <= 3'd0;
                    ae_req   <= 1'b1;
                    to_cnt   <= 20'd0;
                    st       <= S_ISSUE;
                end
            end else if (req_dn) begin
                req_dn <= 1'b0;
                if (exp_val > EXP_MIN) begin
                    exp_val  <= (exp_val < EXP_MIN + EXP_STEP) ? EXP_MIN
                                                               : exp_val - EXP_STEP;
                    seq_gain <= 1'b0;
                    seq_len  <= 3'd5;
                    seq_pos  <= 3'd0;
                    ae_req   <= 1'b1;
                    to_cnt   <= 20'd0;
                    st       <= S_ISSUE;
                end
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
                    ae_req   <= 1'b0;
                    n_writes <= n_writes + 8'd1;
                    st       <= S_EVAL;
                end else begin
                    seq_pos <= seq_pos + 3'd1;
                    st      <= S_ISSUE;
                end
            end else if (to_cnt == 20'hFFFFF) begin
                // ~19.4 ms without completion: give up on this sequence
                ae_req  <= 1'b0;
                n_touts <= n_touts + 8'd1;
                st      <= S_EVAL;
            end
        end

        default: st <= S_INIT;
        endcase

        //--- latch key pulses (after the case: a pulse coinciding with
        //    a consume is kept, presses are never lost) ---
        if (i_exp_up) req_up <= 1'b1;
        if (i_exp_dn) req_dn <= 1'b1;
    end
end

endmodule
