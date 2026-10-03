`timescale 1ns/1ps
module tb_ae_osd_address;
reg clk=0,rst=0,de=0;
always #5 clk=~clk;
wire[23:0]rgb;
osd_ae dut(.clk(clk),.rst_n(rst),.i_hs(1'b0),.i_vs(1'b0),.i_de(de),.i_rgb(24'h123456),
 .i_exp(12'h200),.i_gain(4'd0),.i_state(2'd1),.i_writes(8'h0a),.i_luma(8'h80),.o_rgb(rgb));
integer x,offset;
initial begin
 repeat(4)@(negedge clk);rst=1;
 force dut.y_cnt=11'd48;
 for(x=0;x<1920;x=x+1)begin
  de=1;#1;
  offset=x-16;
  if(offset>=0 && offset<dut.SLOTS_W)begin
   if(dut.slot_q!==offset/9 || dut.slot_c!==(offset%9)%8)$fatal(1,"AE OSD address x=%0d",x);
  end
  @(posedge clk);#1;@(negedge clk);
 end
 release dut.y_cnt;
 $display("PASS AE OSD: parallel address mapping for every 1920 raster position");$finish;
end
endmodule
