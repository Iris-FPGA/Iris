`timescale 1ns/1ps
module tb_white_balance;
reg clk=0,rst=0,upd=0,cal=0,bcal=0;
always #5 clk=~clk;
reg [11:0] exposure=512;
reg [31:0] sr=0,sg=0,sb=0,wr=0,wg=0,wb=0;
reg [23:0] count=2073600,wcount=2073600;
wire [9:0] rg,gg,bg;
wire [7:0] br,bg0,bb;
wire locked;
awb_ctrl #(.SETTLE_FRAMES(2),.MIN_WB_PIXELS(4)) dut(
 .clk(clk),.rst_n(rst),.i_upd(upd),.i_calibrate(cal),.i_black_calibrate(bcal),.i_exposure(exposure),
 .i_sum_r(sr),.i_sum_g(sg),.i_sum_b(sb),.i_wb_r(wr),.i_wb_g(wg),.i_wb_b(wb),
 .i_pixels(count),.i_wb_pixels(wcount),.o_r_gain(rg),.o_g_gain(gg),.o_b_gain(bg),
 .o_black_r(br),.o_black_g(bg0),.o_black_b(bb),.o_locked(locked));
reg de=0,vs=0;
reg [47:0] rgb=0;
wire [31:0] tr,tg,tb,twr,twg,twb;
wire [23:0] tc,twc;
wire tu;
awb_stats stats(.clk(clk),.rst_n(rst),.i_de(de),.i_vs(vs),.i_rgb(rgb),
 .i_black_r(8'd10),.i_black_g(8'd10),.i_black_b(8'd10),
 .o_sum_r(tr),.o_sum_g(tg),.o_sum_b(tb),.o_upd(tu),
 .o_wb_r(twr),.o_wb_g(twg),.o_wb_b(twb),.o_pixels(tc),.o_wb_pixels(twc));
task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
task frame;begin upd=1;tick();upd=0;repeat(50)tick();end endtask
task request;input black;begin cal=!black;bcal=black;tick();cal=0;bcal=0;end endtask
task wait_lock;integer i;begin
 i=0;while(!locked && i<10)begin frame();i=i+1;end
 if(!locked)$fatal(1,"Calibration failed to lock state=%0d",dut.state);
end endtask
task means;input integer r,g,b;begin
 sr=r*count;sg=g*count;sb=b*count;wr=r*wcount;wg=g*wcount;wb=b*wcount;
end endtask
reg [53:0] previous;
always @(posedge clk)begin
 #1;
 if(rst && previous!=={rg,gg,bg,br,bg0,bb} && !upd)$fatal(1,"Colour changed outside frame blanking");
 previous={rg,gg,bg,br,bg0,bb};
end
integer i;
initial begin
 repeat(4)tick();rst=1;means(80,100,120);wait_lock();
 if(rg!==320 || gg!==256 || bg!==213)$fatal(1,"1080p wide division ratios %0d %0d %0d",rg,gg,bg);
 // No exposure-driven or scene-driven colour pumping after lock.
 for(i=0;i<20;i=i+1)begin
  exposure=4+i*111;means(i*9,250-i*7,i);wcount=0;frame();
  if({rg,gg,bg}!=={10'd320,10'd256,10'd213})$fatal(1,"Locked WB changed with exposure/scene");
 end
 request(0);wcount=0;repeat(5)frame();
 if(locked)$fatal(1,"Empty neutral mask falsely calibrated");
 wcount=2073600;means(120,100,80);wait_lock();
 if(rg!==213 || bg!==320)$fatal(1,"Manual white recalibration ratios");
 request(0);means(200,100,25);
 frame();frame();frame();
 // Exposure changes during calibration must restart settling.
 exposure=1024;frame();
 if(dut.state!==1 || dut.settled!==0)$fatal(1,"Exposure did not restart calibration");
 wait_lock();
 if(rg!==128 || bg!==768)$fatal(1,"Gain limits");
 // Known per-channel sensor pedestal; full frame population used.
 request(1);means(12,16,20);repeat(5)frame();
 if(br!==12 || bg0!==16 || bb!==20)$fatal(1,"Black pedestal %0d/%0d/%0d",br,bg0,bb);
 means(80,100,120);wait_lock();
 request(1);means(100,100,100);repeat(5)frame();
 if(br!==12 || bg0!==16 || bb!==20)$fatal(1,"Bright frame accepted as black");
 means(80,100,120);wait_lock();
 // Statistics must reject dark, clipped and highly coloured pixels,
 // but retain raw totals/count for exposure diagnostics.
 de=1;rgb={24'h5a6e82,24'h090909};tick();
 rgb={24'hffffff,24'hfa1414};tick();
 de=0;vs=1;tick();
 if(!tu || tc!==4 || twc!==1 || twr!==80 || twg!==100 || twb!==120)
  $fatal(1,"Neutral mask/count/sums %0d %0d %0d %0d %0d",tc,twc,twr,twg,twb);
 if(tr!==604 || tg!==394 || tb!==414)$fatal(1,"Raw sums altered");
 vs=0;tick();vs=1;tick();
 if(tc!==0 || twc!==0 || tr!==0 || twr!==0)$fatal(1,"Stats frame reset");
 $display("PASS white balance: 1080p division, exposure/scene lock, manual calibration, frame-boundary commits, black reject, neutral mask");$finish;
end
endmodule
