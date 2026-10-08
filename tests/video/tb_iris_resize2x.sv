`timescale 1ns/1ps
module tb_iris_resize2x;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, vendor_idle=1, cmd_valid=0, rsp_ready=1;
    reg [9:0] cmd_function_id=0;
    reg [31:0] cmd_inputs_0=0, cmd_inputs_1=0;
    wire cmd_ready, rsp_valid, busy;
    wire [31:0] rsp_outputs_0, araddr, awaddr;
    wire arvalid, rready, awvalid, wvalid, bready;
    wire [127:0] wdata;
    reg arready=0, awready=0, wready=0, rvalid=0, bvalid=0;
    reg [127:0] rdata=0;
    reg [1:0] rresp=0, bresp=0;
    reg rlast=1;
    iris_resize2x dut(.*);
    reg [7:0] mem[0:1048575];
    reg rd_pending=0, wr_pending=0;
    reg [31:0] rd_addr=0, wr_addr=0;
    integer rd_delay=0, wr_delay=0, writes=0, reads=0;
    reg fail_read=0, fail_write=0, hold_write=0, hold_response=0;
    integer j;
    // Independent byte-addressed AXI slave; randomized command, data and
    // response delays. Responses stay valid until accepted.
    always @(negedge clk) begin
        arready <= rst_n && !rd_pending && !rvalid && ($urandom_range(0,3)!=0);
        awready <= rst_n && !wr_pending && !bvalid && ($urandom_range(0,3)!=0);
        wready <= rst_n && wr_pending && !hold_write && ($urandom_range(0,3)!=0);
    end
    always @(posedge clk) begin
        if (!rst_n) begin rd_pending<=0; wr_pending<=0; rvalid<=0; bvalid<=0; end
        else begin
            if (arvalid && arready) begin
                if (araddr[3:0]!=0) $fatal(1,"unaligned AR");
                rd_pending<=1; rd_addr<=araddr; rd_delay<=$urandom_range(0,4); reads<=reads+1;
            end
            if (rd_pending && !rvalid) begin
                if (rd_delay!=0) rd_delay<=rd_delay-1;
                else begin
                    for (j=0;j<16;j=j+1) rdata[j*8+:8]<=mem[rd_addr+j];
                    rvalid<=1; rresp<=fail_read ? 2'b10 : 0;
                end
            end
            if (rvalid && rready) begin rvalid<=0; rd_pending<=0; end
            if (awvalid && awready) begin wr_pending<=1; wr_addr<=awaddr; end
            if (wvalid && wready) begin
                if (!wr_pending) $fatal(1,"W before AW");
                for (j=0;j<16;j=j+1) mem[wr_addr+j]<=wdata[j*8+:8];
                wr_pending<=0; wr_delay<=$urandom_range(1,4); writes<=writes+1;
            end
            if (wr_delay>0) begin
                if (wr_delay==1 && !hold_response) begin bvalid<=1; bresp<=fail_write ? 2'b10 : 0; wr_delay<=0; end
                else if (wr_delay>1) wr_delay<=wr_delay-1;
            end
            if (bvalid && bready) bvalid<=0;
        end
    end
    reg [31:0] response;
    task command(input [9:0] id,input [31:0] a,input [31:0] b);
        begin
            @(negedge clk);cmd_valid=1;cmd_function_id=id;cmd_inputs_0=a;cmd_inputs_1=b;
            do @(posedge clk); while (!cmd_ready);
            @(negedge clk);cmd_valid=0;
            while (!rsp_valid) @(negedge clk);
            response=rsp_outputs_0;
            @(posedge clk);@(negedge clk);
        end
    endtask
    task configure(input integer h,input integer w,input integer c,input integer dst);
        begin command('h201,'h10000,dst);command('h202,h,w);command('h203,c,0); end
    endtask
    task await_idle;
        integer cycles;
        begin
            cycles=0;
            while (busy && cycles<500000) begin @(negedge clk);cycles=cycles+1; end
            if (busy) $fatal(1,"DMA did not terminate");
        end
    endtask
    task check_shape(input integer h,input integer w,input integer c);
        integer y,x,ch,k;
        begin
            for(k=0;k<h*w*c;k=k+1) mem['h10000+k]=(k*73+17) & 255;
            for(k=0;k<h*w*c*4+16;k=k+1) mem['h30000+k]=8'hcc;
            configure(h,w,c,'h30000);command('h204,0,0);
            if (response!=0) $fatal(1,"valid shape rejected");
            await_idle();command('h205,0,0);
            if (response!=2) $fatal(1,"bad success status %h",response);
            for(y=0;y<2*h;y=y+1) for(x=0;x<2*w;x=x+1) for(ch=0;ch<c;ch=ch+1)
                if(mem['h30000+(y*2*w+x)*c+ch] !== mem['h10000+((y/2)*w+x/2)*c+ch])
                    $fatal(1,"pixel mismatch shape=%0d,%0d,%0d at %0d,%0d,%0d",h,w,c,y,x,ch);
            for(k=0;k<16;k=k+1) if(mem['h30000+h*w*c*4+k]!==8'hcc) $fatal(1,"wrote past tensor");
            $display("PASS resize %0dx%0dx%0d",h,w,c);
        end
    endtask
    task check_copy(input integer h,input integer w,input integer c);
        integer k, old_reads, old_writes;
        begin
            for(k=0;k<h*w*c;k=k+1) mem['h10000+k]=(k*113+41)&255;
            for(k=0;k<h*w*c+16;k=k+1) mem['h30000+k]=8'hcc;
            configure(h,w,c,'h30000);old_reads=reads;old_writes=writes;
            command('h208,0,0);if(response!=0)$fatal(1,"copy rejected");
            await_idle();command('h205,0,0);if(response!=2)$fatal(1,"copy status");
            for(k=0;k<h*w*c;k=k+1)
                if(mem['h10000+k]!==mem['h30000+k])$fatal(1,"copy byte mismatch %0d",k);
            for(k=0;k<16;k=k+1)if(mem['h30000+h*w*c+k]!==8'hcc)$fatal(1,"copy overrun");
            if(reads-old_reads!=h*w*c/16 || writes-old_writes!=h*w*c/16)$fatal(1,"copy beat count");
            $display("PASS DMA copy %0dx%0dx%0d",h,w,c);
        end
    endtask
    task check_stream;
        integer k,w,b,old_writes;
        reg [31:0] got;
        begin
            for(k=0;k<48;k=k+1)mem['h10000+k]=(k%4==3) ? 8'h80 : (k*19+5)&255;
            old_writes=writes;configure(3,4,4,0);command('h20f,0,0);
            if(response!=0)$fatal(1,"stream start rejected");
            for(k=0;k<48;k=k+16)begin
                command('h205,0,0);
                while(!response[3])begin
                    if(!response[0])$fatal(1,"stream finished early");
                    command('h205,0,0);
                end
                for(w=0;w<4;w=w+1)begin
                    command('h20a+w,0,0);got=response;
                    for(b=0;b<4;b=b+1)if(got[b*8+:8]!==mem['h10000+k+4*w+b])$fatal(1,"stream sample mismatch");
                end
                command('h20e,0,0);if(response!=0)$fatal(1,"stream ack rejected");
            end
            command('h205,0,0);if(response!=2)$fatal(1,"stream did not complete");
            command('h209,0,0);if(response!=0)$fatal(1,"dummy audit false positive");
            if(writes!=old_writes)$fatal(1,"read-only stream wrote DDR");
            mem['h10003]=8'h81;configure(1,4,4,0);command('h20f,0,0);
            command('h205,0,0);while(!response[3])command('h205,0,0);
            command('h209,0,0);if(response!=1)$fatal(1,"dummy violation missed");
            command('h206,0,0);await_idle();command('h205,0,0);
            if(!response[2] || response[1])$fatal(1,"stream abort status");
            $display("PASS read-only CI tensor stream: samples, audit, no writes, abort");
        end
    endtask
    integer before_writes;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        command('h200,0,0);if(response!='h49520101)$fatal(1,"capability");
        command('h2ff,0,0);if(response!='hffffffff)$fatal(1,"unknown command hangs");
        check_shape(32,32,32);check_shape(64,64,16);
        check_shape(3,4,4);check_shape(3,2,8);check_shape(3,1,16);check_shape(3,1,32);
        check_stream();
        check_copy(3,4,4);check_copy(3,2,8);check_copy(3,1,16);check_copy(3,1,32);
        check_copy(48,640,4);check_shape(2,4,4);
        configure(1,1,4,'h30000);before_writes=writes;command('h204,0,0);
        if(response!='hffffffff || busy || writes!=before_writes)$fatal(1,"invalid row accepted");
        configure(1,4,4,'h10000);command('h204,0,0);if(response!='hffffffff)$fatal(1,"overlap accepted");
        configure(1,4,4,'h30000);vendor_idle=0;command('h204,0,0);
        if(response!='hfffffffe || busy)$fatal(1,"vendor not idle");vendor_idle=1;
        fail_read=1;command('h204,0,0);await_idle();command('h205,0,0);
        if(!response[2] || response[1])$fatal(1,"read error reported done");fail_read=0;
        fail_write=1;command('h204,0,0);await_idle();command('h205,0,0);
        if(!response[2] || response[1])$fatal(1,"write error reported done");fail_write=0;
        hold_write=1;command('h204,0,0);wait(wvalid);
        command('h201,'h20000,'h40000);if(response!='hfffffffe)$fatal(1,"busy config changed");
        command('h206,0,0);repeat(10)@(negedge clk);if(!busy)$fatal(1,"abort dropped published AW");
        hold_response=1;hold_write=0;wait(bready);repeat(10)@(negedge clk);
        if(!busy)$fatal(1,"abort reused memory before B");hold_response=0;await_idle();
        command('h205,0,0);if(!response[2] || response[1])$fatal(1,"abort status");
        check_shape(2,4,4);
        $display("PASS: tb_iris_resize2x reads=%0d writes=%0d",reads,writes);$finish;
    end
    initial begin #100000000;$fatal(1,"test timeout");end
endmodule
