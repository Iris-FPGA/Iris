// Student output q=-128..127 -> clipped, nearest-integer RGB uint8.
// Input memory order is INT8 R,G,B,dummy; output bus order is RGB [23:0].
// Scale is the exported model's 1.2273634672164917, represented in Q24.
// Zero point is -128. Two registered stages, one pixel per clock.
module iris_style_dequant #(
    parameter [24:0] SCALE_Q24 = 25'd20591742
)(
    input wire clk, rst_n,
    input wire i_valid, input wire [31:0] i_rgba,
    output reg o_valid, output reg [23:0] o_rgb
);
reg valid_q;
reg [32:0] red_q, green_q, blue_q;
wire [7:0] red_u = i_rgba[7:0] ^ 8'h80;
wire [7:0] green_u = i_rgba[15:8] ^ 8'h80;
wire [7:0] blue_u = i_rgba[23:16] ^ 8'h80;
function [7:0] clip;
    input [32:0] value;
    clip = value[32] ? 8'd255 : value[31:24];
endfunction
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_q <= 0; o_valid <= 0;
        red_q <= 0; green_q <= 0; blue_q <= 0; o_rgb <= 0;
    end else begin
        valid_q <= i_valid; o_valid <= valid_q;
        red_q <= red_u * SCALE_Q24 + 33'd8388608;
        green_q <= green_u * SCALE_Q24 + 33'd8388608;
        blue_q <= blue_u * SCALE_Q24 + 33'd8388608;
        o_rgb <= {clip(red_q),clip(green_q),clip(blue_q)};
    end
end
endmodule
