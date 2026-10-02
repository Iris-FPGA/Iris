//=====================================================================
// osd_ae: on-screen AE status overlay, 8x16 white-on-black.
//   Message:  E=<exp 3hex>  G=<gain 1hex>  S=<state 1hex>  W=<writes 2hex>
//              L=<luma 2hex>
//   e.g.      E=200 G=0 S=1 W=0A L=2F
//   E = manual exposure (half-lines), L = live mean brightness (0..255)
//   Display domain (148.75 MHz, 1 px/clk). Inputs come from the
//   gpio_clk_27m AE domain: 2-FF synchronised each bus (values are
//   quasi-static, a torn frame is acceptable for a debug overlay).
//   Geometry / blending follow osd_fps.
//=====================================================================

module osd_ae #(
    parameter X_START = 16,
    parameter Y_START = 48,     // below the fps digits (which end ~Y=34)
    parameter PAD     = 2,
    parameter DIGIT_W = 8,
    parameter DIGIT_H = 16,
    parameter DIGIT_GAP = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_hs,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire [23:0] i_rgb,

    // AE debug bus (gpio_clk_27m domain, quasi-static)
    input  wire [11:0] i_exp,
    input  wire [3:0]  i_gain,
    input  wire [1:0]  i_state,
    input  wire [7:0]  i_writes,
    input  wire [7:0]  i_luma,      // live mean brightness 0..255

    output wire [23:0] o_rgb
);

//---------------------------------------------------------------------
// CDC (2FF per bus)
//---------------------------------------------------------------------
reg [11:0] exp_s;
reg [3:0]  gain_s;
reg [1:0]  state_s;
reg [7:0]  writes_s;
reg [7:0]  luma_s;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        exp_s <= 12'd0; gain_s <= 4'd0; state_s <= 2'd0;
        writes_s <= 8'd0; luma_s <= 8'd0;
    end else begin
        exp_s    <= i_exp;
        gain_s   <= i_gain;
        state_s  <= i_state;
        writes_s <= i_writes;
        luma_s   <= i_luma;
    end
end

//---------------------------------------------------------------------
// 5-bit glyph codes: 0-9=digit, 10-15=A-F, 16=G, 17=S, 18=W, 19='=', 20=blank
//---------------------------------------------------------------------
localparam SLOTS = 23;   // "E=xxx G=x S=x W=xx L=xx"

function [4:0] hexc5;
    input [3:0] v;
    hexc5 = {1'b0, v};         // 0..15 map straight to digit/letter codes
endfunction

function [4:0] slot_char;
    input [4:0] s;
    begin
        case (s)
            5'd0:  slot_char = 5'd14;                    // 'E'
            5'd1:  slot_char = 5'd19;                    // '='
            5'd2:  slot_char = hexc5(exp_s[11:8]);
            5'd3:  slot_char = hexc5(exp_s[7:4]);
            5'd4:  slot_char = hexc5(exp_s[3:0]);
            5'd5:  slot_char = 5'd20;                    // ' '
            5'd6:  slot_char = 5'd16;                    // 'G'
            5'd7:  slot_char = 5'd19;                    // '='
            5'd8:  slot_char = hexc5({1'b0, gain_s});
            5'd9:  slot_char = 5'd20;                    // ' '
            5'd10: slot_char = 5'd17;                    // 'S'
            5'd11: slot_char = 5'd19;                    // '='
            5'd12: slot_char = hexc5({2'd0, state_s});
            5'd13: slot_char = 5'd20;                    // ' '
            5'd14: slot_char = 5'd18;                    // 'W'
            5'd15: slot_char = 5'd19;                    // '='
            5'd16: slot_char = hexc5(writes_s[7:4]);
            5'd17: slot_char = hexc5(writes_s[3:0]);
            5'd18: slot_char = 5'd20;                    // ' '
            5'd19: slot_char = 5'd21;                    // 'L'
            5'd20: slot_char = 5'd19;                    // '='
            5'd21: slot_char = hexc5(luma_s[7:4]);
            default: slot_char = hexc5(luma_s[3:0]);
        endcase
    end
endfunction

//---------------------------------------------------------------------
// 8x16 font, top row first, bit7 = leftmost
//---------------------------------------------------------------------
function [127:0] glyph;
    input [4:0] c;
    begin
        case (c)
            5'd0:  glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,
                            8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'hE7,8'h7E,8'h3C};
            5'd1:  glyph = {8'h18,8'h38,8'h78,8'h18,8'h18,8'h18,8'h18,8'h18,
                            8'h18,8'h18,8'h18,8'h18,8'h18,8'h18,8'hFF,8'hFF};
            5'd2:  glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'h03,8'h07,8'h0E,8'h1C,
                            8'h38,8'h70,8'hE0,8'hC0,8'hC0,8'hFF,8'hFF,8'h00};
            5'd3:  glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'h03,8'h1E,8'h1E,8'h1E,
                            8'h03,8'hC3,8'hE7,8'h7E,8'h3C,8'h00,8'h00,8'h00};
            5'd4:  glyph = {8'h06,8'h0E,8'h1E,8'h36,8'h66,8'hC6,8'hFF,8'hFF,
                            8'h06,8'h06,8'h06,8'h06,8'h06,8'h06,8'h06,8'h00};
            5'd5:  glyph = {8'hFF,8'hFF,8'hC0,8'hC0,8'hFC,8'hFE,8'hC7,8'h03,
                            8'h03,8'hC3,8'hE7,8'h7E,8'h3C,8'h00,8'h00,8'h00};
            5'd6:  glyph = {8'h1E,8'h3C,8'h70,8'hE0,8'hC0,8'hFC,8'hFE,8'hC7,
                            8'hC3,8'hC3,8'hC3,8'hE7,8'h7E,8'h3C,8'h00,8'h00};
            5'd7:  glyph = {8'hFF,8'hFF,8'h03,8'h06,8'h0C,8'h0C,8'h18,8'h18,
                            8'h30,8'h30,8'h60,8'h60,8'h60,8'h60,8'h60,8'h00};
            5'd8:  glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'hC3,8'hE7,8'h7E,8'h7E,
                            8'hE7,8'hC3,8'hC3,8'hE7,8'h7E,8'h3C,8'h00,8'h00};
            5'd9:  glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'hC3,8'hE3,8'h7F,8'h3F,
                            8'h03,8'h07,8'h0E,8'h1C,8'h38,8'h70,8'hE0,8'h00};
            // A-F (hex letters)
            5'd10: glyph = {8'h18,8'h3C,8'h66,8'hC3,8'hC3,8'hC3,8'hFF,8'hFF,
                            8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'h00}; // A
            5'd11: glyph = {8'hFC,8'hFE,8'hC7,8'hC3,8'hC3,8'hC7,8'hFE,8'hFE,
                            8'hC7,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'h00}; // B
            5'd12: glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'hC3,8'hC0,8'hC0,8'hC0,
                            8'hC0,8'hC0,8'hC3,8'hC3,8'hE7,8'h7E,8'h3C,8'h00}; // C
            5'd13: glyph = {8'hF8,8'hFC,8'hDE,8'hC7,8'hC3,8'hC3,8'hC3,8'hC3,
                            8'hC3,8'hC3,8'hC3,8'hC7,8'hDE,8'hFC,8'hF8,8'h00}; // D
            5'd14: glyph = {8'hFF,8'hFF,8'hC0,8'hC0,8'hC0,8'hC0,8'hFC,8'hFC,
                            8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'hFF,8'hFF}; // E
            5'd15: glyph = {8'hFF,8'hFF,8'hC0,8'hC0,8'hC0,8'hC0,8'hFC,8'hFC,
                            8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'h00}; // F
            // G, S, W, '=', blank
            5'd16: glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,
                            8'h83,8'h83,8'hE3,8'hC3,8'hC3,8'hE7,8'h7E,8'h3C}; // G
            5'd17: glyph = {8'h3C,8'h7E,8'hE7,8'hC3,8'hC0,8'hE0,8'hF0,8'h7E,
                            8'h0F,8'h07,8'h83,8'hC3,8'hE7,8'h7E,8'h3C,8'h00}; // S
            5'd18: glyph = {8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'hC3,8'hDB,
                            8'hDB,8'hDB,8'hDB,8'hDB,8'h6E,8'h6E,8'h44,8'h00}; // W
            5'd19: glyph = {128'h000000000000FFFF0000000000000000};           // '='
            5'd21: glyph = {8'hFF,8'hFF,8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,
                            8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'hC0,8'hFF,8'hFF}; // L
            default: glyph = 128'd0;                                          // blank
        endcase
    end
endfunction

//---------------------------------------------------------------------
// active-area x/y (same rebuild as osd_fps)
//---------------------------------------------------------------------
localparam H_ACTIVE = 1920;
localparam V_ACTIVE = 1080;

reg [10:0] x_cnt;
reg [10:0] y_cnt;
reg        de_d, vs_d;
wire de_fall = ~i_de & de_d;
wire vs_rise = i_vs & ~vs_d;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        x_cnt <= 11'd0; y_cnt <= 11'd0; de_d <= 1'b0; vs_d <= 1'b0;
    end else begin
        de_d <= i_de;
        vs_d <= i_vs;
        if (vs_rise) y_cnt <= 11'd0;
        else if (de_fall && y_cnt < V_ACTIVE - 1) y_cnt <= y_cnt + 1'b1;
        if (vs_rise) x_cnt <= 11'd0;
        else if (!i_de) x_cnt <= 11'd0;
        else if (x_cnt < H_ACTIVE - 1) x_cnt <= x_cnt + 1'b1;
    end
end

//---------------------------------------------------------------------
// window + glyph hit test
//---------------------------------------------------------------------
localparam SLOTS_W = SLOTS * (DIGIT_W + DIGIT_GAP) - DIGIT_GAP;
localparam WIN_W   = SLOTS_W + 2 * PAD;
localparam WIN_H   = DIGIT_H + 2 * PAD;
localparam WIN_X0  = X_START - PAD;
localparam WIN_Y0  = Y_START - PAD;

wire in_backdrop = (x_cnt >= WIN_X0) && (x_cnt < WIN_X0 + WIN_W) &&
                    (y_cnt >= WIN_Y0) && (y_cnt < WIN_Y0 + WIN_H);
wire in_row = (y_cnt >= Y_START) && (y_cnt < Y_START + DIGIT_H);

// which slot (if any) and column within it:
// col_ofs / 9 via repeated subtract (18 slots max)
wire [10:0] col_ofs = x_cnt - X_START[10:0];
wire [10:0] row_ofs = y_cnt - Y_START[10:0];

reg [4:0] slot_q;
reg [2:0] slot_c;
integer k;
reg [10:0] rem;
always @* begin
    slot_q = 5'd0;
    slot_c = 3'd0;
    rem    = 11'd0;
    if (in_row && x_cnt >= X_START[11:0] && x_cnt < X_START[11:0] + SLOTS_W[11:0]) begin
        rem = col_ofs;
        for (k = 0; k < SLOTS; k = k + 1) begin
            if (rem >= (DIGIT_W + DIGIT_GAP)) begin
                rem = rem - (DIGIT_W + DIGIT_GAP);
                slot_q = slot_q + 5'd1;
            end
        end
        slot_c = rem[2:0];
    end
end

wire glyph_hit = in_row && (x_cnt >= X_START[11:0]) &&
                 (x_cnt < X_START[11:0] + SLOTS_W[11:0]);

wire [4:0] code_at = slot_char(slot_q);
wire [127:0] bits_at = glyph(code_at);
wire [3:0] row_i = row_ofs[3:0];
wire [7:0] row_bits = bits_at[127 - {row_i, 3'b000} -: 8];
wire pixel_on = glyph_hit && (row_bits[3'd7 - slot_c] == 1'b1);

assign o_rgb = in_backdrop ? (pixel_on ? 24'hFFFFFF : 24'h000000) : i_rgb;

endmodule
