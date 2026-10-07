`timescale 1ns/1ps
module tb_style_panels #(parameter NEGATIVE=0);
reg clk=0,video_clk=0,rst_n=0;
always #5 clk=~clk;
always #7 video_clk=~video_clk;
reg commit_toggle=0,commit_pair=0,i_hs=0,i_vs=0,i_de=0;
reg [47:0] i_rgb=48'h123456abcdef;
wire commit_ack,active_pair,have_frame,o_hs,o_vs,o_de,arvalid,rready;
wire [47:0] o_rgb;wire [31:0] underflows,read_errors,araddr;wire [7:0] arlen;
reg arready=0,rvalid=0,rlast=0;reg [1:0] rresp=0;reg [127:0] rdata=0;
iris_style_panels dut(.*);
integer cyc=0,beat=0,burst_len=0;reg servicing=0;
reg [31:0] address;
function [7:0] colour(input integer y,input integer x,input integer c,input integer style,input integer pair);
 colour=(y*3+x*7+c*43+style*31+pair*23)%256;
endfunction
function [127:0] memory_word(input reg [31:0] a);
 integer offset,pair,style,y,x;
 reg [127:0] v;
 begin
  style=a>=32'h03400000;
  pair=(a & 32'h00200000)!=0;
  offset=a-(style ? 32'h03400000 : 32'h03000000)-(pair ? 32'h00200000 : 0);
  y=offset/2560;x=(offset%2560)/4;v=0;
  for(integer p=0;p<4;p=p+1)begin
   for(integer c=0;c<3;c=c+1)v[p*32+c*8+:8]=colour(y,x+p,c,style,pair)^8'h80;
   v[p*32+24+:8]=8'h80;
  end
  memory_word=v;
 end
endfunction
always @(posedge clk)begin
 if(!rst_n)begin arready<=0;rvalid<=0;servicing<=0;cyc<=0;end
 else begin
  cyc<=cyc+1;arready<=!servicing && cyc%7!=0;
  if(arvalid && arready)begin
   if(servicing || arlen>127 || ((araddr%4096)+(arlen+1)*16)>4096)$fatal(1,"AXI boundary");
   address<=araddr;burst_len<=arlen;beat<=0;servicing<=1;rvalid<=0;
  end
  if(rvalid && rready)begin
   rvalid<=0;
   if(rlast)servicing<=0;
   else begin beat<=beat+1;address<=address+16;end
  end
  if(servicing && !rvalid && cyc%5!=0)begin
   rdata<=memory_word(address);rvalid<=1;rlast<=beat==burst_len;
   rresp<=NEGATIVE && address==32'h03006400 ? 2'b10 : 0;
  end
 end
end
integer tx=0,ty=0,checked=0;
reg [50:0] ref0=0,ref1=0,ref2=0;
reg check_enable=0;
function [23:0] rgb(input integer y,input integer x,input integer style,input integer pair);
 integer val;reg [23:0] v;
 begin
  v=0;
  for(integer c=0;c<3;c=c+1)begin
   val=colour(y,x,c,style,pair);
   if(style)begin val=$rtoi(val*1.2273634672164917+0.5);if(val>255)val=255;end
   v={v[15:0],8'(val)};
  end
  rgb=v;
 end
endfunction
reg [47:0] expected;
always @(posedge video_clk)begin
 expected=i_rgb;
 if(i_de && ty>=300 && ty<780)begin
  if(tx>=160 && tx<800)expected={rgb(ty-300,tx-160,0,commit_pair),rgb(ty-300,tx-159,0,commit_pair)};
  if(tx>=1120 && tx<1760)expected={rgb(ty-300,tx-1120,1,commit_pair),rgb(ty-300,tx-1119,1,commit_pair)};
  if(NEGATIVE && commit_pair==0 && ty==310 && ((tx>=160 && tx<800) || (tx>=1120 && tx<1760)))expected=0;
 end
 ref0<={i_hs,i_vs,i_de,expected};ref1<=ref0;ref2<=ref1;
end
always @(negedge video_clk)if(check_enable)begin
 if({o_hs,o_vs,o_de,o_rgb}!==ref2)$fatal(1,"panel mismatch tx=%d ty=%d got=%h ref=%h",tx,ty,{o_hs,o_vs,o_de,o_rgb},ref2);
 if(o_de)checked=checked+1;
end
task frame;
 begin
  for(integer v=0;v<1125;v=v+1)begin
   for(integer h=0;h<1100;h=h+1)begin
    @(negedge video_clk);
    i_vs=v<5;i_hs=h<22;i_de=v>=45 && v<1125 && h>=74 && h<1034;
    tx=(h-74)*2;ty=v-45;
   end
  end
 end
endtask
initial begin
 repeat(4)@(negedge clk);rst_n=1;commit_toggle=1;
 repeat(8)@(negedge video_clk);
 check_enable=1;frame();
 if(!have_frame || commit_ack!=commit_toggle || underflows!=NEGATIVE || read_errors!=NEGATIVE)$fatal(1,"ready/errors %d/%d",underflows,read_errors);
 commit_pair=1;commit_toggle=0;
 // The pair change is requested in blanking before the next VS; preserve
 // the old mailbox until the display acknowledges the new frame boundary.
 check_enable=0;i_de=0;i_vs=0;repeat(8)@(negedge video_clk);
 check_enable=1;frame();
 if(active_pair!=1 || underflows!=NEGATIVE || read_errors!=NEGATIVE)$fatal(1,"pair transition");
 $display("PASS style panels: %d two-pixel samples, RGB/dequant, 4K bursts, full-frame pairing",checked);$finish;
end
initial begin #50000000;$fatal(1,"panel timeout");end
endmodule
