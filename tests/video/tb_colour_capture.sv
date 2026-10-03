`timescale 1ns/1ps
module tb_colour_capture;
reg vc=0,uc=0,rst=0,vs=0,de=0,rx=0,key=0;
always #7 vc=~vc;
always #5 uc=~uc;
reg [47:0] rgb=0;
reg [7:0] rxdata=0;
wire valid,gate,ready,txd,busy,over,snapshot_ready;
wire [7:0] data;
colour_capture #(.WIDTH(80),.HEIGHT(60),.STEP(20)) dut(
 .video_clk(vc),.uart_clk(uc),.rst_n(rst),.i_vs(vs),.i_de(de),.i_rgb(rgb),
 .i_capture(key),.rx_valid(rx),.rx_data(rxdata),.log_active(1'b0),.tx_req(ready),
 .tx_valid(valid),.tx_data(data),.tx_gate(gate),.o_ready(snapshot_ready));
uart_tx #(.BPS_CNT(8)) tx(.clk(uc),.tx_data(data),.tx_valid(valid),.tx_req(ready),.txd(txd),.tx_busy(busy),.tx_over(over));
integer x,y,packet=0,seen=0,tint=0;
task tick;begin @(negedge vc);end endtask
task frame;begin
 vs=1;repeat(4)tick();vs=0;repeat(4)tick();
 for(y=0;y<60;y=y+1)begin
  de=1;
  for(x=0;x<40;x=x+1)begin rgb={8'hff,8'hff,8'hff,8'(x*2+tint),8'(y+tint),8'(x+y+tint)};tick();end
  de=0;repeat(5)tick();
 end
 repeat(4)tick();
end endtask
function [15:0] crc_byte;input[15:0]old;input[7:0]b;reg[15:0]c;integer k;
 begin c=old^{b,8'b0};for(k=0;k<8;k=k+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
endfunction
reg [7:0] bytes[0:49],ch;
reg [15:0] crc;
integer i,k,p,j;
task read_command;begin @(negedge uc);rx=1;rxdata="C";@(negedge uc);rx=0;end endtask
task key_press;begin @(negedge uc);key=1;@(negedge uc);key=0;end endtask
initial begin wait(rst);forever frame();end
initial begin
 repeat(5)@(negedge uc);rst=1;
 read_command();wait(seen==1); // Empty read must never auto-capture.
 key_press();wait(snapshot_ready);tint=80;
 read_command();wait(seen==2);
 read_command();wait(seen==3); // Read again after the live scene changed.
 key_press();wait(!snapshot_ready);wait(snapshot_ready);
 read_command();wait(seen==4);
 $display("PASS colour capture: empty read, KEY2 snapshots, repeated frozen reads after scene changes, RGB/CRC, explicit replacement");$finish;
end
initial begin
 for(j=0;j<4;j=j+1)begin
  crc=16'hffff;
  for(i=0;i<((j==0)?14:50);i=i+1)begin
   @(negedge txd);repeat(4)@(posedge uc);#1;
   for(k=0;k<8;k=k+1)begin repeat(8)@(posedge uc);#1;ch[k]=txd;end
   repeat(8)@(posedge uc);#1;if(txd!==1)$fatal(1,"UART stop");
   bytes[i]=ch;if(i<((j==0)?12:48))crc=crc_byte(crc,ch);
  end
  if({bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7]}!==64'h4952495343414c31)$fatal(1,"Capture header");
  if(j==0)begin
   if({bytes[9],bytes[8],bytes[11],bytes[10]}!==0 || {bytes[13],bytes[12]}!==crc)$fatal(1,"Empty frame response");
  end else begin
  if({bytes[9],bytes[8]}!==16'd4 || {bytes[11],bytes[10]}!==16'd3)$fatal(1,"Capture dimensions");
  for(p=0;p<12;p=p+1)begin
   if(bytes[12+3*p]!==8'(10+(p%4)*20+((j==3)?80:0)) || bytes[13+3*p]!==8'(10+(p/4)*20+((j==3)?80:0)) || bytes[14+3*p]!==8'(5+(p%4)*10+10+(p/4)*20+((j==3)?80:0)))
    $fatal(1,"Sample order/value %0d %0d/%0d/%0d",p,bytes[12+3*p],bytes[13+3*p],bytes[14+3*p]);
  end
  if({bytes[49],bytes[48]}!==crc)$fatal(1,"CRC mismatch");end seen=seen+1;
 end
end
initial begin #2000000;$fatal(1,"Capture timeout %0d",seen);end
endmodule
