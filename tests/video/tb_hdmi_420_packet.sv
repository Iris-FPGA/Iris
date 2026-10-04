`timescale 1ns/1ps
module tb_hdmi_420_packet;
reg clk=0;always #5 clk=~clk;
reg rst=0;reg [11:0] x=0,y=0;reg hs=0,vs=0,de=0;reg [23:0] channels=24'hebeb80;
wire [9:0] c0,c1,c2;
hdmi_420_tx dut(.clk(clk),.rst_n(rst),.i_hs(hs),.i_vs(vs),.i_de(de),
 .i_channels(channels),.i_x(x),.i_y(y),.ch0(c0),.ch1(c1),.ch2(c2));
reg [11:0] xd[0:2],yd[0:2];
integer trace,xx,yy,k,n=0;reg [1023:0] path;
always @(posedge clk)begin
 xd[0]<=x;yd[0]<=y;for(k=1;k<3;k=k+1)begin xd[k]<=xd[k-1];yd[k]<=yd[k-1];end
 #0.01;
 if(rst)begin n=n+1;if(n>4)$fwrite(trace,"%0d %0d %03h %03h %03h\n",xd[2],yd[2],c0,c1,c2);end
end
initial begin
 if(!$value$plusargs("TRACE=%s",path))$fatal(1,"TRACE required");trace=$fopen(path,"w");
 repeat(5)@(negedge clk);rst=1;
 for(yy=0;yy<3;yy=yy+1)begin
  y=(yy==2)?82:yy;
  for(xx=0;xx<2200;xx=xx+1)begin
   x=xx;hs=xx<44;vs=y<10;de=y==82&&xx>=192&&xx<2112;
   // White: both Y samples=235, neutral chroma=128.
   channels=24'hebeb80;@(negedge clk);
  end
 end
 de=0;repeat(5)@(negedge clk);$fclose(trace);$finish;
end
endmodule
