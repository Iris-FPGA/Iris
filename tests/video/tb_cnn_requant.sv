`timescale 1ns/1ps
module tb_cnn_requant;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,i_valid=0;
    reg signed[31:0]i_value=0,i_multiplier=0;
    reg signed[7:0]i_shift=0,i_zero=0,i_min=0,i_max=0;
    wire o_valid;wire[7:0]o_value;
    iris_cnn_requant dut(.*);
    reg[95:0]stim[0:8191];reg[7:0]refdata[0:8191];
    string a,b;integer received=0;
    always @(posedge clk)if(rst_n && o_valid)begin
        if(o_value!==refdata[received])$fatal(1,"quant mismatch %0d got=%h expected=%h",received,o_value,refdata[received]);
        received=received+1;
    end
    initial begin
        if(!$value$plusargs("IN=%s",a) || !$value$plusargs("REF=%s",b))$fatal(1,"fixtures required");
        $readmemh(a,stim);$readmemh(b,refdata);
        repeat(3)@(negedge clk);rst_n=1;
        for(integer j=0;j<8192;j=j+1)begin
            {i_value,i_multiplier,i_shift,i_zero,i_min,i_max}=stim[j];i_valid=1;@(negedge clk);
            if(j%11==0)begin i_valid=0;@(negedge clk);end
        end
        i_valid=0;repeat(6)@(negedge clk);
        if(received!=8192)$fatal(1,"quant count %0d",received);
        $display("PASS CNN requant 8192 signed, ties, shifts, saturation and pipeline fixtures");$finish;
    end
endmodule
