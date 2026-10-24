// Native camera RGB denoising, before white balance/gamma and AI sampling.
// One light 3x3 binomial convolution, no tensor-resolution blur or frame store.
// Two pixels/clock, RGB0 in [47:24]. Replicate all four image boundaries.
// A complete raster-line delay permits flushing the bottom row in blanking.
module camera_denoise_2px #(
 parameter H_TOTAL=1100,parameter H_ACTIVE=960,parameter V_ACTIVE=1080
)(
 input wire clk,rst_n,i_hs,i_vs,i_de,input wire [47:0] i_rgb,
 output reg o_hs,o_vs,o_de,output reg [47:0] o_rgb
);
localparam XW=$clog2(H_ACTIVE),TW=$clog2(H_TOTAL);
(* syn_ramstyle="block_ram" *) reg [47:0] row1[0:H_ACTIVE-1],row2[0:H_ACTIVE-1];
reg [47:0] row1_q,row2_q;
// Registered read plus H_TOTAL-1 entries gives exactly H_TOTAL cycles.
// A synchronous read is required for the control delay to use block RAM.
reg [2:0] raster[0:H_TOTAL-2];
reg [2:0] raster_q;
reg [TW-1:0] raster_addr;
reg [TW:0] raster_fill;
wire [2:0] delayed=raster_fill<H_TOTAL ? 3'b000 : raster_q;
reg [XW-1:0] x;
reg [11:0] y;
reg de_d,vs_d;
reg copy_enable;
reg [XW-1:0] copy_x;
always @(posedge clk)begin
 raster_q<=raster[raster_addr];
 if(rst_n)raster[raster_addr]<={i_hs,i_vs,i_de};
 if(i_de || delayed[0])begin row1_q<=row1[x];row2_q<=row2[x];end
 if(i_de)row1[x]<=i_rgb;
 // Copy the previous row one clock after its sole synchronous read.
 // Multiple readers with different enables would infer a register array.
 if(copy_enable)row2[copy_x]<=row1_q;
end
function [9:0] vertical;
 input [7:0] top,middle,bottom;
 begin vertical={2'b0,top}+{1'b0,middle,1'b0}+{2'b0,bottom};end
endfunction
function [7:0] horizontal;
 input [9:0] left,middle,right;
 reg [11:0] sum;
 begin sum={2'b0,left}+{1'b0,middle,1'b0}+{2'b0,right}+12'd8;horizontal=sum[11:4];end
endfunction
reg [47:0] current0;
reg top0,bottom0;
reg [59:0] vertical1,pair2;
reg [29:0] previous_left;
reg first2;
reg [2:0] hs_pipe,vs_pipe,de_pipe;
wire [47:0] top_rgb=top0 ? row1_q : row2_q;
wire [47:0] bottom_rgb=bottom0 ? row1_q : current0;
wire [29:0] left_column=first2 ? pair2[59:30] : previous_left;
wire [29:0] right_column=de_pipe[1] ? vertical1[59:30] : pair2[29:0];
integer ch,pixel;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  raster_addr<=0;raster_fill<=0;x<=0;y<=0;de_d<=0;vs_d<=0;
  copy_enable<=0;copy_x<=0;
  current0<=0;top0<=0;bottom0<=0;vertical1<=0;pair2<=0;
  previous_left<=0;first2<=1;hs_pipe<=0;vs_pipe<=0;de_pipe<=0;
  o_hs<=0;o_vs<=0;o_de<=0;o_rgb<=0;
 end else begin
  raster_addr<=raster_addr==H_TOTAL-2 ? 0 : raster_addr+1'b1;
  if(raster_fill<H_TOTAL)raster_fill<=raster_fill+1'b1;
  de_d<=i_de;vs_d<=i_vs;
  copy_enable<=i_de;copy_x<=x;
  if(i_vs && !vs_d)y<=0;
  else if(de_d && !i_de)y<=y+1'b1;
  if(i_de || delayed[0])x<=x==H_ACTIVE-1 ? 0 : x+1'b1;
  else x<=0;
  current0<=i_rgb;top0<=y==1;bottom0<=!i_de;
  hs_pipe<={hs_pipe[1:0],delayed[2]};
  vs_pipe<={vs_pipe[1:0],delayed[1]};
  de_pipe<={de_pipe[1:0],delayed[0]};
  for(pixel=0;pixel<2;pixel=pixel+1)
   for(ch=0;ch<3;ch=ch+1)
    vertical1[pixel*30+ch*10+:10]<=vertical(top_rgb[pixel*24+ch*8+:8],row1_q[pixel*24+ch*8+:8],bottom_rgb[pixel*24+ch*8+:8]);
  pair2<=vertical1;previous_left<=pair2[29:0];first2<=!de_pipe[2];
  o_hs<=hs_pipe[2];o_vs<=vs_pipe[2];o_de<=de_pipe[2];
  for(ch=0;ch<3;ch=ch+1)begin
   o_rgb[24+ch*8+:8]<=de_pipe[2] ? horizontal(left_column[ch*10+:10],pair2[30+ch*10+:10],pair2[ch*10+:10]) : 8'd0;
   o_rgb[ch*8+:8]<=de_pipe[2] ? horizontal(pair2[30+ch*10+:10],pair2[ch*10+:10],right_column[ch*10+:10]) : 8'd0;
  end
 end
end
endmodule
