`timescale 1ns/1ps
// SoC and licensed TinyML cores are black boxes (-i); exercise the actual
// integration logic by driving their boundary wires, including delayed AXI R.
module tb_tinyml_resize_integration;
 reg clk=0;always #5 clk=~clk;
 reg reset=1,valid=0,ready=1;reg [9:0] fn=0;reg [31:0] a=0,b=0;
 reg arready=1,rvalid=0,rlast=1,awready=1,wready=1,bvalid=0;
 reg [1:0] rresp=0,bresp=0;
 wire arv,awv,wv,rr,br;wire [31:0] ara,awa;wire [2:0] ars,aws;
 wire [127:0] wd;wire [15:0] ws;wire [7:0] arlen,awlen;
 tinyml_subsystem dut(.clk(clk),.rst_n(1'b1),.acc_arready(arready),
  .acc_rvalid(rvalid),.acc_rdata(128'h1234),.acc_rlast(rlast),.acc_rresp(rresp),
  .acc_awready(awready),.acc_wready(wready),.acc_bvalid(bvalid),.acc_bresp(bresp),
  .acc_arvalid(arv),.acc_araddr(ara),.acc_arsize(ars),.acc_arlen(arlen),.acc_rready(rr),
  .acc_awvalid(awv),.acc_awaddr(awa),.acc_awsize(aws),.acc_awlen(awlen),
  .acc_wvalid(wv),.acc_wdata(wd),.acc_wstrb(ws),.acc_bready(br));
 task command(input [9:0] op,input [31:0] x,y,expected);
  begin
   @(negedge clk);fn=op;a=x;b=y;valid=1;
   #1;if(!dut.ci_cmd_ready)$fatal(1,"CI not ready");
   @(negedge clk);valid=0;
   while (!dut.ci_rsp_valid) @(negedge clk);
   if(!dut.ci_rsp_valid || dut.ci_outputs_0!==expected)$fatal(1,"CI response %h: %h expected %h",op,dut.ci_outputs_0,expected);
   @(negedge clk);
  end
 endtask
 initial begin
  force dut.io_systemReset=reset;
  force dut.ci_cmd_valid=valid;force dut.ci_function_id=fn;
  force dut.ci_inputs_0=a;force dut.ci_inputs_1=b;force dut.ci_rsp_ready=ready;
  force dut.v_cmd_ready=1;force dut.v_rsp_valid=0;
  force dut.v_arvalid=0;force dut.v_awvalid=0;force dut.v_wvalid=0;
  force dut.v_rready=1;force dut.v_bready=1;
  force dut.v_araddr=32'habc0;force dut.v_awaddr=32'hdef0;
  force dut.v_arlen=8'h7f;force dut.v_awlen=8'h7f;
  force dut.v_arsize=3'd4;force dut.v_awsize=3'd4;
  force dut.v_arburst=1;force dut.v_awburst=1;force dut.v_arlock=0;force dut.v_awlock=0;
  force dut.v_wdata=128'h5678;force dut.v_wstrb=16'h1234;force dut.v_wlast=1;
  repeat(3)@(negedge clk);reset=0;
  rresp=3;bresp=2;
  #1;if(dut.g_vendor.u_accel_channels.m_axi_rlast!==0 || dut.g_vendor.u_accel_channels.m_axi_rresp!==0 || dut.g_vendor.u_accel_channels.m_axi_bresp!==0)
    $fatal(1,"unowned shared response sidebands leaked into vendor");
  rresp=0;bresp=0;
  command(10'h200,0,0,32'h49520101);
  command(10'h201,32'h1000,32'h2000,0);
  command(10'h202,1,4,0);command(10'h203,4,0,0);
  // A vendor AR has handshaken; no ARVALID remains while its R is delayed.
  @(negedge clk);force dut.v_arvalid=1;
  @(negedge clk);force dut.v_arvalid=0;
  if(dut.vendor_reads!==1)$fatal(1,"vendor outstanding count");
  command(10'h204,0,0,32'hfffffffe);
  @(negedge clk);rvalid=1;#1;if(dut.g_vendor.u_accel_channels.m_axi_rlast!==1)$fatal(1,"vendor valid RLAST lost");
  @(negedge clk);rvalid=0;
  if(dut.vendor_reads!==0)$fatal(1,"vendor R completion");
  command(10'h204,0,0,0);
  wait(arv);#1;
  if(ara!==32'h1000 || ars!==4 || arlen!==0)$fatal(1,"resize AXI read mapping");
  if(dut.v_arready || dut.v_rvalid || dut.v_awready || dut.v_bvalid)$fatal(1,"vendor not isolated");
  wait(rr);@(negedge clk);rvalid=1;@(negedge clk);rvalid=0;
  #1;if(dut.g_vendor.u_accel_channels.m_axi_rlast!==0)$fatal(1,"resize RLAST leaked into vendor cache");
  wait(wv);#1;
  if(awa!==32'h2000 || aws!==4 || awlen!==0 || ws!==16'hffff)$fatal(1,"resize AXI write mapping");
  command(10'h206,0,0,0); // abort still needs the pending B to drain
  if(!dut.resize_busy)$fatal(1,"released pending write on abort");
  @(negedge clk);bvalid=1;@(negedge clk);bvalid=0;
  if(dut.resize_busy)$fatal(1,"abort failed to drain");
  #1;if(ara!==32'habc0 || awa!==32'hdef0 || wd!==128'h5678 || ws!==16'h1234)$fatal(1,"vendor mapping not restored");
  // Sapphire single-word access is normalized without changing its byte mask.
  force dut.soc_arw_write=0;force dut.soc_arw_addr=32'h80000c;
  force dut.soc_arw_len=0;force dut.soc_arw_size=2;
  #1;if(dut.cpu_araddr!==32'h800000 || dut.cpu_arsize!==4)$fatal(1,"native line conversion");
  $display("PASS: TinyML resize CI/AXI ownership and native line conversion");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule

// A boundary stub exposes the actual ports connected to the licensed vendor
// core. The test drives its command/DMA outputs above; no IP logic is imitated.
module tinyml_accelerator_channels #(parameter AXI_DW_M=128) (
 input clk,reset,cmd_valid,
 input [9:0] cmd_function_id,
 input [31:0] cmd_inputs_0,cmd_inputs_1,
 output cmd_ready,cmd_int,rsp_valid,
 output [31:0] rsp_outputs_0,input rsp_ready,
 input m_axi_clk,m_axi_rstn,
 output m_axi_awvalid,input m_axi_awready,
 output [31:0] m_axi_awaddr,output [7:0] m_axi_awid,m_axi_awlen,
 output [2:0] m_axi_awsize,m_axi_awprot,output [1:0] m_axi_awburst,
 output m_axi_awlock,output [3:0] m_axi_awcache,
 output m_axi_wvalid,input m_axi_wready,
 output [AXI_DW_M-1:0] m_axi_wdata,output [AXI_DW_M/8-1:0] m_axi_wstrb,
 output m_axi_wlast,input m_axi_bvalid,output m_axi_bready,input [1:0] m_axi_bresp,
 output m_axi_arvalid,input m_axi_arready,
 output [31:0] m_axi_araddr,output [7:0] m_axi_arid,m_axi_arlen,
 output [2:0] m_axi_arsize,m_axi_arprot,output [1:0] m_axi_arburst,
 output m_axi_arlock,output [3:0] m_axi_arcache,
 input m_axi_rvalid,output m_axi_rready,
 input [AXI_DW_M-1:0] m_axi_rdata,input m_axi_rlast,input [1:0] m_axi_rresp
);
endmodule
