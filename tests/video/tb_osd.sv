`timescale 1ns/1ps
module tb_osd;
reg clk=0,rst=0,vs=0,de=0,toggle=0;
always #5 clk=~clk;
wire [23:0] out;
osd_video_status dut(.clk(clk),.rst_n(rst),.i_hs(1'b0),.i_vs(vs),.i_de(de),.i_rgb(24'h123456),
 .i_cam_width(12'd1920),.i_cam_height(12'd1080),.i_cam_toggle(toggle),
 .i_hdmi_width(12'd1920),.i_hdmi_height(12'd1080),
 .i_cam_fps(8'd60),.i_wr_fps(8'd59),.i_hdmi_fps(8'd60),
 .i_cam_fps_upd(toggle),.i_wr_fps_upd(toggle),.i_hdmi_fps_upd(toggle),.o_rgb(out));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
integer x,y,white,black;
initial begin
 repeat(4)tick();rst=1;toggle=1;repeat(10)tick();vs=1;tick();vs=0;repeat(100)tick();
 if(dut.digits[0]!==16'h1920 || dut.digits[1]!==16'h1080 || dut.digits[2]!==16'h0060 || dut.digits[3]!==16'h0059 || dut.digits[4]!==16'h1920 || dut.digits[5]!==16'h1080 || dut.digits[6]!==16'h0060)
  $fatal(1,"OSD BCD/snapshot mismatch");
 white=0;black=0;
 for(y=0;y<100;y=y+1)begin
  de=1;
  for(x=0;x<384;x=x+1)begin
   #1;
   if((y>=16&&y<32||y>=80&&y<96)&&x>=16&&x<352)begin
    if(out==24'hffffff)white=white+1;
    else if(out==0)black=black+1;
    else $fatal(1,"Overlay glyph invalid");
   end else if(out!==24'h123456)$fatal(1,"OSD altered image outside window x=%0d y=%0d",x,y);
   tick();
  end
  de=0;#1;
  if(out!==24'h123456)$fatal(1,"OSD altered blanking");
  tick();tick();
 end
 if(white<100 || black<100)$fatal(1,"OSD empty");
 $display("PASS OSD: actual 1920x1080 and independent CAM/WR/HDMI FPS, glyphs and passthrough");$finish;
end
endmodule
