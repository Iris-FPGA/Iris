`timescale 1ns/1ps
module tb_stream_cnn_dma;
    parameter W=16,H=12,D=2;
    localparam BEATS=W*H/4;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,vendor_idle=1,cmd_valid=0,rsp_ready=1;
    reg[9:0]cmd_function_id=0;reg[31:0]cmd_inputs_0=0,cmd_inputs_1=0;
    wire cmd_ready,rsp_valid,busy,irq;wire[31:0]rsp_outputs_0;
    wire[31:0]araddr,awaddr;wire[7:0]arlen,awlen;
    wire arvalid,rready,awvalid,wvalid,wlast,bready;wire[127:0]wdata;
    reg arready=0,awready=0,wready=0,rvalid=0,rlast=0,bvalid=0;
    reg[127:0]rdata=0;reg[1:0]rresp=0,bresp=0;
    iris_stream_cnn #(.WIDTH(W),.HEIGHT(H),.DILATION(D))dut(.*);
    reg[31:0]parameters[0:155],image[0:W*H-1];
    reg[127:0]reference[0:BEATS-1];
    reg[31:0]prng=32'h814ed89b;
    integer cycle=0,read_index=0,read_n=0,read_addr=0,read_delay=0;
    integer write_index=0,write_n=0,write_addr=0,b_delay=0;
    integer writes=0,reads=0,scenario=0;
    reg read_pending=0,write_pending=0,started_w=0,was_w_stalled=0,was_aw_stalled=0,was_ar_stalled=0;
    reg[127:0]held_w;reg[31:0]held_aw,held_ar;reg[7:0]held_awlen,held_arlen;
    function automatic [127:0]input_beat(input integer idx);
        input_beat={image[idx*4+3],image[idx*4+2],image[idx*4+1],image[idx*4]};
    endfunction
    always @(posedge clk)begin
        if(!rst_n)begin cycle<=0;arready<=0;awready<=0;wready<=0;rvalid<=0;bvalid<=0;
            read_pending<=0;write_pending<=0;read_delay<=0;b_delay<=0;started_w<=0;
            was_w_stalled<=0;was_aw_stalled<=0;was_ar_stalled<=0;end
        else begin
            cycle<=cycle+1;prng<={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
            arready<=!read_pending && prng[0];awready<=!write_pending && prng[1];wready<=write_pending && prng[2];
            if(was_w_stalled && (!wvalid || wdata!==held_w))$fatal(1,"W stability");
            if(was_aw_stalled && (!awvalid || awaddr!==held_aw || awlen!==held_awlen))$fatal(1,"AW stability");
            if(was_ar_stalled && (!arvalid || araddr!==held_ar || arlen!==held_arlen))$fatal(1,"AR stability");
            if(started_w && !wvalid)$fatal(1,"bubble in staged burst");
            was_w_stalled<=wvalid && !wready;held_w<=wdata;
            was_aw_stalled<=awvalid && !awready;held_aw<=awaddr;held_awlen<=awlen;
            was_ar_stalled<=arvalid && !arready;held_ar<=araddr;held_arlen<=arlen;
            if(arvalid && arready)begin
                if(read_pending || araddr[3:0]!=0 || arlen>15)$fatal(1,"read contract");
                read_pending<=1;read_addr<=(araddr-32'h03000000)/16;read_n<=arlen+1;read_index<=0;read_delay<=7;
            end
            if(read_delay>0)begin
                read_delay<=read_delay-1;
                if(read_delay==1)begin
                    rdata<=input_beat(read_addr+read_index);rvalid<=1;rlast<=read_index==read_n-1;
                    rresp<=scenario==1 && read_index==2 ? 2 : 0;
                end
            end
            if(rvalid && rready)begin
                reads<=reads+1;rvalid<=0;
                if(rlast)read_pending<=0;
                else begin read_index<=read_index+1;read_delay<=prng[6:5]+1;end
            end
            if(awvalid && awready)begin
                if(write_pending || awaddr[3:0]!=0 || awlen>15)$fatal(1,"write contract");
                write_pending<=1;write_addr<=(awaddr-32'h03400000)/16;write_n<=awlen+1;write_index<=0;
            end
            if(wvalid && wready)begin
                if(!write_pending)$fatal(1,"W before AW");
                if(wlast!=(write_index==write_n-1))$fatal(1,"write LAST");
                if(scenario==0 && wdata!==reference[write_addr+write_index])
                    $fatal(1,"NN2x DMA mismatch beat=%0d got=%h expected=%h",write_addr+write_index,wdata,reference[write_addr+write_index]);
                started_w<=!wlast;writes<=writes+1;
                if(wlast)b_delay<=write_addr+write_n==BEATS ? 80 : 9;
                else write_index<=write_index+1;
            end
            if(b_delay>0)begin b_delay<=b_delay-1;if(b_delay==1)begin bvalid<=1;bresp<=scenario==2 ? 2 : 0;end end
            if(bvalid && bready)begin bvalid<=0;write_pending<=0;end
            if(irq && (write_pending || read_pending))$fatal(1,"completion before final B/drain");
        end
    end
    task command(input[9:0]fn,input[31:0]a,input[31:0]b,output[31:0]value);
        begin
            @(negedge clk);cmd_valid=1;cmd_function_id=fn;cmd_inputs_0=a;cmd_inputs_1=b;
            while(!cmd_ready)@(negedge clk);
            @(negedge clk);cmd_valid=0;
            while(!rsp_valid)@(negedge clk);
            value=rsp_outputs_0;
        end
    endtask
    reg[31:0]value;string dir;integer elapsed;
    task run(input integer sc);
        begin
            scenario=sc;writes=0;reads=0;
            command('h241,'h03000000,'h03400000,value);
            command('h245,0,0,value);if(value!=0)$fatal(1,"start rejected");
            if(sc==3)begin wait(wvalid && wready);command('h247,0,0,value);end
            elapsed=0;
            while(busy)begin @(negedge clk);elapsed=elapsed+1;if(elapsed>W*H*80+10000)$fatal(1,"DMA timeout rs=%d ws=%d",dut.rs,dut.ws);end
            command('h246,0,0,value);
            if(sc==0)begin
                if((value&7)!=2 || writes!=BEATS || reads!=BEATS || !irq)$fatal(1,"frame status %h read=%d write=%d",value,reads,writes);
                $display("DMA bit-exact W=%0d H=%0d D=%0d cycles=%0d",W,H,D,dut.last_cycles);
            end else if((value&7)!=4 || irq || write_pending || read_pending)$fatal(1,"failed task did not drain %h",value);
        end
    endtask
    initial begin
        if(!$value$plusargs("DIR=%s",dir))$fatal(1,"fixture directory required");
        $readmemh({dir,"/parameters.mem"},parameters);$readmemh({dir,"/input.mem"},image);
        $readmemh({dir,"/output-full.mem"},reference);
        repeat(3)@(negedge clk);rst_n=1;
        command('h240,0,0,value);if(value!='h49430101)$fatal(1,"ABI");
        command('h245,0,0,value);if(value!='hffffffff)$fatal(1,"unconfigured start accepted");
        for(integer layer=0;layer<3;layer=layer+1)for(integer k=0;k<52;k=k+1)
            command('h244,(layer<<8)|k,parameters[layer*52+k],value);
        command('h241,'h03000000,'h03000000,value);
        command('h245,0,0,value);if(value!='hffffffff)$fatal(1,"overlap accepted");
        run(0);run(0);
        if(W==16)begin run(1);run(0);run(2);run(0);run(3);run(0);end
        $display("PASS CNN DMA exact pixels, burst stability, final B, errors, abort drain, restart");$finish;
    end
endmodule
