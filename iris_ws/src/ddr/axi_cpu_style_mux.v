// Independent read/write round-robin CPU + style DMA merger.
// Grants lock before presenting an address and last through B/RLAST.
module axi_cpu_style_mux(
    input wire clk, rst_n,
    input wire [7:0] cpu_awid,
    input wire [31:0] cpu_awaddr,
    input wire [7:0] cpu_awlen,
    input wire [2:0] cpu_awsize,
    input wire [1:0] cpu_awburst,
    input wire cpu_awlock,
    input wire cpu_awvalid,
    input wire [127:0] cpu_wdata,
    input wire [15:0] cpu_wstrb,
    input wire cpu_wlast,
    input wire cpu_wvalid,
    input wire cpu_bready,
    input wire [7:0] cpu_arid,
    input wire [31:0] cpu_araddr,
    input wire [7:0] cpu_arlen,
    input wire [2:0] cpu_arsize,
    input wire [1:0] cpu_arburst,
    input wire cpu_arlock,
    input wire cpu_arvalid,
    input wire cpu_rready,
    output wire cpu_awready,
    output wire cpu_wready,
    output wire [7:0] cpu_bid,
    output wire [1:0] cpu_bresp,
    output wire cpu_bvalid,
    output wire cpu_arready,
    output wire [127:0] cpu_rdata,
    output wire [7:0] cpu_rid,
    output wire [1:0] cpu_rresp,
    output wire cpu_rlast,
    output wire cpu_rvalid,
    input wire [31:0] style_awaddr,
    input wire [7:0] style_awlen,
    input wire style_awvalid,
    input wire [127:0] style_wdata,
    input wire style_wlast,
    input wire style_wvalid,
    input wire style_bready,
    input wire [31:0] style_araddr,
    input wire [7:0] style_arlen,
    input wire style_arvalid,
    input wire style_rready,
    output wire style_awready,
    output wire style_wready,
    output wire [1:0] style_bresp,
    output wire style_bvalid,
    output wire style_arready,
    output wire [127:0] style_rdata,
    output wire [1:0] style_rresp,
    output wire style_rlast,
    output wire style_rvalid,
    output wire [7:0] m_awid,
    output wire [31:0] m_awaddr,
    output wire [7:0] m_awlen,
    output wire [2:0] m_awsize,
    output wire [1:0] m_awburst,
    output wire m_awlock,
    output wire m_awvalid,
    output wire [127:0] m_wdata,
    output wire [15:0] m_wstrb,
    output wire m_wlast,
    output wire m_wvalid,
    output wire m_bready,
    output wire [7:0] m_arid,
    output wire [31:0] m_araddr,
    output wire [7:0] m_arlen,
    output wire [2:0] m_arsize,
    output wire [1:0] m_arburst,
    output wire m_arlock,
    output wire m_arvalid,
    output wire m_rready,
    input wire m_awready,
    input wire m_wready,
    input wire [7:0] m_bid,
    input wire [1:0] m_bresp,
    input wire m_bvalid,
    input wire m_arready,
    input wire [127:0] m_rdata,
    input wire [7:0] m_rid,
    input wire [1:0] m_rresp,
    input wire m_rlast,
    input wire m_rvalid
);
reg wr_busy,wr_style,wr_started,wr_last,wr_next;
reg rd_busy,rd_style,rd_started,rd_next;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  wr_busy<=0;wr_style<=0;wr_started<=0;wr_last<=0;wr_next<=0;
  rd_busy<=0;rd_style<=0;rd_started<=0;rd_next<=0;
 end else begin
  if(!wr_busy && (cpu_awvalid || style_awvalid))begin
   wr_busy<=1;wr_started<=0;wr_last<=0;
   wr_style<=style_awvalid && (!cpu_awvalid || wr_next);
  end
  if(m_awvalid && m_awready)wr_started<=1;
  if(m_wvalid && m_wready && m_wlast)wr_last<=1;
  if(m_bvalid && m_bready)begin wr_busy<=0;wr_next<=!wr_style;end
  if(!rd_busy && (cpu_arvalid || style_arvalid))begin
   rd_busy<=1;rd_started<=0;
   rd_style<=style_arvalid && (!cpu_arvalid || rd_next);
  end
  if(m_arvalid && m_arready)rd_started<=1;
  if(m_rvalid && m_rready && m_rlast)begin rd_busy<=0;rd_next<=!rd_style;end
 end
end
// Use a small dedicated tag while investigating the controller interaction
// triggered by capture writes. Global ownership still routes B/R responses.
assign m_awid=wr_style ? 8'h10 : cpu_awid;
assign m_awaddr=wr_style ? style_awaddr : cpu_awaddr;
assign m_awlen=wr_style ? style_awlen : cpu_awlen;
assign m_awsize=wr_style ? 3'd4 : cpu_awsize;
assign m_awburst=wr_style ? 2'd1 : cpu_awburst;
assign m_awlock=wr_style ? 1'b0 : cpu_awlock;
assign m_wdata=wr_style ? style_wdata : cpu_wdata;
assign m_wstrb=wr_style ? 16'hffff : cpu_wstrb;
assign m_wlast=wr_style ? style_wlast : cpu_wlast;
assign m_arid=rd_style ? 8'h10 : cpu_arid;
assign m_araddr=rd_style ? style_araddr : cpu_araddr;
assign m_arlen=rd_style ? style_arlen : cpu_arlen;
assign m_arsize=rd_style ? 3'd4 : cpu_arsize;
assign m_arburst=rd_style ? 2'd1 : cpu_arburst;
assign m_arlock=rd_style ? 1'b0 : cpu_arlock;
assign m_awvalid=wr_busy && !wr_started && (wr_style ? style_awvalid : cpu_awvalid);
assign m_wvalid=wr_busy && wr_started && !wr_last && (wr_style ? style_wvalid : cpu_wvalid);
assign m_bready=wr_busy && wr_started && wr_last && (wr_style ? style_bready : cpu_bready);
assign m_arvalid=rd_busy && !rd_started && (rd_style ? style_arvalid : cpu_arvalid);
assign m_rready=rd_busy && rd_started && (rd_style ? style_rready : cpu_rready);
assign cpu_awready=wr_busy && !wr_started && (!wr_style) && m_awready;
assign cpu_wready=wr_busy && wr_started && !wr_last && (!wr_style) && m_wready;
assign cpu_bvalid=wr_busy && wr_started && wr_last && (!wr_style) && m_bvalid;
assign cpu_bresp=m_bresp;
assign cpu_arready=rd_busy && !rd_started && (!rd_style) && m_arready;
assign cpu_rvalid=rd_busy && rd_started && (!rd_style) && m_rvalid;
assign cpu_rdata=m_rdata;
assign cpu_rresp=m_rresp;
assign cpu_rlast=m_rlast;
assign cpu_bid=m_bid;
assign cpu_rid=m_rid;
assign style_awready=wr_busy && !wr_started && (wr_style) && m_awready;
assign style_wready=wr_busy && wr_started && !wr_last && (wr_style) && m_wready;
assign style_bvalid=wr_busy && wr_started && wr_last && (wr_style) && m_bvalid;
assign style_bresp=m_bresp;
assign style_arready=rd_busy && !rd_started && (rd_style) && m_arready;
assign style_rvalid=rd_busy && rd_started && (rd_style) && m_rvalid;
assign style_rdata=m_rdata;
assign style_rresp=m_rresp;
assign style_rlast=m_rlast;
endmodule
