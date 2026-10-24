//=====================================================================
// ae_uart_log: periodic ASCII status line for the AE controller.
//
//   Line (48 bytes, hex fields):
//     AE i=<init> E=<exp:3hex> G=<gain:1hex> S=<state:1hex>
//        W=<writes:2hex> T=<timeouts:2hex> L=<luma:2hex> U=<sum3:8hex> \r\n
//
//   Example: AE i=1 E=200 G=0 S=1 W=0A T=00 L=2F U=00C4A120
//   E = manual exposure (half-lines), L = live mean brightness 0..255
//
//   TX handshake with uart_tx is quirky: tx_req stays high for ~2 cycles
//   after a byte is accepted (tx_busy rises late), so presenting a byte
//   too early overwrites it before the shifter reads it. We only present
//   a byte when tx_req has been continuously high for >=6 cycles with no
//   recent FIFO / own activity (stab counter), which covers both the
//   acceptance-dip window and the FIFO in-flight-data window.
//
//   tx_gate holds off the RX-echo FIFO pops while a line is in progress
//   and is released only after the last byte's acceptance dip (tx_req
//   falling) is observed, so the final byte cannot be clobbered.
//=====================================================================

module ae_uart_log #(
    parameter [24:0] PERIOD = 25'd33554431   // 2^25-1 cycles @27 MHz = 1.24 s
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_pause, // Calibration packet owns TX; finish an active line first.

    // AE status inputs (gpio_clk_27m domain)
    input  wire        i_init,      // sensor bring-up done && id ok
    input  wire [1:0]  i_state,
    input  wire [11:0] i_exp,
    input  wire [3:0]  i_gain,
    input  wire [31:0] i_sum,
    input  wire [7:0]  i_writes,
    input  wire [7:0]  i_touts,
    input  wire [7:0]  i_luma,
    input  wire [7:0]  i_target,    // exposure-compensation target
    input wire [255:0] i_sensor_readback,
    input wire [7:0] i_cam_fps,i_wr_fps,i_hdmi_fps,
    input wire [31:0] i_byte_hz,i_cam_period,

    // uart_tx side
    input  wire        tx_req,      // from uart_tx (level, high = wants byte)
    output reg         tx_valid,    // 1-cycle data strobe
    output reg  [7:0]  tx_data,
    output wire        tx_gate,     // 1: suppress RX-echo FIFO pops
    input  wire        fifo_act     // FIFO pop or FIFO DataVal this cycle
);

localparam LEN = 8'd160;

//---------------------------------------------------------------------
// snapshot + periodic trigger
//---------------------------------------------------------------------
reg  [24:0] timer;
reg         go;               // 1-cycle start pulse

reg         snp_init;
reg  [1:0]  snp_state;
reg  [11:0] snp_exp;
reg  [3:0]  snp_gain;
reg  [31:0] snp_sum;
reg  [7:0]  snp_writes;
reg  [7:0]  snp_touts;
reg  [7:0]  snp_luma;
reg  [7:0]  snp_target;

//---------------------------------------------------------------------
// tx_req stability guard (see header)
//---------------------------------------------------------------------
reg [2:0] stab;

// activity that must be followed by >=6 quiet tx_req-high cycles
wire own_act = tx_valid;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)              stab <= 3'd0;
    else if (!tx_req)        stab <= 3'd0;   // acceptance dip resets
    else if (fifo_act)       stab <= 3'd0;
    else if (own_act)        stab <= 3'd0;
    else if (stab != 3'd7)   stab <= stab + 3'd1;
end
wire present_ok = tx_req && (stab >= 3'd6) && !tx_valid;

//---------------------------------------------------------------------
// state machine
//---------------------------------------------------------------------
localparam ST_IDLE   = 2'd0;
localparam ST_SEND   = 2'd1;
localparam ST_DRAIN  = 2'd2;

reg [1:0]  st;
reg [7:0] idx;
reg [255:0] snp_regs;
reg [7:0] snp_cam,snp_wr,snp_hdmi;
reg [31:0] snp_byte_hz,snp_period;
reg        sending;

assign tx_gate = sending;

function [7:0] hexc;
    input [3:0] v;
    begin
        hexc = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
    end
endfunction

// byte for current idx, from snapshot
reg [7:0] ch;
always @* begin
    case (idx)
        8'd0:  ch = "A";
        8'd1:  ch = "E";
        8'd2:  ch = " ";
        8'd3:  ch = "i";
        8'd4:  ch = "=";
        8'd5:  ch = snp_init ? "1" : "0";
        8'd6:  ch = " ";
        8'd7:  ch = "E";
        8'd8:  ch = "=";
        8'd9:  ch = hexc(snp_exp[11:8]);
        8'd10: ch = hexc(snp_exp[7:4]);
        8'd11: ch = hexc(snp_exp[3:0]);
        8'd12: ch = " ";
        8'd13: ch = "G";
        8'd14: ch = "=";
        8'd15: ch = hexc({3'd0, snp_gain});
        8'd16: ch = " ";
        8'd17: ch = "S";
        8'd18: ch = "=";
        8'd19: ch = hexc({2'd0, snp_state});
        8'd20: ch = " ";
        8'd21: ch = "W";
        8'd22: ch = "=";
        8'd23: ch = hexc(snp_writes[7:4]);
        8'd24: ch = hexc(snp_writes[3:0]);
        8'd25: ch = " ";
        8'd26: ch = "T";
        8'd27: ch = "=";
        8'd28: ch = hexc(snp_touts[7:4]);
        8'd29: ch = hexc(snp_touts[3:0]);
        8'd30: ch = " ";
        8'd31: ch = "L";
        8'd32: ch = "=";
        8'd33: ch = hexc(snp_luma[7:4]);
        8'd34: ch = hexc(snp_luma[3:0]);
        8'd35: ch = " ";
        8'd36: ch = "U";
        8'd37: ch = "=";
        8'd38: ch = hexc(snp_sum[31:28]);
        8'd39: ch = hexc(snp_sum[27:24]);
        8'd40: ch = hexc(snp_sum[23:20]);
        8'd41: ch = hexc(snp_sum[19:16]);
        8'd42: ch = hexc(snp_sum[15:12]);
        8'd43: ch = hexc(snp_sum[11:8]);
        8'd44: ch = hexc(snp_sum[7:4]);
        8'd45: ch = hexc(snp_sum[3:0]);
        8'd46:ch=" ";8'd47:ch="R";8'd48:ch="=";
        8'd113:ch=" ";8'd114:ch="C";8'd115:ch="=";
        8'd116:ch=hexc(snp_cam[7:4]);8'd117:ch=hexc(snp_cam[3:0]);
        8'd118:ch=" ";8'd119:ch="W";8'd120:ch="=";
        8'd121:ch=hexc(snp_wr[7:4]);8'd122:ch=hexc(snp_wr[3:0]);
        8'd123:ch=" ";8'd124:ch="H";8'd125:ch="=";
        8'd126:ch=hexc(snp_hdmi[7:4]);8'd127:ch=hexc(snp_hdmi[3:0]);
        8'd128:ch=" ";8'd129:ch="B";8'd130:ch="Y";8'd131:ch="T";8'd132:ch="E";8'd133:ch="=";
        8'd142:ch=" ";8'd143:ch="P";8'd144:ch="=";
        8'd153:ch=" ";8'd154:ch="T";8'd155:ch="=";
        8'd156:ch=hexc(snp_target[7:4]);8'd157:ch=hexc(snp_target[3:0]);
        8'd158:ch=8'h0d;8'd159:ch=8'h0a;
        default:begin
         if(idx>=49 && idx<113)ch=hexc(snp_regs[255-(idx-49)*4-:4]);
         else if(idx>=134 && idx<142)ch=hexc(snp_byte_hz[31-(idx-134)*4-:4]);
         else if(idx>=145 && idx<153)ch=hexc(snp_period[31-(idx-145)*4-:4]);
         else ch=8'h0a;
        end
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        timer     <= 25'd0;
        go        <= 1'b0;
        st        <= ST_IDLE;
        idx       <= 8'd0;
        sending   <= 1'b0;
        tx_valid  <= 1'b0;
        tx_data   <= 8'd0;
        snp_init  <= 1'b0;
        snp_state <= 2'd0;
        snp_exp   <= 12'd0;
        snp_gain  <= 4'd0;
        snp_sum   <= 32'd0;
        snp_writes<= 8'd0;
        snp_touts <= 8'd0;
        snp_luma<=8'd0;snp_regs<=0;snp_cam<=0;snp_wr<=0;snp_hdmi<=0;snp_byte_hz<=0;snp_period<=0;
        snp_target<=8'd0;
    end else begin
        tx_valid <= 1'b0;                       // default: 1-cycle strobe

        // periodic trigger
        if (timer == PERIOD) timer <= 25'd0;
        else                 timer <= timer + 25'd1;
        go <= (timer == PERIOD);

        case (st)
        ST_IDLE: begin
            if (go && present_ok && !i_pause) begin
                snp_init   <= i_init;
                snp_state  <= i_state;
                snp_exp    <= i_exp;
                snp_gain   <= i_gain;
                snp_sum    <= i_sum;
                snp_writes <= i_writes;
                snp_touts  <= i_touts;
                snp_luma <= i_luma;
                snp_target <= i_target;
                snp_regs<=i_sensor_readback;snp_cam<=i_cam_fps;snp_wr<=i_wr_fps;
                snp_hdmi<=i_hdmi_fps;snp_byte_hz<=i_byte_hz;snp_period<=i_cam_period;
                sending    <= 1'b1;             // gate FIFO pops from now
                idx        <= 8'd0;
                st         <= ST_SEND;
            end
        end

        ST_SEND: begin
            if (present_ok) begin
                tx_valid <= 1'b1;
                tx_data  <= ch;
                if (idx == LEN - 8'd1) st <= ST_DRAIN;
                else                   idx <= idx + 8'd1;
            end
        end

        ST_DRAIN: begin
            // wait for the last byte's acceptance: tx_req dips
            if (!tx_req) begin
                sending <= 1'b0;                // release FIFO gate
                st      <= ST_IDLE;
            end
        end

        default: st <= ST_IDLE;
        endcase
    end
end

endmodule
