`timescale 1ns/1ps
module tb_style_fps;
reg core_clk=0,video_clk=0,rst=0,pulse=0,vs=0,de=0;
always #5 core_clk=~core_clk;
always #7 video_clk=~video_clk;
wire [7:0] fps;
wire update;
fps_counter #(.CLK_FREQ_HZ(1000)) counter(
 .clk(core_clk),.rst_n(rst),.frame_pulse(pulse),.fps(fps),.upd_toggle(update));
wire [23:0] rgb;
osd_video_status #(.ENABLE_STYLE_FPS(1)) dut(
 .clk(video_clk),.rst_n(rst),.i_hs(1'b0),.i_vs(vs),.i_de(de),.i_rgb(24'h123456),
 .i_cam_width(12'd1920),.i_cam_height(12'd1080),.i_cam_toggle(1'b1),
 .i_hdmi_width(12'd1920),.i_hdmi_height(12'd1080),
 .i_cam_fps(8'd60),.i_wr_fps(8'd60),.i_hdmi_fps(8'd60),
 .i_cam_fps_upd(1'b1),.i_wr_fps_upd(1'b1),.i_hdmi_fps_upd(1'b1),
 .i_style_fps(fps),.i_style_fps_upd(update),.i_wb_locked(1'b1),.i_black_g(8'd0),.o_rgb(rgb));
task vstep;begin @(posedge video_clk);#1;@(negedge video_clk);end endtask
integer k,x,y,white,black;
reg last_update;
initial begin
 repeat(4)vstep();@(negedge core_clk);rst=1;
 last_update=update;
 // Fifteen fresh commits, each held high for three cycles. HDMI remains 60.
 for(k=0;k<1000;k=k+1)begin
  pulse=(k>=30 && k<873 && (k-30)%60<3);
  @(posedge core_clk);#1;@(negedge core_clk);
 end
 pulse=0;
 if(update===last_update || fps!==15)$fatal(1,"Fresh-frame gate must count 15 commits, got %0d",fps);
 repeat(8)vstep();vs=1;vstep();vs=0;repeat(125)vstep();
 if(dut.digits[8]!==16'h0015 || dut.digits[6]!==16'h0060)
  $fatal(1,"AI and HDMI FPS were conflated or lost crossing clocks");
 white=0;black=0;
 for(y=0;y<161;y=y+1)begin
  de=1;
  for(x=0;x<384;x=x+1)begin
   #1;
   if(y>=144 && y<160 && x>=16 && x<352)begin
    if(rgb==24'hffffff)white=white+1;
    else if(rgb==0)black=black+1;
    else $fatal(1,"AI FPS glyph invalid");
   end else if(y>=128 && rgb!==24'h123456)$fatal(1,"AI FPS changed pixels outside its row");
   vstep();
  end
  de=0;vstep();vstep();
 end
 if(white<100 || black<100)$fatal(1,"AI FPS row is empty");
 // Rendering elapsed several gates with no commits; the rate must reach zero.
 if(fps!==0)$fatal(1,"Frozen content incorrectly retained a nonzero rate");
 repeat(8)vstep();vs=1;vstep();vs=0;repeat(125)vstep();
 if(dut.digits[8]!==0 || dut.digits[6]!==16'h0060)$fatal(1,"AI freeze did not show zero independently of HDMI");
 $display("PASS: fresh AI FPS 15 vs HDMI 60, held pulses, CDC, glyphs and freeze-to-zero");$finish;
end
endmodule
