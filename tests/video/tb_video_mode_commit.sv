`timescale 1ns/1ps
module tb_video_mode_commit;
reg rclk=0,pclk=0;always #7 rclk=~rclk;always #3 pclk=~pclk;
reg rst=0,req=0,vs=0;
wire rdmode,pxmode;
video_mode_commit dut(.read_clk(rclk),.pixel_clk(pclk),.rst_n(rst),.request_4k(req),.read_vs(vs),.read_4k(rdmode),.pixel_4k(pxmode));
task wait_read;input integer n;integer i;begin for(i=0;i<n;i=i+1)@(negedge rclk);end endtask
initial begin
 wait_read(4);rst=1;wait_read(4);if(rdmode||pxmode)$fatal(1,"boot mode");
 req=1;wait_read(10);if(rdmode||pxmode)$fatal(1,"mid-frame request committed early");
 vs=1;wait_read(4);if(!rdmode||!pxmode)$fatal(1,"frame request did not commit");
 req=0;wait_read(10);if(!rdmode||!pxmode)$fatal(1,"changed during VS plateau");
 vs=0;wait_read(5);if(!rdmode)$fatal(1,"changed at VS falling edge");
 vs=1;wait_read(4);if(rdmode||pxmode)$fatal(1,"return to RGB failed");
 req=1;vs=0;wait_read(10);rst=0;wait_read(4);
 if(rdmode||pxmode)$fatal(1,"reset did not restore RGB");
 $display("PASS mode switch: asynchronous request, VS rising-edge commits, stable during active frame/VS plateau, RGB reset");$finish;
end
endmodule
