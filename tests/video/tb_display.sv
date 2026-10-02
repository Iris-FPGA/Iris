`timescale 1ns/1ps
module tb_display;
localparam N=1536;
reg clk=0,rst=0;
always #5 clk=~clk;
reg [59:0] vectors [0:N-1];
reg [50:0] expected [0:N-1];
reg [59:0] v=0;
reg [1023:0] infile,reffile;
wire [50:0] output_v;
rgb_display_2px dut(.clk(clk),.rst_n(rst),.i_hs(v[59]),.i_vs(v[58]),.i_de(v[57]),
 .i_rgb(v[56:9]),.i_r_gain(v[8:6]),.i_g_gain(v[5:3]),.i_b_gain(v[2:0]),
 .o_hs(output_v[50]),.o_vs(output_v[49]),.o_de(output_v[48]),.o_rgb(output_v[47:0]));
integer t;
initial begin
 if(!$value$plusargs("IN=%s",infile)||!$value$plusargs("REF=%s",reffile))$fatal(1,"Fixtures");
 $readmemh(infile,vectors);$readmemh(reffile,expected);
 repeat(4)@(negedge clk);rst=1;
 for(t=0;t<N+1;t=t+1)begin
  v=(t<N)?vectors[t]:0;
  @(posedge clk);#1;
  if(t>0 && output_v!==expected[t-1])$fatal(1,"Gain/gamma/sync t=%0d got=%h exp=%h",t,output_v,expected[t-1]);
  @(negedge clk);
 end
 $display("PASS display: exhaustive 256 levels x 6 gains, saturation and raster alignment");$finish;
end
endmodule
