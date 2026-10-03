//=====================================================================
// key_pulse: active-low push-button to single-cycle pulse converter.
//   - 2FF synchroniser (async pad)
//   - 20 ms stability debounce
//   - 1-cycle pulse on press (debounced falling edge, active-low)
//   - auto-repeat: another pulse every REP_MS while held
//   Reference: official key_detect.v (15 ms, release-side); this module
//   fires on press instead and adds hold-repeat for value sweeping.
//=====================================================================

module key_pulse #(
    parameter CLK_HZ = 27_000_000,
    parameter DEB_MS = 20,
    parameter REP_MS = 250
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,     // async pad, pressed = 0 (external pull-up)
    output reg  pulse       // 1-cycle
);

localparam DEB_CNT = CLK_HZ / 1000 * DEB_MS;   // 540_000
localparam REP_CNT = CLK_HZ / 1000 * REP_MS;   // 6_750_000

//---------------------------------------------------------------------
// 2FF synchroniser
//---------------------------------------------------------------------
reg [1:0] sync;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sync <= 2'b11;                 // idle = released (high)
    else        sync <= {sync[0], key_in};
end
wire key_s = sync[1];

//---------------------------------------------------------------------
// debounce: accept a new level only after DEB_CNT stable samples
//---------------------------------------------------------------------
reg        stable;          // debounced level (1 = released)
reg [19:0] db_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stable <= 1'b1;
        db_cnt <= 20'd0;
    end else if (key_s == stable) begin
        db_cnt <= 20'd0;
    end else if (db_cnt == DEB_CNT - 1) begin
        stable <= key_s;
        db_cnt <= 20'd0;
    end else begin
        db_cnt <= db_cnt + 20'd1;
    end
end

wire pressed  = ~stable;
reg  pressed_d;
wire press_edge = pressed & ~pressed_d;

//---------------------------------------------------------------------
// press pulse + hold repeat
//---------------------------------------------------------------------
reg [22:0] rep_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pressed_d <= 1'b0;
        rep_cnt   <= 23'd0;
        pulse     <= 1'b0;
    end else begin
        pressed_d <= pressed;
        if (press_edge) begin
            pulse   <= 1'b1;
            rep_cnt <= 23'd0;
        end else if (pressed && REP_MS > 0 && (rep_cnt == REP_CNT - 1)) begin
            pulse   <= 1'b1;
            rep_cnt <= 23'd0;
        end else begin
            pulse   <= 1'b0;
            if (!pressed) rep_cnt <= 23'd0;
            else          rep_cnt <= rep_cnt + 23'd1;
        end
    end
end

endmodule
