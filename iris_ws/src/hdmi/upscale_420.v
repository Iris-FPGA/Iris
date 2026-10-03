// 1920x1080p30 RGB -> 3840x2160p30 YCbCr420 at the same 148.75 MHz
// TMDS word clock used by 1080p60. Source active pixels arrive at one/clk;
// source lines are 4400 clocks long. Output lines are 2200 clocks long.
// Each source pixel becomes a 2x2 block: two identical Y samples per word,
// Cb on the first row and Cr on the second. Only two source lines are stored.
// One source-line delay ensures both repeated rows read a completed bank.
module upscale_420 #(
 parameter HA=1920,HT=2200,HS=44,HB=148,
 parameter VA=1080,VT=1125,VS=5,VB=36
)(input clk,rst_n,enable,i_hs,i_vs,i_de,input [23:0] i_rgb,
 output reg o_hs,o_vs,o_de,output reg [23:0] o_channels,
 output reg [11:0] o_x,o_y,output reg o_started);
localparam YBEGIN=2*(VS+VB),HBEGIN=HS+HB;
reg [23:0] line0[0:HA-1],line1[0:HA-1];
wire converted_de;wire [23:0] ycc;
rgb_to_ycbcr709 convert(.clk(clk),.rst_n(rst_n&&enable),.i_de(i_de),.i_rgb(i_rgb),
 .o_de(converted_de),.o_ycc(ycc));
reg vs_d,de_d,write_bank,completed_bank,completed_valid,read_bank,line_valid;
reg [11:0] wx,wrow,completed_row,h,v;
reg [23:0] read0,read1;
wire [23:0] read_pixel=read_bank?read1:read0;
wire vs_edge=i_vs&&!vs_d;
wire [11:0] read_address=(h>=HBEGIN-1&&h<HBEGIN+HA-1)?h-(HBEGIN-1):0;
wire active_v=v>=YBEGIN&&v<YBEGIN+2*VA;
wire [11:0] row=(v-YBEGIN)>>1;
always @(posedge clk)begin
 if(enable && converted_de && wx<HA)begin
  if(write_bank)line1[wx]<=ycc;else line0[wx]<=ycc;
 end
 // Separate registered ports infer block RAM; a mux inside the read register
 // would cause Efinity to implement both lines in flip-flops instead.
 read0<=line0[read_address];read1<=line1[read_address];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  vs_d<=0;de_d<=0;write_bank<=0;completed_bank<=0;completed_valid<=0;
  read_bank<=0;line_valid<=0;wx<=0;wrow<=0;completed_row<=0;
  h<=0;v<=0;o_hs<=0;o_vs<=0;o_de<=0;o_channels<=0;o_x<=0;o_y<=0;o_started<=0;
 end else begin
  vs_d<=i_vs;de_d<=converted_de;
  o_x<=h;o_y<=v;o_hs<=o_started&&h<HS;o_vs<=o_started&&v<2*VS;
  // Keep DE timing intact on missing data, but substitute limited-range black.
  o_de<=o_started&&active_v&&h>=HBEGIN&&h<HBEGIN+HA;
  o_channels<=line_valid ? {read_pixel[23:16],read_pixel[23:16],
    (v[0]?read_pixel[7:0]:read_pixel[15:8])} : 24'h101080;
  if(!enable)begin
   o_started<=0;o_de<=0;o_hs<=0;o_vs<=0;
   wx<=0;wrow<=0;completed_valid<=0;line_valid<=0;write_bank<=0;
  end else begin
   if(vs_edge)begin
    // Start two output lines before the next VS: exactly 4400 word clocks.
    h<=0;v<=2*VT-2;o_started<=1;wx<=0;wrow<=0;completed_valid<=0;
   end else if(o_started)begin
    if(h==HT-1)begin h<=0;v<=(v==2*VT-1)?0:v+1'b1;end
    else h<=h+1'b1;
   end
   if(converted_de)wx<=wx+1'b1;
   if(de_d&&!converted_de)begin
    wx<=0;wrow<=wrow+1'b1;
    if(wx==HA)begin
     completed_bank<=write_bank;completed_row<=wrow;completed_valid<=1;
     write_bank<=~write_bank;
    end
   end
   if(h==HBEGIN-2 && active_v && !v[0])begin
    read_bank<=completed_bank;
    line_valid<=completed_valid&&completed_row==row;
   end
  end
 end
end
endmodule
