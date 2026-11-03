// INT8 model output -> clipped, nearest-integer RGB uint8.
// Input memory order is INT8 R,G,B,dummy; output bus order is RGB [23:0].
// Scale and zero point follow the model export. Dynamically configured per model.
// Two registered stages, one pixel per clock; negative values clamp to zero.
module iris_style_dequant (
    input wire clk, rst_n,
    input wire [25:0] scale_q24,
    input wire signed [8:0] zero_point,
    input wire i_valid, input wire [31:0] i_rgba,
    output reg o_valid, output reg [23:0] o_rgb
);
reg valid_q;
reg [34:0] red_q, green_q, blue_q;
function [8:0] positive_delta;
    input [7:0] code;
    input signed [8:0] zp;
    reg signed [9:0] delta;
    begin
        delta=$signed({code[7],code})-zp;
        positive_delta=delta<0 ? 9'd0 : delta[8:0];
    end
endfunction
wire [8:0] red_u=positive_delta(i_rgba[7:0],zero_point);
wire [8:0] green_u=positive_delta(i_rgba[15:8],zero_point);
wire [8:0] blue_u=positive_delta(i_rgba[23:16],zero_point);
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
        red_q <= red_u * scale_q24 + 35'd8388608;
        green_q <= green_u * scale_q24 + 35'd8388608;
        blue_q <= blue_u * scale_q24 + 35'd8388608;
        o_rgb <= {clip(red_q),clip(green_q),clip(blue_q)};
    end
end
endmodule
