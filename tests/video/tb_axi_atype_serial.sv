`timescale 1ns/1ps
module tb_axi_atype_serial;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,awv=0,arv=0,ready=0,br=0,rr=0;
  reg [7:0] wid=1,rid=2;
  reg [27:0] wa=28'h810000,ra=28'h920000;
  wire awr,arr,av,wr; wire [7:0] id;
  reg bv=0,rv=0;
  axi_atype_bridge #(.IDW(8),.AW(28)) dut(
    .clk(clk),.rst_n(rst_n),.s_awid(wid),.s_awaddr(wa),
    .s_awlen(8'd0),.s_awsize(3'd4),.s_awburst(2'd1),
    .s_awlock(1'b0),.s_awvalid(awv),.s_awready(awr),
    .s_arid(rid),.s_araddr(ra),.s_arlen(8'd0),.s_arsize(3'd4),
    .s_arburst(2'd1),.s_arlock(1'b0),.s_arvalid(arv),.s_arready(arr),
    .m_aid(id),.m_atype(wr),.m_avalid(av),.m_aready(ready),
    .bvalid(bv),.bready(br),.rvalid(rv),.rlast(rv),.rready(rr));
  reg pending=0,pending_write=0,aw_hs=0,ar_hs=0;
  integer delay=0,writes=0,reads=0,cycles=0;
  always @(posedge clk) begin
    aw_hs<=awv && awr; ar_hs<=arv && arr;
    if(rst_n) begin
      cycles<=cycles+1;
      if(pending && av) $fatal(1,"new VALID before previous response handshook");
      if(av && ready) begin
        if(pending) $fatal(1,"overlapping controller transactions");
        if(wr ? (!awr || arr || id!=wid) : (!arr || awr || id!=rid))
          $fatal(1,"incorrect upstream ownership");
        pending<=1; pending_write<=wr; delay<=1+$urandom%30;
        if(wr) writes<=writes+1; else reads<=reads+1;
      end
      if(pending) begin
        if(delay>0) delay<=delay-1;
        else if(pending_write) bv<=1; else rv<=1;
      end
      if((bv && br)||(rv && rr)) begin pending<=0; bv<=0;rv<=0; end
    end
  end
  integer i;
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    for(i=0;i<40000;i=i+1) begin
      if(!awv || aw_hs) begin awv=$urandom%2;wid=wid+1;wa=wa+16;end
      if(!arv || ar_hs) begin arv=$urandom%2;rid=rid+1;ra=ra+16;end
      ready=$urandom%2; br=($urandom%4)==0;rr=($urandom%4)==0;
      @(negedge clk);
    end
    if(writes<500 || reads<500) $fatal(1,"direction starved");
    if(writes-reads>2 || reads-writes>2) $fatal(1,"unfair arbitration under continuous contention");
    $display("PASS serialized controller transactions writes=%0d reads=%0d cycles=%0d",writes,reads,cycles);
    $finish;
  end
endmodule
