`timescale 1ns/1ps
module tb_cpu_style_mux;
reg rst_n=0;
reg clk=0;
reg [7:0] cpu_awid=0;
reg [31:0] cpu_awaddr=0;
reg [7:0] cpu_awlen=0;
reg [2:0] cpu_awsize=0;
reg [1:0] cpu_awburst=0;
reg cpu_awlock=0;
reg cpu_awvalid=0;
reg [127:0] cpu_wdata=0;
reg [15:0] cpu_wstrb=0;
reg cpu_wlast=0;
reg cpu_wvalid=0;
reg cpu_bready=0;
reg [7:0] cpu_arid=0;
reg [31:0] cpu_araddr=0;
reg [7:0] cpu_arlen=0;
reg [2:0] cpu_arsize=0;
reg [1:0] cpu_arburst=0;
reg cpu_arlock=0;
reg cpu_arvalid=0;
reg cpu_rready=0;
wire cpu_awready;
wire cpu_wready;
wire [7:0] cpu_bid;
wire [1:0] cpu_bresp;
wire cpu_bvalid;
wire cpu_arready;
wire [127:0] cpu_rdata;
wire [7:0] cpu_rid;
wire [1:0] cpu_rresp;
wire cpu_rlast;
wire cpu_rvalid;
reg [31:0] style_awaddr=0;
reg [7:0] style_awlen=0;
reg style_awvalid=0;
reg [127:0] style_wdata=0;
reg style_wlast=0;
reg style_wvalid=0;
reg style_bready=0;
reg [31:0] style_araddr=0;
reg [7:0] style_arlen=0;
reg style_arvalid=0;
reg style_rready=0;
wire style_awready;
wire style_wready;
wire [1:0] style_bresp;
wire style_bvalid;
wire style_arready;
wire [127:0] style_rdata;
wire [1:0] style_rresp;
wire style_rlast;
wire style_rvalid;
wire [7:0] m_awid;
wire [31:0] m_awaddr;
wire [7:0] m_awlen;
wire [2:0] m_awsize;
wire [1:0] m_awburst;
wire m_awlock;
wire m_awvalid;
wire [127:0] m_wdata;
wire [15:0] m_wstrb;
wire m_wlast;
wire m_wvalid;
wire m_bready;
wire [7:0] m_arid;
wire [31:0] m_araddr;
wire [7:0] m_arlen;
wire [2:0] m_arsize;
wire [1:0] m_arburst;
wire m_arlock;
wire m_arvalid;
wire m_rready;
reg m_awready=0;
reg m_wready=0;
reg [7:0] m_bid=0;
reg [1:0] m_bresp=0;
reg m_bvalid=0;
reg m_arready=0;
reg [127:0] m_rdata=0;
reg [7:0] m_rid=0;
reg [1:0] m_rresp=0;
reg m_rlast=0;
reg m_rvalid=0;
always #5 clk=~clk;
axi_cpu_style_mux dut(.*);
integer cpu_bcount=0,cpu_rcount=0;
integer style_bcount=0,style_rcount=0;
integer cycle=0,wb=0,wlen=0,rb=0,rlen=0,bdelay=0;
reg wp=0,rp=0;reg [31:0] wa,ra;reg [7:0] wid,rid;
reg awstall=0,arstall=0,wstall=0;
reg [52:0] awhold,arhold;reg [128:0] whold;
always @(posedge clk)begin
 if(!rst_n)begin m_awready<=0;m_wready<=0;m_bvalid<=0;m_arready<=0;m_rvalid<=0;end
 else begin
  cycle<=cycle+1;m_awready<=!wp && cycle%7!=0;m_wready<=wp && cycle%3!=0;
  m_arready<=!rp && cycle%5!=0;
  if(awstall && ({m_awid,m_awaddr,m_awlen,m_awsize,m_awburst}!==awhold || !m_awvalid))$fatal(1,"AW hold");
  if(arstall && ({m_arid,m_araddr,m_arlen,m_arsize,m_arburst}!==arhold || !m_arvalid))$fatal(1,"AR hold");
  if(wstall && ({m_wlast,m_wdata}!==whold || !m_wvalid))$fatal(1,"W hold");
  awstall<=m_awvalid && !m_awready;awhold<={m_awid,m_awaddr,m_awlen,m_awsize,m_awburst};
  arstall<=m_arvalid && !m_arready;arhold<={m_arid,m_araddr,m_arlen,m_arsize,m_arburst};
  wstall<=m_wvalid && !m_wready;whold<={m_wlast,m_wdata};
  if(m_awvalid && m_awready)begin
   if(wp)$fatal(1,"AW ownership");wp<=1;wa<=m_awaddr;wid<=m_awid;wlen<=m_awlen;wb<=0;
   if(m_awsize!=4 || m_awburst!=1)$fatal(1,"write geometry");
  end
  if(m_wvalid && m_wready)begin
   if(!wp || wb>wlen)$fatal(1,"W before AW or after LAST");
   if(m_wdata!==(wid==8'h10 ? 128'hd000 : 128'hc000)+(wa & 32'hffff)+wb || m_wlast!=(wb==wlen))$fatal(1,"W response routing/data");
   wb<=wb+1;if(m_wlast)bdelay<=11;
  end
  if(bdelay>0)begin bdelay<=bdelay-1;if(bdelay==1)begin m_bvalid<=1;m_bid<=wid;m_bresp<=0;end end
  if(m_bvalid && m_bready)begin m_bvalid<=0;wp<=0;end
  if(m_arvalid && m_arready)begin
   if(rp)$fatal(1,"AR ownership");rp<=1;ra<=m_araddr;rid<=m_arid;rb<=0;rlen<=m_arlen;
   if(m_arsize!=4 || m_arburst!=1)$fatal(1,"read geometry");
  end
  if(m_rvalid && m_rready)begin
   m_rvalid<=0;rb<=rb+1;ra<=ra+16;if(m_rlast)rp<=0;
  end
  if(rp && !m_rvalid && cycle%4!=0)begin m_rvalid<=1;m_rdata<=ra;m_rid<=rid;m_rresp<=0;m_rlast<=rb==rlen;end
  if(cpu_bvalid && cpu_bready)begin
   if(cpu_bid!=3 || cpu_bresp!=0)$fatal(1,"CPU B");cpu_bcount<=cpu_bcount+1;
  end
  if(style_bvalid && style_bready)begin
   if(style_bresp!=0)$fatal(1,"style B");style_bcount<=style_bcount+1;
  end
 end
end
task cpu_writes;
 for(integer i=0;i<32;i=i+1)begin
  @(negedge clk);cpu_awaddr=32'h00800000+i*256;cpu_awlen=3;cpu_awvalid=1;
  fork
   begin do @(posedge clk);while(!cpu_awready);@(negedge clk);cpu_awvalid=0;end
   begin
    for(integer b=0;b<4;b=b+1)begin
     @(negedge clk);cpu_wdata=128'hc000+i*256+b;cpu_wlast=b==3;cpu_wvalid=1;
     do @(posedge clk);while(!cpu_wready);
    end
    @(negedge clk);cpu_wvalid=0;
   end
  join
  // Submit next AW/W before delayed B: next W must not leak through.
 end
endtask
task style_writes;
 for(integer i=0;i<16;i=i+1)begin
  @(negedge clk);style_awaddr=32'h03000000+i*256;style_awlen=15;style_awvalid=1;
  fork
   begin do @(posedge clk);while(!style_awready);@(negedge clk);style_awvalid=0;end
   begin
    for(integer b=0;b<16;b=b+1)begin
     @(negedge clk);style_wdata=128'hd000+i*256+b;style_wlast=b==15;style_wvalid=1;
     do @(posedge clk);while(!style_wready);
    end
    @(negedge clk);style_wvalid=0;
   end
  join
  // Submit next AW/W before delayed B: next W must not leak through.
 end
endtask
task cpu_reads;
 for(integer i=0;i<16;i=i+1)begin
  @(negedge clk);cpu_araddr=32'h00900000+i*512;cpu_arlen=3;cpu_arvalid=1;
  do @(posedge clk);while(!cpu_arready);@(negedge clk);cpu_arvalid=0;
  for(integer b=0;b<4;b=b+1)begin
   do @(posedge clk);while(!cpu_rvalid);
   if(cpu_rdata!==32'h00900000+i*512+b*16 || cpu_rlast!=(b==3) || cpu_rresp!=0)$fatal(1,"cpu R attribution");
   cpu_rcount=cpu_rcount+1;
  end
 end
endtask
task style_reads;
 for(integer i=0;i<16;i=i+1)begin
  @(negedge clk);style_araddr=32'h03400000+i*512;style_arlen=31;style_arvalid=1;
  do @(posedge clk);while(!style_arready);@(negedge clk);style_arvalid=0;
  for(integer b=0;b<32;b=b+1)begin
   do @(posedge clk);while(!style_rvalid);
   if(style_rdata!==32'h03400000+i*512+b*16 || style_rlast!=(b==31) || style_rresp!=0)$fatal(1,"style R attribution");
   style_rcount=style_rcount+1;
  end
 end
endtask
initial begin
 cpu_awid=3;cpu_arid=3;cpu_awsize=4;cpu_arsize=4;cpu_awburst=1;cpu_arburst=1;cpu_wstrb=16'hffff;
 cpu_bready=1;style_bready=1;cpu_rready=1;style_rready=1;
 repeat(4)@(negedge clk);rst_n=1;
 fork cpu_writes();style_writes();cpu_reads();style_reads();join
 wait(cpu_bcount==32 && style_bcount==16);
 if(cpu_rcount!=64 || style_rcount!=512)$fatal(1,"read count");
 $display("PASS CPU/style mux: concurrent streams, backpressure, response ownership, independent AW/W, WLAST gate");$finish;
end
initial begin #2000000;$fatal(1,"mux timeout");end
endmodule
