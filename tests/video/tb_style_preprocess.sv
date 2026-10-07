`timescale 1ns/1ps
module tb_style_preprocess;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, enable=1, vs=0, de=0;
reg [47:0] rgb=0;
wire valid,sof,eol,eof; wire [31:0] rgba;
wire [9:0] ox; wire [8:0] oy;
iris_style_preprocess dut(clk,rst_n,enable,vs,de,rgb,valid,rgba,sof,eol,eof,ox,oy);
integer count=0, frames=0, expected_x, expected_y, sx,sy;
reg [31:0] expected;
function [23:0] pixel(input integer x,input integer y);
    pixel={8'(x),8'(y),8'(x+y)};
endfunction
always @(negedge clk) if (valid) begin
    expected_x=count%640; expected_y=(count/640)%480;
    sx=240+(expected_x*9)/4; sy=(expected_y*9)/4;
    expected={8'h80,8'(sx+sy)^8'h80,8'(sy)^8'h80,8'(sx)^8'h80};
    if (ox!==expected_x || oy!==expected_y || rgba!==expected ||
        sof!==(expected_x==0 && expected_y==0) || eol!==(expected_x==639) ||
        eof!==(expected_x==639 && expected_y==479))
        $fatal(1,"preprocess pixel %0d got %h (%0d,%0d) expected %h (%0d,%0d)",count,rgba,ox,oy,expected,expected_x,expected_y);
    count=count+1; if(eof) frames=frames+1;
end
task blank(input integer cycles);
    begin
        for(integer i=0;i<cycles;i=i+1) begin @(posedge clk); #1; de=0; rgb=48'hffffff_ffffff; end
    end
endtask
task frame(input integer rows);
    begin
        blank(3); @(posedge clk); #1; vs=1; blank(4);
        @(posedge clk); #1; vs=0; blank(5);
        for(integer y=0;y<rows;y=y+1) begin
            for(integer x=0;x<1920;x=x+2) begin
                @(posedge clk); #1; de=1; rgb={pixel(x,y),pixel(x+1,y)};
            end
            blank(5+(y%7));
        end
        blank(12);
    end
endtask
initial begin
    blank(5); rst_n=1;
    frame(1080); frame(1080);
    if(count!=614400 || frames!=2) $fatal(1,"wrong complete frame count %0d/%0d",count,frames);
    // A short input must never generate a complete-frame indication.
    frame(10);
    if(frames!=2) $fatal(1,"short frame published");
    enable=0; blank(3); count=0;
    frame(1080); if(count!=0) $fatal(1,"disabled tap emitted data");
    enable=1; count=0;
    // Enabling between VS events must wait for a fresh complete frame.
    for(integer k=0;k<960;k=k+1) begin @(posedge clk); #1; de=1; rgb=0; end
    blank(4); if(count!=0) $fatal(1,"mid-frame enable emitted data");
    frame(1080);
    if(count!=307200 || frames!=3) $fatal(1,"enable/frame restart failed");
    $display("PASS 640x480 RGBA hardware preprocessing: crop, all phase positions, RGB/INT8 order, markers, short frame, disable/restart");
    $finish;
end
initial begin #100000000; $fatal(1,"watchdog"); end
endmodule
