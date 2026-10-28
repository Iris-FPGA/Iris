`timescale 1ns/1ps
module tb_tinyml_capture #(parameter STAGING_STYLE="hybrid");
reg clk=0,video_clk=0,rst_n=0;
always #5 clk=~clk;always #7 video_clk=~video_clk;
reg request=0,vs=0,de=0;reg [47:0] rgb=0;
wire valid,sof,eof,enable,busy,done,error;
wire [31:0] word,awaddr,audit;wire [7:0] awlen;
wire awvalid,wvalid,wlast,bready;wire [127:0] wdata;
reg awready=0,wready=0,bvalid=0;
reg [31:0] cycle=0;integer writes=0,bursts=0,delay_b=0,beat=0;
reg transaction=0;reg [31:0] address;
iris_tinyml_preprocess sample(.clk(video_clk),.rst_n(rst_n),.enable(enable),
 .i_vs(vs),.i_de(de),.i_rgb(rgb),.o_valid(valid),.o_word(word),.o_sof(sof),.o_eof(eof));
iris_style_capture #(.FRAME_WORDS(3072),.FIFO_AW(5),.BURST_BITS(2),.AUDIT_DUMMY(0),.STAGING_STYLE(STAGING_STYLE)) capture(
 .clk(clk),.video_clk(video_clk),.rst_n(rst_n),.request(request),.pair(2'd2),
 .busy(busy),.done(done),.error(error),.write_dummy_bad(audit),.capture_enable(enable),
 .i_vs(vs),.i_valid(valid),.i_sof(sof),.i_eof(eof),.i_rgba(word),.i_dual(1'b0),.i_rgba_b(32'd0),
 .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
 .wdata(wdata),.wvalid(wvalid),.wlast(wlast),.wready(wready),
 .bresp(2'd0),.bvalid(bvalid),.bready(bready));
function [23:0] sensor;
 input integer x,y;
 begin sensor={8'((x+y)%256),8'((3*x+7*y)%256),8'((x^y)%256)};end
endfunction
function [7:0] reference_byte;
 input integer offset;
 integer x,y,c;reg [23:0] p;
 begin x=(offset/3)%128;y=(offset/3)/128;c=offset%3;p=sensor(15*x,(135*y)/16);
 reference_byte=(c==0 ? p[23:16] : c==1 ? p[15:8] : p[7:0])^8'h80;end
endfunction
integer lane;
always @(posedge clk)if(rst_n)begin
 cycle<=cycle+1;awready<=cycle%5!=0;wready<=cycle%7!=0;
 if(awvalid && awready)begin
  if(transaction || awaddr!==32'h03800000+bursts*64 || awlen!=3)$fatal(1,"capture AW order/address");
  transaction<=1;address<=awaddr;beat<=0;bursts<=bursts+1;
 end
 if(wvalid && wready)begin
  if(!transaction || wlast!=(beat==3))$fatal(1,"capture W protocol");
  for(lane=0;lane<16;lane=lane+1)
   if(wdata[lane*8+:8]!==reference_byte(writes*16+lane))
    $fatal(1,"C3 capture byte=%0d got=%h exp=%h",writes*16+lane,wdata[lane*8+:8],reference_byte(writes*16+lane));
  writes<=writes+1;beat<=beat+1;
  if(wlast)delay_b<=11;
 end
 if(delay_b!=0)begin delay_b<=delay_b-1;if(delay_b==1)bvalid<=1;end
 if(bvalid && bready)begin bvalid<=0;transaction<=0;end
 if(done && (transaction || writes!=3072 || error || audit))$fatal(1,"capture premature/failed completion");
end
integer x,y;
initial begin
 #100;rst_n=1;repeat(10)@(negedge clk);request=1;@(negedge clk);request=0;
 repeat(20)@(negedge video_clk);vs=1;repeat(8)@(negedge video_clk);vs=0;
 for(y=0;y<1080;y=y+1)begin
  for(x=0;x<1920;x=x+2)begin
   @(negedge video_clk);de=1;rgb={sensor(x,y),sensor(x+1,y)};
  end
  @(negedge video_clk);de=0;repeat(12)@(negedge video_clk);
 end
 repeat(1000)@(negedge clk);
 if(!done || error || writes!=3072 || bursts!=768)$fatal(1,"missing packed frame");
 $display("PASS TinyML capture: all 49152 C3 bytes, full 1920x1080 raster, RGB order, stalls, final B, 768 bursts");$finish;
end
initial begin #30000000;$fatal(1,"timeout");end
endmodule
