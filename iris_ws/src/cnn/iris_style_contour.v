// Hybrid display: smoothed camera contours guide unmodified neural colours.
// The 5x5 gradient is Gaussian3 convolved with Sobel3, normalized by 16.
// Six clocks from the two-pixel RAM stream; borders replicate endpoints.
module iris_style_contour #(parameter [24:0] SCALE_Q24=25'd20596120)(
 input wire clk,rst_n,i_valid,i_first,i_last,
 input wire [1:0] i_mode,
 input wire [79:0] i_grey_rows,
 input wire [63:0] i_neural_rgba,
 output reg o_valid,output reg [47:0] o_rgb
);
reg [79:0] pair_q,left_q,previous;
reg pair_valid,first_q,last_q;
reg signed [10:0] dx0[0:4],dx1[0:4];
reg [11:0] smooth0[0:4],smooth1[0:4];
reg signed [14:0] gx0,gx1,gy0,gy1;
reg [14:0] magnitude0,magnitude1;
reg [7:0] ink0,ink1;
reg [3:0] valid_pipe;
wire [47:0] dequant;
wire dv0,dv1;
iris_style_dequant #(.SCALE_Q24(SCALE_Q24)) d0(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_rgba(i_neural_rgba[31:0]),.o_valid(dv0),.o_rgb(dequant[47:24]));
iris_style_dequant #(.SCALE_Q24(SCALE_Q24)) d1(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_rgba(i_neural_rgba[63:32]),.o_valid(dv1),.o_rgb(dequant[23:0]));
reg [47:0] colour_pipe[0:2];
function signed [10:0] derivative;
 input [7:0] a,b,d,e;
 begin derivative=($signed({1'b0,e})-$signed({1'b0,a}))+2*($signed({1'b0,d})-$signed({1'b0,b}));end
endfunction
function [11:0] smooth;
 input [7:0] a,b,c,d,e;
 begin smooth={4'd0,a}+({4'd0,b}<<2)+({4'd0,c}<<2)+({4'd0,c}<<1)+({4'd0,d}<<2)+{4'd0,e};end
endfunction
function signed [14:0] weighted;
 input signed [10:0] a,b,c,d,e;
 reg signed [14:0] aa,bb,cc,dd,ee;
 begin
  aa=a;bb=b;cc=c;dd=d;ee=e;
  weighted=aa+(bb<<<2)+(cc<<<2)+(cc<<<1)+(dd<<<2)+ee;
 end
endfunction
function signed [14:0] vertical;
 input [11:0] a,b,d,e;
 reg signed [14:0] aa,bb,dd,ee;
 begin aa={1'b0,a};bb={1'b0,b};dd={1'b0,d};ee={1'b0,e};vertical=ee-aa+((dd-bb)<<<1);end
endfunction
function [14:0] absolute;
 input signed [14:0] v;
 begin absolute=v<0 ? -v : v;end
endfunction
function [7:0] strength;
 input [14:0] magnitude;
 input [1:0] mode;
 reg [11:0] grad;
 begin
  grad=({1'b0,magnitude}+16'd8)>>4;
  if(mode==3)strength=grad<=40 ? 0 : grad>=80 ? 160 : (grad-40)<<2;
  else strength=grad<=32 ? 0 : grad>=96 ? 128 : (grad-32)<<1;
 end
endfunction
function [23:0] render;
 input [23:0] rgb;
 input [7:0] ink;
 input [1:0] mode;
 reg [7:0] minimum;
 integer dark,base,value,ch;
 begin
  minimum=rgb[23:16]<rgb[15:8] ? rgb[23:16] : rgb[15:8];
  if(rgb[7:0]<minimum)minimum=rgb[7:0];
  dark=minimum<239 ? (239-minimum)*4 : 0;
  base=255-((255-minimum+2)>>2);
  for(ch=0;ch<3;ch=ch+1)begin
   value=rgb[ch*8+:8];
   if(mode==1)value=value-dark;
   else if(mode>=2)begin
    value=base+value-minimum;
    if(value>255)value=255;
    value=value-ink;
   end
   render[ch*8+:8]=value<0 ? 0 : value;
  end
 end
endfunction
integer row;
reg [7:0] a,b,c,d,e,f;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  pair_q<=0;left_q<=0;previous<=0;pair_valid<=0;first_q<=0;last_q<=0;
  valid_pipe<=0;o_valid<=0;o_rgb<=0;
  gx0<=0;gx1<=0;gy0<=0;gy1<=0;magnitude0<=0;magnitude1<=0;ink0<=0;ink1<=0;
  for(row=0;row<5;row=row+1)begin dx0[row]<=0;dx1[row]<=0;smooth0[row]<=0;smooth1[row]<=0;end
  for(row=0;row<3;row=row+1)colour_pipe[row]<=0;
 end else begin
  pair_valid<=i_valid;pair_q<=i_grey_rows;left_q<=previous;first_q<=i_first;last_q<=i_last;
  if(i_valid)previous<=i_grey_rows;
  for(row=0;row<5;row=row+1)begin
   c=pair_q[row*16+:8];d=pair_q[row*16+8+:8];
   a=first_q ? c : left_q[row*16+:8];b=first_q ? c : left_q[row*16+8+:8];
   e=last_q ? d : i_grey_rows[row*16+:8];f=last_q ? d : i_grey_rows[row*16+8+:8];
   dx0[row]<=derivative(a,b,d,e);smooth0[row]<=smooth(a,b,c,d,e);
   dx1[row]<=derivative(b,c,e,f);smooth1[row]<=smooth(b,c,d,e,f);
  end
  gx0<=weighted(dx0[0],dx0[1],dx0[2],dx0[3],dx0[4]);
  gx1<=weighted(dx1[0],dx1[1],dx1[2],dx1[3],dx1[4]);
  gy0<=vertical(smooth0[0],smooth0[1],smooth0[3],smooth0[4]);
  gy1<=vertical(smooth1[0],smooth1[1],smooth1[3],smooth1[4]);
  magnitude0<=absolute(gx0)+absolute(gy0);magnitude1<=absolute(gx1)+absolute(gy1);
  ink0<=strength(magnitude0,i_mode);ink1<=strength(magnitude1,i_mode);
  colour_pipe[0]<=dequant;colour_pipe[1]<=colour_pipe[0];colour_pipe[2]<=colour_pipe[1];
  o_rgb<={render(colour_pipe[2][47:24],ink0,i_mode),render(colour_pipe[2][23:0],ink1,i_mode)};
  valid_pipe<={valid_pipe[2:0],pair_valid};o_valid<=valid_pipe[3];
 end
end
endmodule
