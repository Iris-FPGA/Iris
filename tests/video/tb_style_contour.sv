`timescale 1ns/1ps
module tb_style_contour #(
 parameter SOURCE_MIX_Q2=3,parameter SATURATION_Q2=5,parameter COLOUR_BITS=5,
 parameter NORMAL_THRESHOLD=20,parameter NORMAL_INK_GAIN=2,parameter NORMAL_INK_CAP=128,
 parameter STRONG_THRESHOLD=40,parameter STRONG_INK_GAIN=4,parameter STRONG_INK_CAP=160
);
reg clk=0,rst_n=0,i_valid=0,i_first=0,i_last=0;
reg [1:0] i_mode=0;reg [79:0] i_grey_rows=0;reg [63:0] i_neural_rgba=0;
reg [47:0] i_source_rgb=0;
always #5 clk=~clk;
wire o_valid;wire [47:0] o_rgb;
iris_style_contour #(
 .SOURCE_MIX_Q2(SOURCE_MIX_Q2),.SATURATION_Q2(SATURATION_Q2),.COLOUR_BITS(COLOUR_BITS),
 .NORMAL_THRESHOLD(NORMAL_THRESHOLD),.NORMAL_INK_GAIN(NORMAL_INK_GAIN),.NORMAL_INK_CAP(NORMAL_INK_CAP),
 .STRONG_THRESHOLD(STRONG_THRESHOLD),.STRONG_INK_GAIN(STRONG_INK_GAIN),.STRONG_INK_CAP(STRONG_INK_CAP)
) dut(.*);
reg [196:0] stimulus[0:65535];reg [48:0] reference[0:65535];
reg [1023:0] in_path,ref_path;integer count;
initial begin
 if(!$value$plusargs("IN=%s",in_path)||!$value$plusargs("REF=%s",ref_path)||!$value$plusargs("COUNT=%d",count))$fatal(1,"paths/count missing");
 $readmemh(in_path,stimulus,0,count-1);$readmemh(ref_path,reference,0,count-1);
 repeat(3)@(negedge clk);rst_n=1;
 for(integer i=0;i<count+6;i=i+1)begin
  @(negedge clk);
  if(i<count){i_valid,i_first,i_last,i_mode,i_grey_rows,i_neural_rgba,i_source_rgb}=stimulus[i];
  else i_valid=0;
  @(posedge clk);#1;
  if(i>=5 && i-5<count)begin
   if(o_valid!==reference[i-5][48])$fatal(1,"contour valid latency vector=%0d",i-5);
   if(o_valid && o_rgb!==reference[i-5][47:0])$fatal(1,"contour vector=%0d got=%h ref=%h",i-5,o_rgb,reference[i-5][47:0]);
  end
 end
 @(negedge clk);rst_n=0;#1;if(o_valid!==0)$fatal(1,"contour reset");
 $display("PASS contour: %0d vectors, 5x5 convolution, grey neural + colour camera, borders, modes, saturation and pipeline",count);$finish;
end
initial begin #1000000;$fatal(1,"contour timeout");end
endmodule
