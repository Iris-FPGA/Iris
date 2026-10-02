`timescale 1ns/1ps
module tb_frame_banks;
reg clk=0,rst=0,wd=0,rs=0;
always #5 clk=~clk;
wire [27:0] wa,ra;
wire [1:0] writer,reader,latest;
wire ready;
frame_bank_manager dut(.clk(clk),.rst_n(rst),.wr_done(wd),.rd_start(rs),
 .wr_addr(wa),.rd_addr(ra),.writer(writer),.reader(reader),.latest(latest),.ready(ready));
reg [2:0] sync=0;
reg [1:0] physical_reader=1;
reg [27:0] physical_addr;
reg [31:0] rng=32'hbed123;
integer t;
always @(posedge clk)begin
 if(!rst)begin sync<=0;physical_reader<=1;end
 else begin
  sync<={sync[1:0],rs};
  // This matches ddr_rd_buffer's pos_start and start_addr_r capture.
  if(sync[1:0]==2'b01)begin physical_reader<=ready?latest:reader;physical_addr<=ra;end
 end
end
initial begin
 repeat(4)@(negedge clk);rst=1;
 for(t=0;t<3000;t=t+1)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  wd=(t%7==0 || (rng[3:0]==0));
  rs=(t%31<3);
  @(posedge clk);#1;
  if(writer===physical_reader)$fatal(1,"Writer overwrote display-locked frame at t=%0d writer=%0d reader=%0d",t,writer,physical_reader);
  if(reader!==physical_reader)$fatal(1,"Reader lock differs from actual DDR address capture");
  if(wa%2080768!=0 || ra%2080768!=0)$fatal(1,"Incorrect 1080p bank stride");
  if(wa>28'd4161536 || ra>28'd4161536)$fatal(1,"Invalid bank");
  @(negedge clk);
 end
 $display("PASS 1080p frame banks: disjoint 2080768-byte strides, writer/reader locks and coincident swaps");$finish;
end
endmodule
