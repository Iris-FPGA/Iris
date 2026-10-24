`timescale 1ns/1ps
module tb_stream_cnn;
    parameter W=16,H=12,D=2;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,start=0,abort=0;
    reg [31:0] parameters [0:155];
    reg [31:0] image [0:W*H-1];
    reg [31:0] reference [0:W*H/4-1];
    reg [31:0] reference0 [0:W*H/4-1],reference1 [0:W*H/4-1];
    reg pv=0;reg[5:0]pi=0;reg[31:0]pd=0;integer layer=0;
    wire [2:0] configured,done;
    wire [31:0] pixel_counts [0:2];
    reg iv=0;reg [31:0]ip=0;wire ir;
    wire v0,v1,v2,r0,r1;wire[31:0]p0,p1,p2;
    reg r2=0;
    iris_stream_conv #(.WIDTH(W),.HEIGHT(H),.STRIDE(2),.KERNEL(3),.DILATION(1)) a(
        .clk(clk),.rst_n(rst_n),.start(start),.abort(abort),
        .parameter_valid(pv && layer==0),.parameter_index(pi),.parameter_value(pd),.parameters_ready(configured[0]),
        .i_valid(iv),.i_pixel(ip),.i_ready(ir),.o_valid(v0),.o_pixel(p0),.o_ready(r0),.frame_done(done[0]),.pixel_count(pixel_counts[0]));
    iris_stream_conv #(.WIDTH(W/2),.HEIGHT(H/2),.STRIDE(1),.KERNEL(3),.DILATION(D)) b(
        .clk(clk),.rst_n(rst_n),.start(start),.abort(abort),
        .parameter_valid(pv && layer==1),.parameter_index(pi),.parameter_value(pd),.parameters_ready(configured[1]),
        .i_valid(v0),.i_pixel(p0),.i_ready(r0),.o_valid(v1),.o_pixel(p1),.o_ready(r1),.frame_done(done[1]),.pixel_count(pixel_counts[1]));
    iris_stream_conv #(.WIDTH(W/2),.HEIGHT(H/2),.STRIDE(1),.KERNEL(1),.DILATION(1)) c(
        .clk(clk),.rst_n(rst_n),.start(start),.abort(abort),
        .parameter_valid(pv && layer==2),.parameter_index(pi),.parameter_value(pd),.parameters_ready(configured[2]),
        .i_valid(v1),.i_pixel(p1),.i_ready(r1),.o_valid(v2),.o_pixel(p2),.o_ready(r2),.frame_done(done[2]),.pixel_count(pixel_counts[2]));
    string dir;integer sent=0,received=0,cycles=0;reg[31:0]prng=32'h83216325;
    reg held=0;reg[31:0]held_pixel;reg source_consumed;
    integer seen0=0,seen1=0;
    always @(posedge clk)begin
        if($test$plusargs("TRACE") && a.quant_fire && a.out_x==0 && a.out_y==0)
            $display("acc3=%d sum3=%d bias3=%d mult3=%d shift3=%d zp=%d min=%d max=%d",a.acc[3],a.sums[3],a.bias[3],a.multiplier[3],a.shift[3],a.output_zero,a.activation_min,a.activation_max);
        if($test$plusargs("TRACE") && a.g_quant[3].u_quant.v[2] && a.out_x==0 && a.out_y==0)
            $display("q3 high=%d rounded=%d translated=%d",a.g_quant[3].u_quant.high,a.g_quant[3].u_quant.rounded,a.g_quant[3].u_quant.translated);
        if(start)begin seen0=0;seen1=0;end
        else begin
            if(v0 && r0)begin
                if(p0!==reference0[seen0])$fatal(1,"layer0 mismatch pixel=%0d got=%h expected=%h",seen0,p0,reference0[seen0]);
                seen0=seen0+1;
            end
            if(v1 && r1)begin
                if(p1!==reference1[seen1])$fatal(1,"layer1 mismatch pixel=%0d got=%h expected=%h",seen1,p1,reference1[seen1]);
                seen1=seen1+1;
            end
        end
    end
    task run_frame;
        begin
            sent=0;received=0;cycles=0;held=0;
            @(negedge clk);start=1;
            @(negedge clk);start=0;
            while(received<W*H/4)begin
                if(cycles>W*H*50+10000)$fatal(1,"CNN timeout sent=%0d received=%0d",sent,received);
                if(held && (!v2 || p2!==held_pixel))$fatal(1,"output changed under backpressure");
                held=v2 && !r2;held_pixel=p2;
                source_consumed=iv && ir;
                if(source_consumed)sent=sent+1;
                if(v2 && r2)begin
                    if(p2!==reference[received])$fatal(1,"CNN mismatch pixel=%0d got=%h expected=%h",received,p2,reference[received]);
                    received=received+1;
                end
                @(negedge clk);
                prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
                // Respect valid/data stability until the previous word is accepted.
                if(!iv || source_consumed)begin iv=sent<W*H && prng[0];ip=sent<W*H ? image[sent] : 0;end
                r2=prng[2] || prng[3];
                cycles=cycles+1;
                @(posedge clk);
            end
            @(negedge clk);iv=0;r2=1;
            repeat(3)@(negedge clk);
            if(sent!=W*H || done!==3'b111)$fatal(1,"incomplete frame sent=%0d done=%b",sent,done);
            $display("CNN bit-exact W=%0d H=%0d D=%0d pixels=%0d cycles=%0d",W,H,D,received,cycles);
        end
    endtask
    initial begin
        if(!$value$plusargs("DIR=%s",dir))$fatal(1,"fixture directory required");
        $readmemh({dir,"/parameters.mem"},parameters);$readmemh({dir,"/input.mem"},image);$readmemh({dir,"/output-low.mem"},reference);
        $readmemh({dir,"/output-0.mem"},reference0);$readmemh({dir,"/output-1.mem"},reference1);
        repeat(3)@(negedge clk);rst_n=1;
        for(layer=0;layer<3;layer=layer+1)for(integer k=0;k<52;k=k+1)begin
            pv=1;pi=k;pd=parameters[layer*52+k];@(negedge clk);
        end
        pv=0;
        if(configured!==3'b111)$fatal(1,"parameter load incomplete %b",configured);
        run_frame();run_frame();
        $display("PASS streaming CNN independent integer oracle and frame restart");$finish;
    end
endmodule
