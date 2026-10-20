`timescale 1ns/1ps
module tb_style_fractional;
reg clk=0,rst_n=0,vs=0,de=0,upd=0;reg [11:0] rate=0;
always #5 clk=~clk;
wire [23:0] rgb;
osd_video_status #(.ENABLE_STYLE_FPS(1),.STYLE_FRACTIONAL(1)) dut(
 .clk(clk),.rst_n(rst_n),.i_hs(1'b0),.i_vs(vs),.i_de(de),.i_rgb(24'h123456),
 .i_cam_width(12'd1920),.i_cam_height(12'd1080),.i_cam_toggle(1'b1),
 .i_hdmi_width(12'd1920),.i_hdmi_height(12'd1080),
 .i_cam_fps(8'd60),.i_wr_fps(8'd60),.i_hdmi_fps(8'd60),
 .i_cam_fps_upd(1'b1),.i_wr_fps_upd(1'b1),.i_hdmi_fps_upd(1'b1),
 .i_style_fps(8'd0),.i_style_fps_upd(1'b0),.i_style_centifps(rate),.i_style_rate_upd(upd),
 .i_wb_locked(1'b1),.i_black_g(8'd0),.o_rgb(rgb));
task update_rate;
 input [11:0] value;
 begin
  @(negedge clk);rate=value;upd=~upd;repeat(8)@(negedge clk);
  vs=1;repeat(4)@(negedge clk);vs=0;repeat(130)@(negedge clk);
 end
endtask
integer x,y,dots=0,rate_pixels=0;
initial begin
 repeat(4)@(negedge clk);rst_n=1;
 update_rate(22);
 if(dut.digits[8]!==16'h0022 || dut.digits[6]!==16'h0060)$fatal(1,"AI 0.22 vs HDMI 60 not preserved");
 for(y=0;y<161;y=y+1)begin
  de=1;
  for(x=0;x<384;x=x+1)begin
   #1;
   if(y>=144 && y<160 && x>=16 && x<352)begin
    if(rgb!=0 && rgb!=24'hffffff)$fatal(1,"invalid rate glyph");
    if(rgb==24'hffffff)rate_pixels=rate_pixels+1;
    if(dut.slot==5)begin
     if(dut.ch!=".")$fatal(1,"decimal point missing");
     if(rgb==24'hffffff)dots=dots+1;
    end
   end
   @(negedge clk);
  end
  de=0;repeat(2)@(negedge clk);
 end
 if(dots==0 || rate_pixels<100)$fatal(1,"fractional row is blank");
 update_rate(1678);if(dut.digits[8]!==16'h1678)$fatal(1,"16.78 FPS failed");
 update_rate(0);if(dut.digits[8]!==0)$fatal(1,"stopped AI did not reach zero");
 $display("PASS fractional AI FPS: 0.22/16.78/0.00, decimal glyph, CDC and independent HDMI 60");$finish;
end
endmodule
