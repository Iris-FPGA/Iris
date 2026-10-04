`timescale 1ns/1ps
module tb_upscale_420;
reg clk=0;always #5 clk=~clk;
reg rst=0,ena=0,hs=0,vs=0,de=0;reg [23:0] rgb=0;
wire oh,ov,od,started;wire [23:0] channels;wire [11:0] ox,oy;
localparam HA=16,HT=24,HS=4,HB=4,VA=8,VT=12,VS=1,VB=1;
upscale_420 #(.HA(HA),.HT(HT),.HS(HS),.HB(HB),.VA(VA),.VT(VT),.VS(VS),.VB(VB)) dut
 (.clk(clk),.rst_n(rst),.enable(ena),.i_hs(hs),.i_vs(vs),.i_de(de),.i_rgb(rgb),
 .o_hs(oh),.o_vs(ov),.o_de(od),.o_channels(channels),.o_x(ox),.o_y(oy),.o_started(started));
function [23:0] pixel;
 input integer x,y,f;
 begin pixel={8'(20+x*9+f*7),8'(30+y*20),8'(220-x*7-y*3)};end
endfunction
function [23:0] reference;
 input [23:0] p;input integer odd;
 integer r,g,b,y,u,v;
 begin
  r=p[23:16];g=p[15:8];b=p[7:0];
  y=16+(47*r+157*g+16*b+128)/256;
  u=128+(-26*r-87*g+113*b+128)/256;
  // Signed division truncates differently; use positive biased numerators.
  u=(32896-26*r-87*g+113*b)/256;if(u>240)u=240;if(u<16)u=16;
  v=(32896+112*r-102*g-10*b)/256;
  reference={8'(y),8'(y),8'(odd?v:u)};
 end
endfunction
integer f,x,y,count,oframe=-1,frames=0,words=0,last_hs=-1,cycle=0;
reg ov_d=0,oh_d=0;reg checking=0;reg [23:0] expected;
always @(negedge clk)begin
 if(rst&&ena&&checking)begin
  if(ov&&!ov_d)begin
   if(oframe>=0 && words!=2*HA*VA)$fatal(1,"frame words %0d",words);
   oframe=oframe+1;words=0;frames=frames+1;
  end
  if(oh&&!oh_d)begin
   if(last_hs>=0&&cycle-last_hs!=HT)$fatal(1,"line period %0d",cycle-last_hs);
   last_hs=cycle;
  end
  if(od)begin
   if(ox<HS+HB||ox>=HS+HB+HA||oy<2*(VS+VB)||oy>=2*(VS+VB+VA))$fatal(1,"raster bounds");
   expected=reference(pixel(ox-HS-HB,(oy-2*(VS+VB))/2,oframe),oy[0]);
   if(channels!==expected)$fatal(1,"420 x=%0d y=%0d f=%0d got=%h expected=%h valid=%b row=%0d",ox,oy,oframe,channels,expected,dut.line_valid,dut.completed_row);
   words=words+1;
  end
  ov_d=ov;oh_d=oh;cycle=cycle+1;
 end
end
initial begin
 repeat(5)@(negedge clk);rst=1;ena=1;checking=1;
 for(f=0;f<4;f=f+1)for(y=0;y<VT;y=y+1)for(x=0;x<2*HT;x=x+1)begin
  hs=x<HS;vs=y<VS;de=y>=VS+VB&&y<VS+VB+VA&&x>=HS+HB&&x<HS+HB+HA;
  rgb=de?pixel(x-HS-HB,y-VS-VB,f):0;@(negedge clk);
 end
 if(frames<3)$fatal(1,"missing output frames");
 checking=0;ena=0;repeat(10)@(negedge clk);
 if(od||started)$fatal(1,"mode disable did not clear output");
 // Re-enable mid-frame: output must wait for the next actual VS edge.
 vs=0;ena=1;repeat(40)@(negedge clk);
 if(started||od)$fatal(1,"mode enable used stale frame");
 $display("PASS 420 upscale: complete frames, 2x2 pixels, Cb/Cr row order, exact word/line counts, stale-frame suppression");$finish;
end
endmodule
