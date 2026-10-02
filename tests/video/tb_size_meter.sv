`timescale 1ns/1ps
module tb_size_meter;
reg clk=0,rst=0,hs=0,vs=0,de=0;
always #5 clk=~clk;
wire [11:0] w,h;
wire toggle;
video_size_meter dut(.clk(clk),.rst_n(rst),.i_hs(hs),.i_vs(vs),.i_de(de),.o_width(w),.o_height(h),.o_toggle(toggle));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
integer x,y;
initial begin
 repeat(3)tick();rst=1;vs=1;tick();vs=0;tick();
 for(y=0;y<1080;y=y+1)begin
  hs=1;
  for(x=0;x<480;x=x+1)begin de=1;tick();de=0;tick();end
  hs=0;de=0;tick();tick();
 end
 vs=1;tick();
 if(w!==1920 || h!==1080) $fatal(1,"Gapped CSI size got %0dx%0d",w,h);
 vs=0;tick();
 for(y=0;y<720;y=y+1)begin
  hs=1;de=1;repeat(320)tick();hs=0;de=0;tick();tick();
 end
 vs=1;tick();
 if(w!==1280 || h!==720) $fatal(1,"Size did not update %0dx%0d",w,h);
 $display("PASS measured resolution: gapped RAW10 1920x1080, then mode change to 1280x720");$finish;
end
endmodule
