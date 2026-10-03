`timescale 1ns/1ps
// Common-clock FIFO model isolates the real AXI writer's transaction timing.
module DC_FIFO #(parameter FIFO_MODE="Normal", DATA_WIDTH=128, FIFO_DEPTH=1024)(
 input Reset,WrClk,WrEn,RdClk,RdEn,
 input [DATA_WIDTH-1:0] WrData,
 output [ $clog2(FIFO_DEPTH):0] WrDNum,RdDNum,
 output WrFull,RdEmpty,
 output reg [DATA_WIDTH-1:0] RdData
);
 reg [DATA_WIDTH-1:0] mem[0:FIFO_DEPTH-1];
 integer wp=0,rp=0,count=0;
 assign WrDNum=count; assign RdDNum=count;
 assign WrFull=count==FIFO_DEPTH; assign RdEmpty=count==0;
 always @(posedge WrClk or posedge Reset) begin
  if(Reset)begin wp<=0;rp<=0;count<=0;RdData<=0;end
  else begin
   if(WrEn&&!WrFull)begin mem[wp]<=WrData;wp<=(wp+1)%FIFO_DEPTH;end
   if(RdEn&&!RdEmpty)begin RdData<=mem[rp];rp<=(rp+1)%FIFO_DEPTH;end
   case({WrEn&&!WrFull,RdEn&&!RdEmpty})
    2'b10:count<=count+1;2'b01:count<=count-1;default:;
   endcase
  end
 end
endmodule

module tb_write_commit;
 reg clk=0,rst=0,start=0,frst=0,push=0;
 always #5 clk=~clk;
 reg [127:0] din=0;
 wire full,done,awvalid,wvalid,wlast,bready;
 wire [27:0] addr,wa,ra;
 wire [7:0] len;
 wire [127:0] data;
 wire [1:0] writer,reader,latest;
 wire ready;
 reg awready=0,wready=0,bvalid=0;
 ddr_wr_buffer1 #(.AXI_DATA_WIDTH(128),.AXI_ADDR_WIDTH(28),.BURST_LEN(127)) dut(
  .axi_clk(clk),.rst_n(rst),.wr_start(start),.start_addr(wa),.total_burst_len(25'd320),
  .bank_sw_ack(done),.bank_sw(done),.wr_fifo_rst_p(frst),.wr_fifo_wrclk(clk),
  .wr_fifo_wren(push),.wr_fifo_wrfull(full),.wr_fifo_wrdata(din),
  .awaddr(addr),.awlen(len),.awvalid(awvalid),.awready(awready),
  .wdata(data),.wvalid(wvalid),.wlast(wlast),.wready(wready),
  .bid(6'd0),.bvalid(bvalid),.bready(bready));
 frame_bank_manager banks(.clk(clk),.rst_n(rst),.wr_done(done),.rd_start(1'b0),
  .wr_addr(wa),.rd_addr(ra),.writer(writer),.reader(reader),.latest(latest),.ready(ready));
 integer cycle=0,frame=0,words=0,aws=0,ends=0,backs=0,publishes=0;
 integer due[0:15],qwr=0,qrd=0,held=0,k,limit;
 reg done_prev=0;
 reg [27:0] base=0;
 always @(negedge clk)begin
  awready=(cycle%7!=0);
  wready=(cycle%5!=0);
  // Force a long stall WITHIN the last burst.
  if(words==300 && held<80)begin wready=0;held=held+1;end
  bvalid=(qrd<qwr && cycle>=due[qrd]);
 end
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rst)begin
   if(awvalid&&awready)begin
    if(addr!==base+aws*2048)$fatal(1,"Write address/order %h expected %h",addr,base+aws*2048);
    if(len!==(aws<2?8'd127:8'd63))$fatal(1,"Incorrect burst length");
    aws=aws+1;
   end
   if(wvalid&&wready)begin
    if(data!==128'(frame*1000+words))$fatal(1,"Write pixel order: frame=%0d word=%0d got=%h",frame,words,data);
    words=words+1;
    if(wlast)begin
     ends=ends+1;due[qwr]=cycle+100;qwr=qwr+1;
    end
   end
   if(bvalid&&bready)begin backs=backs+1;qrd=qrd+1;end
   #1;
   if(done)begin
    if(done_prev)$fatal(1,"Frame publication is a level, not a pulse");
    if(words!=320||ends!=3||backs!=3)$fatal(1,"Premature publication: W=%0d last=%0d B=%0d",words,ends,backs);
    publishes=publishes+1;
   end
   done_prev=done;
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(frame=0;frame<3;frame=frame+1)begin
   words=0;aws=0;ends=0;backs=0;held=0;qwr=0;qrd=0;base=wa;
   frst=1;@(negedge clk);frst=0;
   start=1;repeat(12)@(negedge clk);start=0;
   for(k=0;k<320;k=k+1)begin
    push=1;din=frame*1000+k;@(negedge clk);
   end
   push=0;limit=cycle+5000;
   while(publishes<frame+1&&cycle<limit)@(negedge clk);
   if(publishes!=frame+1)$fatal(1,"Missing frame completion");
   repeat(30)@(negedge clk);
   if(publishes!=frame+1)$fatal(1,"Repeated frame completion");
  end
  $display("PASS actual DDR writer: ordered pixels/bursts, final-burst stall, delayed B, exactly one complete-frame publication");$finish;
 end
endmodule
