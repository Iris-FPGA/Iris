// INT8 model output -> clipped, nearest-integer RGB uint8.
// Input memory order is INT8 R,G,B,dummy; output bus order is RGB [23:0].
// Scale and zero point follow the model export. Legacy defaults are retained.
// Two registered stages, one pixel per clock; negative values clamp to zero.
module iris_style_dequant #(
    parameter [25:0] SCALE_Q24 = 26'd20591742,
    parameter integer ZERO_POINT = -128
)(
    input wire clk, rst_n,
    input wire i_valid, input wire [31:0] i_rgba,
    output reg o_valid, output reg [23:0] o_rgb
);
reg valid_q;
reg [34:0] red_q, green_q, blue_q;
function [8:0] positive_delta;
    input [7:0] code;
    reg signed [9:0] delta;
    begin
        delta=$signed(code)-ZERO_POINT;
        positive_delta=delta<0 ? 9'd0 : delta[8:0];
    end
endfunction
wire [8:0] red_u=positive_delta(i_rgba[7:0]);
wire [8:0] green_u=positive_delta(i_rgba[15:8]);
wire [8:0] blue_u=positive_delta(i_rgba[23:16]);
function [7:0] clip;
    input [34:0] value;
    clip = |value[34:32] ? 8'd255 : value[31:24];
endfunction
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_q <= 0; o_valid <= 0;
        red_q <= 0; green_q <= 0; blue_q <= 0; o_rgb <= 0;
    end else begin
        valid_q <= i_valid; o_valid <= valid_q;
        red_q <= red_u * SCALE_Q24 + 35'd8388608;
        green_q <= green_u * SCALE_Q24 + 35'd8388608;
        blue_q <= blue_u * SCALE_Q24 + 35'd8388608;
        o_rgb <= {clip(red_q),clip(green_q),clip(blue_q)};
    end
end
endmodule
