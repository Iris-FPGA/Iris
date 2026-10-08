`timescale 1ns/1ps
module tb_stream_subsystem;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,valid=0,ready=1;reg[9:0]fn=0;reg[31:0]a=0,b=0;
    reg arready=0,rvalid=0,rlast=0,awready=1,wready=1,bvalid=0;
    wire arv,rr;wire[31:0]ara;wire[7:0]arlen;wire[2:0]ars;
    tinyml_subsystem #(.ENABLE_STREAM_CNN(1))dut(.clk(clk),.rst_n(1'b1),
        .acc_arready(arready),.acc_rvalid(rvalid),.acc_rlast(rlast),.acc_rresp(2'b0),
        .acc_rdata(128'h80000000800000008000000080000000),
        .acc_awready(awready),.acc_wready(wready),.acc_bvalid(bvalid),.acc_bresp(2'b0),
        .acc_arvalid(arv),.acc_araddr(ara),.acc_arlen(arlen),.acc_arsize(ars),.acc_rready(rr));
    task command(input[9:0]f,input[31:0]x,y,expected);
        begin
            @(negedge clk);fn=f;a=x;b=y;valid=1;
            while(!dut.ci_cmd_ready)@(negedge clk);
            @(negedge clk);valid=0;
            while(!dut.ci_rsp_valid)@(negedge clk);
            if(dut.ci_outputs_0!==expected)$fatal(1,"CI %h got=%h expected=%h",f,dut.ci_outputs_0,expected);
            @(negedge clk);
        end
    endtask
    initial begin
        force dut.io_systemReset=reset;
        force dut.ci_cmd_valid=valid;force dut.ci_function_id=fn;
        force dut.ci_inputs_0=a;force dut.ci_inputs_1=b;force dut.ci_rsp_ready=ready;
        repeat(3)@(negedge clk);reset=0;
        command('h000,0,0,'hffffffff); // Removed vendor engine cannot masquerade as a fallback.
        command('h240,0,0,'h49430101);command('h242,0,0,'h01e00280);
        command('h200,0,0,'h49520101);
        command('h241,'h03000000,'h03400000,0);
        command('h245,0,0,'hffffffff);
        force dut.g_cnn.u_cnn.configured=3'b111;
        command('h245,0,0,0);
        wait(arv);if(ara!='h03000000 || arlen!=15 || ars!=4)$fatal(1,"CNN native AXI mapping");
        command('h244,0,0,'hfffffffe);
        command('h201,'h07000000,'h07100000,0);command('h202,1,4,0);command('h203,4,0,0);
        command('h208,0,0,'hfffffffe);
        command('h247,0,0,0);
        if(!dut.cnn_busy || !arv)$fatal(1,"CNN released published AR on abort");
        @(negedge clk);arready=1;@(negedge clk);arready=0;
        wait(rr);
        for(integer k=0;k<16;k=k+1)begin
            @(negedge clk);rvalid=1;rlast=k==15;
        end
        @(negedge clk);rvalid=0;rlast=0;
        wait(!dut.cnn_busy);
        command('h208,0,0,0);wait(arv);
        command('h245,0,0,'hfffffffe);
        command('h206,0,0,0);
        @(negedge clk);arready=1;@(negedge clk);arready=0;
        wait(rr);@(negedge clk);rvalid=1;rlast=1;@(negedge clk);rvalid=0;
        wait(!dut.resize_busy);
        if(dut.vendor_reads || dut.vendor_writes || dut.accel_cmd_int)$fatal(1,"inactive owner leaked state");
        $display("PASS CNN/resize CI decoding, vendor rejection, DMA ownership and abort drain");$finish;
    end
    initial begin #2000000;$fatal(1,"integration timeout");end
endmodule
