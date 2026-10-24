// Display-only ink contrast. CNN output memory and its quantization are intact.
// Modes: 0 original; 1/2 moderate (floor16, gain4); 3 strong (floor20, gain8).
// Subtract a shared darkening amount to keep the original colour differences.
// Two stages, one pixel per clock, no DSP or line RAM.
module iris_style_ink(
 input wire clk,rst_n,i_valid,
 input wire [1:0] i_mode,
 input wire [23:0] i_rgb,
 output reg o_valid,output reg [23:0] o_rgb
);
wire [7:0] rg_min=i_rgb[23:16]<i_rgb[15:8] ? i_rgb[23:16] : i_rgb[15:8];
wire [7:0] darkest=rg_min<i_rgb[7:0] ? rg_min : i_rgb[7:0];
wire [7:0] paper=i_mode==3 ? 8'd235 : 8'd239;
wire [7:0] ink=darkest<paper ? paper-darkest : 8'd0;
reg [10:0] dark_q;
reg [23:0] rgb_q;
reg enabled_q,valid_q;
function [7:0] deepen;
 input [7:0] colour;
 input [10:0] dark;
 begin deepen=dark>=colour ? 8'd0 : colour-dark[7:0];end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  dark_q<=0;rgb_q<=0;enabled_q<=0;valid_q<=0;o_valid<=0;o_rgb<=0;
 end else begin
  dark_q<=i_mode==3 ? {ink,3'b0} : {1'b0,ink,2'b0};
  rgb_q<=i_rgb;enabled_q<=i_mode!=0;valid_q<=i_valid;
  o_valid<=valid_q;
  o_rgb<=enabled_q ? {deepen(rgb_q[23:16],dark_q),deepen(rgb_q[15:8],dark_q),deepen(rgb_q[7:0],dark_q)} : rgb_q;
 end
end
endmodule
