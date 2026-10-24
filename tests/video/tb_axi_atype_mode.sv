`timescale 1ns/1ps
module tb_axi_atype_mode;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,serial_enable=0,awv=0,arv=0,ready=1;
reg bv=0,br=0,rv=0,rr=0;
wire awr,arr,av,wr;
axi_atype_bridge #(.IDW(8),.AW(28)) dut(
 .clk(clk),.rst_n(rst_n),.serial_enable(serial_enable),
 .s_awid(8'h11),.s_awaddr(28'h810000),.s_awlen(8'd0),.s_awsize(3'd4),
 .s_awburst(2'd1),.s_awlock(1'b0),.s_awvalid(awv),.s_awready(awr),
 .s_arid(8'h22),.s_araddr(28'h920000),.s_arlen(8'd0),.s_arsize(3'd4),
 .s_arburst(2'd1),.s_arlock(1'b0),.s_arvalid(arv),.s_arready(arr),
 .m_atype(wr),.m_avalid(av),.m_aready(ready),
 .bvalid(bv),.bready(br),.rvalid(rv),.rlast(rv),.rready(rr));
task idle_cycle;@(negedge clk);endtask
initial begin
 repeat(3)idle_cycle();rst_n=1;
 // Offer a write, then lock an overlapping read under backpressure.
 awv=1;idle_cycle();awv=0;
 if(!dut.write_active)$fatal(1,"write was not recorded");
 ready=0;arv=1;idle_cycle();
 if(!dut.selection_locked || !av || wr)$fatal(1,"read not locked");
 serial_enable=1;idle_cycle();
 if(!av || wr)$fatal(1,"mode change withdrew a stalled read");
 ready=1;idle_cycle();arv=0;
 if(!dut.read_active || !dut.write_active)$fatal(1,"overlap not tracked");
 // A new write must wait for BOTH old transactions, even if B completes.
 awv=1;bv=1;br=1;idle_cycle();bv=0;
 repeat(4)begin
  if(av || awr)$fatal(1,"serialization released after only B");
  idle_cycle();
 end
 rv=1;rr=0;idle_cycle();
 if(av || awr)$fatal(1,"unaccepted RLAST released mode");
 rr=1;idle_cycle();rv=0;
 if(!av || !awr || !wr)$fatal(1,"new write not released after full drain");
 idle_cycle();awv=0;
 if(!dut.write_active)$fatal(1,"serialized write not recorded");
 arv=1;repeat(4)begin
  if(av || arr)$fatal(1,"read overlapped serialized write");
  idle_cycle();
 end
 bv=1;idle_cycle();bv=0;
 if(!av || !arr || wr)$fatal(1,"read not released after B");
 $display("PASS DDR mode switch: held VALID, drain both directions, response backpressure");
 $finish;
end
initial begin #5000;$fatal(1,"mode test timeout");end
endmodule
