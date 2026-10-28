`timescale 1ns/1ps
module tb_style_preprocess #(parameter GAUSSIAN=1,parameter MEDIAN=0,parameter SMOOTH=0);
reg clk=0; always #5 clk=~clk;
reg rst_n=0, enable=1, vs=0, de=0;
reg [47:0] rgb=0;
wire valid,dual,sof,eol,eof; wire [31:0] rgba,rgba_b;
wire [9:0] ox; wire [8:0] oy;
iris_style_preprocess #(.ENABLE_GAUSSIAN(GAUSSIAN),.ENABLE_MEDIAN(MEDIAN),.ENABLE_SMOOTH(SMOOTH),.HEIGHT(480)) dut(clk,rst_n,enable,vs,de,rgb,valid,rgba,dual,rgba_b,sof,eol,eof,ox,oy);
integer count=0, frames=0, expected_x, expected_y, sx,sy;
integer pattern=0;
reg [23:0] median_reference[0:2457599];
reg [2047:0] median_path;
initial if(MEDIAN)begin
 if(!$value$plusargs("MEDIAN_REF=%s",median_path))$fatal(1,"median reference missing");
 $readmemh(median_path,median_reference);
end
reg [31:0] expected;
function [23:0] pixel(input integer x,input integer y);
    case(pattern)
        0:pixel={8'(x),8'(y),8'(x+y)};
        1:pixel={8'((x*73+y*151)^(x*y*17)),8'((x*191+y*13)^(x*y*31)),8'((x*43+y*97)^(x*y*7))};
        2:pixel=24'hffffff;
        3:pixel=0;
        4:pixel=(x==960 && y==540) ? 24'hffffff : 0;
        6:pixel=((x*73+y*151)^(x*y*17))%13==0 ? (((x+y)%2) ? 24'hffffff : 0) : 24'h808080;
        7:pixel={8'(112+(((x*73+y*151)^(x*y*17))%33)),8'(112+(((x*191+y*13)^(x*y*31))%33)),8'(112+(((x*43+y*97)^(x*y*7))%33))};
        default:pixel={8'(x<960 ? 0 : 255),8'(y<540 ? 0 : 255),8'((x+y)%2 ? 0 : 255)};
    endcase
endfunction
// Independent 2D convolution at the original-resolution sampling centres.
// This deliberately does not reproduce the separable, row-bank RTL.
function [23:0] reference_pixel(input integer x,input integer y);
    integer r,g,b,weight,yy;
    reg [23:0] p;
    begin
        r=0;g=0;b=0;
        if(!GAUSSIAN)reference_pixel=pixel(x,y);
        else begin
            for(integer dy=-1;dy<=1;dy=dy+1)begin
                yy=y+dy;if(yy<0)yy=0;
                for(integer dx=-1;dx<=1;dx=dx+1)begin
                    weight=(dx==0 ? 2 : 1)*(dy==0 ? 2 : 1);
                    p=pixel(x+dx,yy);
                    r=r+weight*p[23:16];g=g+weight*p[15:8];b=b+weight*p[7:0];
                end
            end
            reference_pixel={8'((r+8)/16),8'((g+8)/16),8'((b+8)/16)};
        end
    end
endfunction
reg [23:0] reference_rgb;
always @(negedge clk) if (valid) begin
    expected_x=count%640; expected_y=(count/640)%480;
    sx=(!GAUSSIAN && !MEDIAN) ? expected_x*3 : 240+(expected_x*9)/4; sy=(expected_y*9)/4;
    reference_rgb=MEDIAN ? median_reference[pattern*307200+expected_y*640+expected_x] : reference_pixel(sx,sy);
    expected={8'h80,reference_rgb[7:0]^8'h80,reference_rgb[15:8]^8'h80,reference_rgb[23:16]^8'h80};
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
        if(MEDIAN)$display("median frame rows=%0d pattern=%0d checked=%0d complete=%0d",rows,pattern,count,frames);
    end
endtask
initial begin
    blank(5); rst_n=1;
    frame(1080); pattern=1;frame(1080);
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
    for(integer p=2;p<(MEDIAN ? 8 : 6);p=p+1)begin
        count=0;pattern=p;frame(1080);
        if(count!=307200 || frames!=p+2) $fatal(1,"pattern %0d incomplete",p);
    end
    $display("PASS 640x480 RGBA preprocessing Gaussian=%0d Median=%0d Smooth=%0d: 2D oracle, noise/impulse/edges/black/white, crop phases, INT8 order, markers, short frame, disable/restart",GAUSSIAN,MEDIAN,SMOOTH);
    $finish;
end
initial begin #130000000; $fatal(1,"watchdog"); end
endmodule
