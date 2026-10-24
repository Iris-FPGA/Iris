`timescale 1ns/1ps
// Exercise APB ownership independently of pixel arithmetic and AXI timing.
module tb_style_pipeline;
reg clk=0,rst_n=0;
always #5 clk=~clk;
reg [15:0] paddr=0;
reg psel=0,penable=0,pwrite=0;
reg [31:0] pwdata=0;
wire [31:0] prdata;
reg cap_busy=0,cap_done=0,commit_ack=0,video_have=0;
reg [1:0] video_pair=0;
iris_style_demo dut(.clk(clk),.video_clk(clk),.rst_n(rst_n),
 .paddr(paddr),.psel(psel),.penable(penable),.pwrite(pwrite),
 .pwdata(pwdata),.prdata(prdata),.bus_write_dummy_bad(32'd0));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task write_reg(input integer index,input reg [31:0] value);
 begin paddr=index*4;pwdata=value;psel=1;penable=1;pwrite=1;tick();psel=0;penable=0;pwrite=0;tick();end
endtask
task select_bank(input integer bank);write_reg(1,bank);endtask
task finish_capture;
 begin tick();cap_busy=0;cap_done=1;repeat(3)tick();end
endtask
task acknowledge(input integer bank);
 begin video_pair=bank;video_have=1;commit_ack=dut.commit_toggle;repeat(6)tick();end
endtask
integer rejected;
initial begin
 force dut.cap_busy=cap_busy;force dut.cap_done=cap_done;force dut.cap_error=1'b0;
 force dut.capture_write_dummy_bad=32'd0;
 force dut.commit_ack=commit_ack;force dut.video_pair=video_pair;force dut.video_have=video_have;
 force dut.underflows=32'd0;force dut.read_errors=32'd0;
 repeat(4)tick();rst_n=1;repeat(3)tick();
 paddr=64;#1;if(prdata!==32'h49500301)$fatal(1,"pipeline registers alias legacy APB");
 select_bank(0);write_reg(0,1);cap_busy=1;cap_done=0;
 select_bank(2);if(dut.capture_pair!=0)$fatal(1,"capture address changed with config");
 finish_capture();
 if(dut.captured_valid!=1)$fatal(1,"capture validity not bank-specific");
 write_reg(18,4);if(!dut.inference_busy || dut.inference_pair!=0)$fatal(1,"acquire inference bank");
 rejected=dut.rejected_count;select_bank(0);write_reg(0,1);
 if(dut.rejected_count!=rejected+1)$fatal(1,"capture overwrote inference");
 rejected=dut.rejected_count;write_reg(0,2);
 if(dut.rejected_count!=rejected+1)$fatal(1,"unfinished inference was published");
 select_bank(1);write_reg(0,1);cap_busy=1;cap_done=0;
 if(dut.capture_pair!=1)$fatal(1,"capture did not overlap inference");
 write_reg(18,0);select_bank(0);write_reg(0,2);
 if(!dut.pending_commit || dut.commit_pair!=0)$fatal(1,"commit blocked by different capture bank");
 select_bank(2);if(dut.commit_pair!=0)$fatal(1,"pending commit mailbox changed");
 rejected=dut.rejected_count;select_bank(0);write_reg(0,1);
 if(dut.rejected_count!=rejected+1)$fatal(1,"pending bank was writable");
 finish_capture();write_reg(18,5);
 if(!dut.inference_busy || dut.inference_pair!=1)$fatal(1,"inference blocked by other pending bank");
 acknowledge(0);
 if(dut.displayed_count!=1 || dut.pending_commit)$fatal(1,"VS did not release pending lease");
 rejected=dut.rejected_count;select_bank(0);write_reg(0,1);
 if(dut.rejected_count!=rejected+1)$fatal(1,"displayed bank was writable");
 select_bank(2);paddr=8;#1;if(prdata!=32'h03800000)$fatal(1,"third input address");
 paddr=12;#1;if(prdata!=32'h03a00000)$fatal(1,"third output address");
 write_reg(0,1);cap_busy=1;cap_done=0;
 if(dut.capture_pair!=2 || !dut.inference_busy || !dut.video_have)$fatal(1,"three stages not concurrent");
 finish_capture();write_reg(18,1);select_bank(1);write_reg(0,2);
 select_bank(2);write_reg(18,6);acknowledge(1);
 if(dut.inference_pair!=2 || dut.displayed_count!=2)$fatal(1,"third inference bank or second VS");
 select_bank(0);write_reg(0,1);cap_busy=1;cap_done=0;
 if(dut.capture_pair!=0 || dut.captured_valid[0])$fatal(1,"old display bank was not reusable");
 finish_capture();write_reg(18,2);select_bank(2);write_reg(0,2);acknowledge(2);
 if(dut.pair_sync2!=2 || dut.displayed_count!=3)$fatal(1,"third bank identity truncated across CDC");
 rejected=dut.rejected_count;select_bank(3);write_reg(18,7);write_reg(0,3);
 if(dut.rejected_count!=rejected+3 || dut.pair_cfg!=2)$fatal(1,"invalid bank or combined command accepted");
 $display("PASS triple-bank leases: concurrent capture/inference/display, stable mailboxes, VS release, bank 2, rejection guards");
 $finish;
end
initial begin #100000;$fatal(1,"pipeline ownership timeout");end
endmodule
