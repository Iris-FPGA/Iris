`timescale 1ns/1ps
module tb_style_dequant #(parameter SCALE_Q24=20591742);
reg clk=0; always #5 clk=~clk;
reg rst_n=0, valid=0; reg [31:0] rgba=0;
wire out_valid; wire [23:0] rgb;
iris_style_dequant #(.SCALE_Q24(SCALE_Q24)) dut(clk,rst_n,valid,rgba,out_valid,rgb);
reg [32:0] stimulus[0:1023]; reg [24:0] reference[0:1023];
reg [1023:0] in_path,ref_path;
integer count=0;
initial begin
    if(!$value$plusargs("IN=%s",in_path)||!$value$plusargs("REF=%s",ref_path)) $fatal(1,"paths missing");
    $readmemh(in_path,stimulus);$readmemh(ref_path,reference);
    repeat(3) @(negedge clk);rst_n=1;
    for(integer i=0;i<1024;i=i+1)begin
        @(negedge clk);{valid,rgba}=stimulus[i];
        @(posedge clk);#1;
        if(i>0)begin
            if({out_valid,rgb}!==reference[i-1]) $fatal(1,"dequant %0d got %h expected %h",i-1,{out_valid,rgb},reference[i-1]);
            count=count+1;
        end
    end
    @(negedge clk);valid=0;rgba=0;
    @(posedge clk);#1;
    if({out_valid,rgb}!==reference[1023])$fatal(1,"final pixel lost");
    @(negedge clk);rst_n=0;#1;if(out_valid!==0)$fatal(1,"reset valid");
    $display("PASS output dequantization: 1024 independent floating-reference RGB pixels, saturation, pipeline/valid/reset");$finish;
end
initial begin #200000; $fatal(1,"watchdog");end
endmodule
