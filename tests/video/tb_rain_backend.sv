`timescale 1ns/1ps
module tb_rain_backend;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, vendor_idle=1, cmd_valid=0, rsp_ready=1;
    reg [9:0] cmd_function_id=0;
    reg [31:0] cmd_inputs_0=0, cmd_inputs_1=0;
    wire cmd_ready, rsp_valid, busy;
    wire [31:0] rsp_outputs_0, araddr, awaddr;
    wire arvalid, rready, awvalid, wvalid, wlast, bready;
    wire [7:0] arlen,awlen;
    wire [127:0] wdata;
    reg arready=0, awready=0, wready=0, rvalid=0, bvalid=0;
    reg [127:0] rdata=0;
    reg [1:0] rresp=0, bresp=0;
    reg rlast=1;
    wire irq;
    iris_rain_backend dut(.*);
    reg [7:0] mem[0:2097151];
    reg rd_pending=0, wr_pending=0;
    reg [31:0] rd_addr=0, wr_addr=0;
    integer rd_delay=0, wr_delay=0, writes=0, reads=0;
    integer rd_beats=0,wr_beats=0,read_requests=0,write_requests=0,cycles=0;
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
            cycles<=cycles+1;
            if (arvalid && arready) begin
                if (araddr[3:0]!=0) $fatal(1,"unaligned AR");
                if({1'b0,araddr[11:0]}+((arlen+1)*16)>4096)$fatal(1,"AR crossed 4K");
                rd_pending<=1; rd_addr<=araddr; rd_delay<=$urandom_range(0,4);
                rd_beats<=arlen+1;read_requests<=read_requests+1;
            end
            if (rd_pending && !rvalid) begin
                if (rd_delay!=0) rd_delay<=rd_delay-1;
                else begin
                    for (j=0;j<16;j=j+1) rdata[j*8+:8]<=mem[rd_addr+j];
                    rvalid<=1; rresp<=fail_read ? 2'b10 : 0;rlast<=rd_beats==1;
                end
            end
            if (rvalid && rready) begin
                rvalid<=0;reads<=reads+1;rd_beats<=rd_beats-1;rd_addr<=rd_addr+16;
                rd_delay<=$urandom_range(0,4);
                if(rlast)rd_pending<=0;
            end
            if (awvalid && awready) begin
                if(awaddr[3:0]!=0)$fatal(1,"unaligned AW");
                if({1'b0,awaddr[11:0]}+((awlen+1)*16)>4096)$fatal(1,"AW crossed 4K");
                wr_pending<=1;wr_addr<=awaddr;wr_beats<=awlen+1;write_requests<=write_requests+1;
            end
            if (wvalid && wready) begin
                if (!wr_pending) $fatal(1,"W before AW");
                for (j=0;j<16;j=j+1) mem[wr_addr+j]<=wdata[j*8+:8];
                if(wlast!=(wr_beats==1))$fatal(1,"incorrect WLAST");
                wr_addr<=wr_addr+16;wr_beats<=wr_beats-1;writes<=writes+1;
                if(wlast)begin wr_pending<=0;wr_delay<=$urandom_range(1,4);end
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
    reg [7:0] cfg_data[0:9];
    reg [63:0] inputs[0:65535],expected[0:65535];
    reg [127:0] weights[0:575];
    reg [31:0] parameters[0:95];
    string dir;
    integer input_words,output_words,weight_words,co,ci,h,w,stride,k,c,y,x,groups,bytes_out;
    localparam SRC='h10ff0,DST='h100ff0,WEIGHT='h80ff0;
    reg [7:0] add_input_a[0:262143],add_input_b[0:262143],add_expected[0:262143];
    reg [31:0] add_parameters[0:13];
    task test_add;
        integer size,z;
        begin
            $readmemh({dir,"/parameters.mem"},add_parameters);
            size=add_parameters[1];
            $readmemh({dir,"/a.mem"},add_input_a,0,size-1);
            $readmemh({dir,"/b.mem"},add_input_b,0,size-1);
            $readmemh({dir,"/output.mem"},add_expected,0,size-1);
            for(z=0;z<size;z=z+1)begin
                mem[SRC+z]=add_input_a[z];mem[add_parameters[0]+z]=add_input_b[z];mem[DST+z]='hcc;
            end
            repeat(4)@(negedge clk);rst_n=1;
            command('h261,SRC,DST);
            for(z=0;z<14;z=z+1)command('h262,z+8,add_parameters[z]);
            command('h264,1,0);if(response!=0)$fatal(1,"Add start rejected");
            await_idle();command('h265,0,0);if(response!=2)$fatal(1,"Add status %h",response);
            for(z=0;z<size;z=z+1)if(mem[DST+z]!==add_expected[z])
                $fatal(1,"Add mismatch at %0d got=%h expected=%h",z,mem[DST+z],add_expected[z]);
            command('h267,0,0);$display("PASS Rain DMA Add %s bytes=%0d cycles=%0d",dir,size,response);
            $finish;
        end
    endtask
    task configure;
        begin
            command('h261,SRC,DST);if(response!=0)$fatal(1,"addresses rejected");
            command('h262,0,w);command('h262,1,h);command('h262,2,ci);command('h262,3,co);
            command('h262,4,stride);command('h262,5,WEIGHT);command('h262,6,weight_words*16);
            command('h262,7,{cfg_data[8],cfg_data[7],cfg_data[6],cfg_data[5]});
            for(k=0;k<96;k=k+1)begin command('h263,k,parameters[k]);if(response!=0)$fatal(1,"params");end
        end
    endtask
    task await_idle;
        integer n;
        begin
            n=0;while(busy && n<1000000)begin @(negedge clk);n=n+1;end
            if(busy)$fatal(1,"backend timeout phase=%0d read=%0d write=%0d corestate=%0d iy=%0d oy=%0d iw=%0d ow=%0d pack=%0d",
                dut.phase,dut.read_state,dut.write_state,dut.u_conv.state,dut.u_conv.iy,dut.u_conv.oy,dut.input_count,dut.output_words,dut.output_count);
            if(rd_pending || wr_pending || rvalid || bvalid)$fatal(1,"ownership released before responses drained");
        end
    endtask
    task reject_start;
        integer old_reads,old_writes;
        begin
            old_reads=reads;old_writes=writes;command('h264,0,0);
            if(response!='hffffffff || busy || reads!=old_reads || writes!=old_writes)$fatal(1,"invalid Conv accepted");
        end
    endtask
    task test_faults;
        begin
            command('h264,0,0);if(response!='hffffffff)$fatal(1,"stale configuration reused");
            configure();command('h262,0,'h40000080);reject_start();
            command('h262,0,w);command('h262,2,'h40000008);reject_start();
            command('h262,2,ci);command('h262,6,16);reject_start();
            command('h262,6,weight_words*16);command('h263,64,32);reject_start();
            command('h263,64,parameters[64]);command('h261,'hfffffff0,DST);reject_start();
            command('h261,SRC,SRC);reject_start();command('h261,SRC,DST);
            vendor_idle=0;command('h264,0,0);
            if(response!='hfffffffe || busy)$fatal(1,"vendor ownership not respected");vendor_idle=1;
            fail_read=1;command('h264,0,0);await_idle();command('h265,0,0);
            if(response!=4)$fatal(1,"R error status %h",response);fail_read=0;
            configure();hold_write=1;command('h264,0,0);wait(wvalid);
            command('h261,SRC+16,DST+16);if(response!='hffffffff)$fatal(1,"busy config accepted");
            command('h266,0,0);repeat(16)@(negedge clk);
            if(!busy || !wvalid)$fatal(1,"abort released W ownership early");
            hold_write=0;await_idle();command('h265,0,0);
            if(response!=12)$fatal(1,"abort status %h",response);
            configure();fail_write=1;command('h264,0,0);await_idle();command('h265,0,0);
            if(response!=4)$fatal(1,"B error status %h",response);fail_write=0;
            $display("PASS Rain DMA invalid dimensions/parameters/ranges, R/B errors and abort drain");
        end
    endtask
    initial begin
        if(!$value$plusargs("DIR=%s",dir))$fatal(1,"missing DIR");
        if($test$plusargs("ADD"))test_add();
        $readmemh({dir,"/config.mem"},cfg_data);
        w=cfg_data[0];h=cfg_data[1];ci=cfg_data[2];co=cfg_data[3];stride=cfg_data[4] ? 2 : 1;
        input_words=w*h*((ci+7)/8);output_words=(w/stride)*(h/stride)*((co+7)/8);
        weight_words=9*((ci+7)/8)*((co+7)/8)*4;
        bytes_out=(w/stride)*(h/stride)*co;
        $readmemh({dir,"/input.mem"},inputs,0,input_words-1);
        $readmemh({dir,"/output.mem"},expected,0,output_words-1);
        $readmemh({dir,"/weights.mem"},weights,0,weight_words-1);
        $readmemh({dir,"/parameters.mem"},parameters);
        for(k=0;k<w*h;k=k+1)for(c=0;c<ci;c=c+1)mem[SRC+k*ci+c]=inputs[k*((ci+7)/8)+c/8][(c%8)*8+:8];
        for(k=0;k<weight_words;k=k+1)for(c=0;c<16;c=c+1)mem[WEIGHT+k*16+c]=weights[k][c*8+:8];
        for(k=-16;k<bytes_out+16;k=k+1)mem[DST+k]='hcc;
        repeat(4)@(negedge clk);rst_n=1;
        command('h260,0,0);if(response!='h49500101)$fatal(1,"capability");
        // Hold the first bank's write long enough for the next computed row
        // to fill the alternate bank. It must then wait without overwriting
        // either row, and completion must retain AXI ownership.
        if($test$plusargs("BACKPRESSURE"))begin
            hold_write=1;
            fork
                begin
                    wait(wvalid);repeat(12000)@(negedge clk);
                    if(!busy || !wvalid)$fatal(1,"row backpressure released ownership");
                    hold_write=0;
                end
            join_none
        end
        configure();command('h264,0,0);if(response!=0)$fatal(1,"Conv start rejected %h",response);
        await_idle();command('h265,0,0);if(response!=2)$fatal(1,"Conv status %h",response);
        for(k=0;k<(w/stride)*(h/stride);k=k+1)for(c=0;c<co;c=c+1)
            if(mem[DST+k*co+c]!==expected[k*((co+7)/8)+c/8][(c%8)*8+:8])
                $fatal(1,"Conv mismatch pixel=%0d channel=%0d got=%h expected=%h",k,c,mem[DST+k*co+c],expected[k*((co+7)/8)+c/8][(c%8)*8+:8]);
        for(k=0;k<16;k=k+1)if(mem[DST-16+k]!=='hcc || mem[DST+bytes_out+k]!=='hcc)$fatal(1,"Conv overrun");
        command('h267,0,0);$display("PASS Rain DMA Conv %s cycles=%0d AR=%0d AW=%0d",dir,response,read_requests,write_requests);
        // The next layer starts with the previous core's done flag still
        // asserted during weight loading. It must not finish before the new
        // start pulse clears that flag and the full next tensor is written.
        for(k=0;k<bytes_out;k=k+1)mem[DST+k]='hcc;
        configure();command('h264,0,0);if(response!=0)$fatal(1,"second Conv rejected");
        await_idle();command('h265,0,0);if(response!=2)$fatal(1,"second Conv status");
        for(k=0;k<(w/stride)*(h/stride);k=k+1)for(c=0;c<co;c=c+1)
            if(mem[DST+k*co+c]!==expected[k*((co+7)/8)+c/8][(c%8)*8+:8])
                $fatal(1,"second Conv incomplete/mismatched pixel=%0d channel=%0d",k,c);
        $display("PASS Rain DMA consecutive Conv restart %s",dir);
        if($test$plusargs("FAULTS"))test_faults();
        $finish;
    end
    initial begin #15000000;$fatal(1,"timeout");end
endmodule
