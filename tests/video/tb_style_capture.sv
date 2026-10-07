`timescale 1ns/1ps
module tb_style_capture;
reg clk=0,video_clk=0,rst_n=0;
always #5 clk=~clk;
always #7 video_clk=~video_clk;
reg request=0,pair=0,i_vs=0,i_valid=0,i_sof=0,i_eof=0;
reg [31:0] i_rgba=0;
wire busy,done,error,capture_enable,awvalid,wvalid,wlast,bready;
wire [31:0] awaddr;wire [7:0] awlen;wire [127:0] wdata;
reg awready=0,wready=0,bvalid=0;reg [1:0] bresp=0;
iris_style_capture #(.FRAME_WORDS(64),.FIFO_AW(5)) dut(.*);
integer cycle=0,beats=0,bursts=0,pending=0,delay_b=0,scenario=0;
reg [31:0] address;
reg stall=0,inject_error=0;
reg [127:0] held;reg was_stalled=0;
function [31:0] pixel(input integer i);pixel=32'h80000000 | (i*32'h010203);endfunction
always @(posedge clk)begin
    if(!rst_n)begin
        cycle<=0;awready<=0;wready<=0;bvalid<=0;pending<=0;was_stalled<=0;
    end else begin
        cycle<=cycle+1;awready<=!pending && cycle%5!=0;
        wready<=pending && !stall && cycle%4!=0;
        if(was_stalled && (wdata!==held || !wvalid))$fatal(1,"W changed under backpressure");
        was_stalled<=wvalid && !wready;held<=wdata;
        if(awvalid && awready)begin
            if(pending)$fatal(1,"multiple writes in flight");
            if(awlen!=15 || awaddr[7:0]!=0)$fatal(1,"burst geometry");
            if(awaddr!=(pair ? 32'h03200000 : 32'h03000000)+bursts*256)$fatal(1,"address");
            address<=awaddr;pending<=1;beats<=0;
        end
        if(wvalid && wready)begin
            if(!pending)$fatal(1,"W before AW");
            if(wlast!=(beats==15))$fatal(1,"LAST mismatch");
            if(scenario==0 || scenario==1)begin
                for(integer k=0;k<4;k=k+1)
                    if(wdata[k*32+:32]!==pixel((bursts*16+beats)*4+k))$fatal(1,"pixel order");
            end
            if(wlast)begin bursts<=bursts+1;delay_b<=13;end
            else beats<=beats+1;
        end
        if(delay_b>0)begin
            delay_b<=delay_b-1;
            if(delay_b==1)begin bvalid<=1;bresp<=inject_error ? 2'b10 : 0;end
        end
        if(bvalid && bready)begin bvalid<=0;pending<=0;end
        if(done && pending)$fatal(1,"published before B");
    end
end
task start(input integer sc);
    begin
        wait(!busy);@(negedge clk);scenario=sc;bursts=0;beats=0;pair=sc%2;
        inject_error=sc==1;request=1;@(negedge clk);request=0;
        wait(capture_enable);repeat(3)@(negedge video_clk);
        i_vs=1;@(negedge video_clk);i_vs=0;
    end
endtask
task send_pixels(input integer n,input bit eof);
    for(integer i=0;i<n;i=i+1)begin
        @(negedge video_clk);i_valid=1;i_sof=i==0;i_eof=eof && i==n-1;i_rgba=pixel(i);
        @(negedge video_clk);i_valid=0;i_sof=0;i_eof=0;
    end
endtask
initial begin
    repeat(4)@(negedge clk);rst_n=1;
    start(0);send_pixels(256,1);wait(done);
    if(error || bursts!=4)$fatal(1,"complete frame failed");
    start(1);send_pixels(256,1);wait(done);
    if(!error)$fatal(1,"B error published success");
    start(2);send_pixels(20,0);repeat(3)@(negedge video_clk);
    i_vs=1;@(negedge video_clk);i_vs=0;wait(done);
    if(!error || pending)$fatal(1,"short frame must drain accepted burst");
    stall=1;start(3);send_pixels(256,1);repeat(40)@(negedge clk);stall=0;wait(done);
    if(!error || pending)$fatal(1,"overflow must drain accepted burst");
    start(0);send_pixels(256,1);wait(done);
    if(error || bursts!=4)$fatal(1,"recovery after errors");
    $display("PASS style capture: order, backpressure, final B, B errors, short frame, overflow, recovery");$finish;
end
initial begin #2000000;$fatal(1,"capture timeout state=%d level=%d words=%d",dut.state,dut.fifo_level,dut.words);end
endmodule
