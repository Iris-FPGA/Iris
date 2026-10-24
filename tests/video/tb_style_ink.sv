`timescale 1ns/1ps
module tb_style_ink;
reg clk=0,rst_n=0,i_valid=0;reg [1:0] i_mode=0;reg [23:0] i_rgb=0;
always #5 clk=~clk;
wire o_valid;wire [23:0] o_rgb;
iris_style_ink dut(.*);
reg [26:0] input_vector[0:4095];reg [24:0] reference[0:4095];
reg [1023:0] in_path,ref_path;
initial begin
 if(!$value$plusargs("IN=%s",in_path)||!$value$plusargs("REF=%s",ref_path))$fatal(1,"paths missing");
 $readmemh(in_path,input_vector);$readmemh(ref_path,reference);
 repeat(3)@(negedge clk);rst_n=1;
 for(integer i=0;i<4096;i=i+1)begin
  @(negedge clk);{i_valid,i_mode,i_rgb}=input_vector[i];@(posedge clk);#1;
  if(i>0 && {o_valid,o_rgb}!==reference[i-1])$fatal(1,"ink vector %0d got=%h ref=%h",i-1,{o_valid,o_rgb},reference[i-1]);
 end
 @(negedge clk);i_valid=0;@(posedge clk);#1;
 if({o_valid,o_rgb}!==reference[4095])$fatal(1,"ink last pixel");
 @(negedge clk);rst_n=0;#1;if(o_valid!==0)$fatal(1,"ink reset");
 $display("PASS ink: 4096 independent RGB cases, all modes, saturation, valid and pipeline");$finish;
end
initial begin #100000;$fatal(1,"ink timeout");end
endmodule
