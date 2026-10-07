`timescale 1ns/1ps
module tb_axi_atype_bridge;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,awv=0,arv=0,ready=0;
  reg [7:0] awid=8'ha3,arid=8'hb4;
  reg [27:0] awaddr=28'h12340,araddr=28'h56780;
  reg [7:0] awlen=7,arlen=19;
  reg [2:0] awsize=4,arsize=3;
  reg [1:0] awburst=1,arburst=2;
  reg awlock=1,arlock=0;
  wire awready,arready,valid,atype;
  wire [7:0] id,len; wire [27:0] addr;
  wire [2:0] size; wire [1:0] burst,lock;
  axi_atype_bridge #(.IDW(8),.AW(28),.SERIAL_TRANSACTIONS(0)) dut(
    .clk(clk),.rst_n(rst_n),.s_awid(awid),.s_awaddr(awaddr),
    .s_awlen(awlen),.s_awsize(awsize),.s_awburst(awburst),
    .s_awlock(awlock),.s_awvalid(awv),.s_awready(awready),
    .s_arid(arid),.s_araddr(araddr),.s_arlen(arlen),
    .s_arsize(arsize),.s_arburst(arburst),.s_arlock(arlock),
    .s_arvalid(arv),.s_arready(arready),.m_aid(id),.m_aaddr(addr),
    .m_alen(len),.m_asize(size),.m_aburst(burst),.m_alock(lock),
    .m_atype(atype),.m_avalid(valid),.m_aready(ready),
    .bvalid(1'b0),.bready(1'b0),.rvalid(1'b0),.rlast(1'b0),.rready(1'b0));
  reg was_stalled=0; reg [51:0] held;
  wire [51:0] payload={atype,id,addr,len,size,burst,lock};
  integer writes=0,reads=0;
  always @(posedge clk) begin
    if(!rst_n) was_stalled<=0;
    else begin
      if(was_stalled && (!valid || payload!==held))
        $fatal(1,"shared address changed while stalled: was %h now %h",held,payload);
      if(awready && arready) $fatal(1,"both input addresses accepted");
      if(valid && ready) begin
        if(atype) begin
          if(!awready || arready || payload!=={1'b1,awid,awaddr,awlen,awsize,awburst,1'b0,awlock})
            $fatal(1,"wrong write ownership/payload");
          writes<=writes+1;
        end else begin
          if(!arready || awready || payload!=={1'b0,arid,araddr,arlen,arsize,arburst,1'b0,arlock})
            $fatal(1,"wrong read ownership/payload");
          reads<=reads+1;
        end
      end
      was_stalled<=valid && !ready;
      held<=payload;
    end
  end
  integer i;
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    // AW is already stalled when AR arrives. Every address field must hold.
    awv=1; repeat(3) @(negedge clk); arv=1;
    repeat(40) @(negedge clk); ready=1;
    @(negedge clk); awv=0;
    @(negedge clk); arv=0; ready=0;
    // Mirror direction, then reset with a locked pending request.
    arv=1; repeat(3) @(negedge clk); awv=1;
    repeat(40) @(negedge clk); ready=1;
    @(negedge clk); arv=0;
    @(negedge clk); awv=0;ready=0;
    awv=1; repeat(3) @(negedge clk); rst_n=0; awv=0;
    @(negedge clk); rst_n=1; arv=1;ready=1;
    @(negedge clk); arv=0;ready=0;
    // Independent streams retain their payload until their own handshake.
    for(i=0;i<4000;i=i+1) begin
      if(!awv || awready) begin
        awv=($urandom%3)!=0;awid=$urandom;awaddr=$urandom;
        awlen=$urandom;awsize=$urandom;awburst=$urandom;awlock=$urandom;
      end
      if(!arv || arready) begin
        arv=($urandom%3)!=0;arid=$urandom;araddr=$urandom;
        arlen=$urandom;arsize=$urandom;arburst=$urandom;arlock=$urandom;
      end
      ready=($urandom%4)==0;
      @(negedge clk);
    end
    if(writes<50 || reads<50) $fatal(1,"insufficient both-direction coverage");
    $display("PASS AXI shared-address stability writes=%0d reads=%0d",writes,reads);
    $finish;
  end
  initial begin #1000000; $fatal(1,"timeout"); end
endmodule
