// Same-colour Bayer denoising before demosaic, two pixels/clock.
// The cross uses (x+-2,y) and (x,y+-2), never neighbouring Bayer colours.
// A median5 guide replaces large impulses; a clipped cross average reduces
// smaller noise while limiting mixing across edges. No previous-frame blend.
// Input/output first pixel is [15:8]. Replicate edges within each colour plane.
module camera_raw_denoise_2px #(
 parameter H_TOTAL=1100, H_ACTIVE=960, V_ACTIVE=1080,
 parameter [7:0] IMPULSE_THRESHOLD=24, SMOOTH_LIMIT=12
)(
 input wire clk,rst_n,i_hs,i_vs,i_de,input wire [15:0] i_raw,
 output reg o_hs,o_vs,o_de,output reg [15:0] o_raw
);
localparam XW=$clog2(H_ACTIVE), TW=$clog2(2*H_TOTAL);
(* syn_ramstyle="block_ram" *) reg [15:0] row1[0:H_ACTIVE-1],row2[0:H_ACTIVE-1],
 row3[0:H_ACTIVE-1],row4[0:H_ACTIVE-1];
reg [15:0] row1_q,row2_q,row3_q,row4_q;
reg [2:0] raster[0:2*H_TOTAL-2];
reg [2:0] raster_q;
reg [TW-1:0] raster_addr;
reg [TW:0] raster_fill;
wire [2:0] delayed=raster_fill<2*H_TOTAL ? 3'b000 : raster_q;
reg [XW-1:0] x,copy_x;
reg copy_enable,delayed_de,delayed_vs;
reg [11:0] output_y;
always @(posedge clk)begin
 raster_q<=raster[raster_addr];
 if(rst_n)raster[raster_addr]<={i_hs,i_vs,i_de};
 if(i_de || delayed[0])begin
  row1_q<=row1[x];row2_q<=row2[x];row3_q<=row3[x];row4_q<=row4[x];
 end
 if(i_de)row1[x]<=i_raw;
 // Each row has exactly one synchronous reader and one writer.
 if(copy_enable)begin
  row2[copy_x]<=row1_q;row3[copy_x]<=row2_q;row4[copy_x]<=row3_q;
 end
end
reg [15:0] current0;
reg top0,tail0,last0;
wire [15:0] middle=tail0 && last0 ? row1_q : row2_q;
wire [15:0] top=top0 ? middle : tail0 && last0 ? row3_q : row4_q;
wire [15:0] bottom=tail0 ? middle : current0;
reg [15:0] north1,centre1,south1,north2,centre2,south2,west2;
reg first2;
reg [7:0] hs_pipe,vs_pipe,de_pipe;
wire [15:0] west=first2 ? centre2 : west2;
wire [15:0] east=de_pipe[1] ? centre1 : centre2;

function [7:0] min8;
 input [7:0] a,b;
 begin min8=a<b ? a : b;end
endfunction
function [7:0] max8;
 input [7:0] a,b;
 begin max8=a>b ? a : b;end
endfunction
function [7:0] median3;
 input [7:0] a,b,c;
 begin median3=a<b ? (b<c ? b : (a<c ? c : a)) :
                         (a<c ? a : (b<c ? c : b));end
endfunction
function [7:0] distance;
 input [7:0] a,b;
 begin distance=a>b ? a-b : b-a;end
endfunction
function [7:0] clipped;
 input [7:0] value,guide;
 reg [8:0] upper;
 reg [7:0] lower;
 begin
  upper={1'b0,guide}+{1'b0,SMOOTH_LIMIT};
  lower=guide<SMOOTH_LIMIT ? 8'd0 : guide-SMOOTH_LIMIT;
  clipped=value<lower ? lower : {1'b0,value}>upper ? upper[7:0] : value;
 end
endfunction
function [7:0] average;
 input [7:0] c,n,s,w,e;
 reg [10:0] sum;
 begin
  sum={1'b0,c,2'b0}+{3'b0,n}+{3'b0,s}+{3'b0,w}+{3'b0,e}+11'd4;
  average=sum[10:3];
 end
endfunction
genvar lane;
generate for(lane=0;lane<2;lane=lane+1)begin : g_lane
 wire [7:0] n=north2[lane*8+:8],s=south2[lane*8+:8];
 wire [7:0] w=west[lane*8+:8],e=east[lane*8+:8],c=centre2[lane*8+:8];
 reg [7:0] ns_min,ns_max,we_min,we_max;
 reg [7:0] c3,n3,s3,w3,e3,lo4,hi4,c4,n4,s4,w4,e4;
 reg [7:0] m5,c5,n5,s5,w5,e5;
 reg [7:0] guide6,n6,s6,w6,e6,guide7,n7,s7,w7,e7;
 always @(posedge clk)begin
  // Remove the global minimum and maximum of the four neighbours.
  // The median of the remaining two values and c is exactly median5.
  ns_min<=min8(n,s);ns_max<=max8(n,s);
  we_min<=min8(w,e);we_max<=max8(w,e);
  c3<=c;n3<=n;s3<=s;w3<=w;e3<=e;
  lo4<=max8(ns_min,we_min);hi4<=min8(ns_max,we_max);
  c4<=c3;n4<=n3;s4<=s3;w4<=w3;e4<=e3;
  m5<=median3(lo4,hi4,c4);
  c5<=c4;n5<=n4;s5<=s4;w5<=w4;e5<=e4;
  guide6<=distance(c5,m5)>IMPULSE_THRESHOLD ? m5 : c5;
  n6<=n5;s6<=s5;w6<=w5;e6<=e5;
  guide7<=guide6;
  n7<=clipped(n6,guide6);s7<=clipped(s6,guide6);
  w7<=clipped(w6,guide6);e7<=clipped(e6,guide6);
  o_raw[lane*8+:8]<=de_pipe[7] ? average(guide7,n7,s7,w7,e7) : 8'd0;
 end
end endgenerate
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  raster_addr<=0;raster_fill<=0;x<=0;copy_x<=0;copy_enable<=0;
  delayed_de<=0;delayed_vs<=0;output_y<=0;
  current0<=0;top0<=0;tail0<=0;last0<=0;
  north1<=0;centre1<=0;south1<=0;north2<=0;centre2<=0;south2<=0;west2<=0;
  first2<=1;hs_pipe<=0;vs_pipe<=0;de_pipe<=0;o_hs<=0;o_vs<=0;o_de<=0;
 end else begin
  raster_addr<=raster_addr==2*H_TOTAL-2 ? 0 : raster_addr+1'b1;
  if(raster_fill<2*H_TOTAL)raster_fill<=raster_fill+1'b1;
  copy_enable<=i_de;copy_x<=x;
  if(i_de || delayed[0])x<=x==H_ACTIVE-1 ? 0 : x+1'b1;
  else x<=0;
  delayed_de<=delayed[0];delayed_vs<=delayed[1];
  if(delayed[1] && !delayed_vs)output_y<=0;
  else if(delayed_de && !delayed[0])output_y<=output_y+1'b1;
  current0<=i_raw;top0<=output_y<2;tail0<=!i_de;last0<=output_y==V_ACTIVE-1;
  north1<=top;centre1<=middle;south1<=bottom;
  north2<=north1;centre2<=centre1;south2<=south1;west2<=centre2;
  first2<=!de_pipe[2];
  hs_pipe<={hs_pipe[6:0],delayed[2]};
  vs_pipe<={vs_pipe[6:0],delayed[1]};
  de_pipe<={de_pipe[6:0],delayed[0]};
  o_hs<=hs_pipe[7];o_vs<=vs_pipe[7];o_de<=de_pipe[7];
 end
end
endmodule
