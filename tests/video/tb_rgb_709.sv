`timescale 1ns/1ps
module tb_rgb_709;
reg clk=0;always #5 clk=~clk;
reg rst=0,de=0;reg [23:0] rgb=0;
wire valid;wire [23:0] ycc;
rgb_to_ycbcr709 dut(.clk(clk),.rst_n(rst),.i_de(de),.i_rgb(rgb),.o_de(valid),.o_ycc(ycc));
reg [23:0] old_rgb[0:2];reg [2:0] old_de=0;
integer f,i,kind;reg [1023:0] path;
always @(posedge clk)begin
 old_de<={old_de[1:0],de};old_rgb[0]<=rgb;old_rgb[1]<=old_rgb[0];old_rgb[2]<=old_rgb[1];
 #0.01;
 if(rst)begin
  if(valid!==old_de[2])$fatal(1,"709 valid latency");
  if(valid)$fwrite(f,"%06h %06h\n",old_rgb[2],ycc);
 end
end
initial begin
 if(!$value$plusargs("TRACE=%s",path))$fatal(1,"TRACE required");f=$fopen(path,"w");
 repeat(5)@(negedge clk);rst=1;
 for(kind=0;kind<6;kind=kind+1)for(i=0;i<256;i=i+1)begin
  case(kind)
   0:rgb={8'(i),8'(i),8'(i)};
   1:rgb={8'(i),8'd0,8'd0};2:rgb={8'd0,8'(i),8'd0};3:rgb={8'd0,8'd0,8'(i)};
   4:rgb={8'(i),8'(i),8'd0};5:rgb={8'(i*17),8'(i*43),8'(i*127)};
  endcase
  de=1;@(negedge clk);de=0;@(negedge clk);
 end
 repeat(5)@(negedge clk);$fclose(f);$finish;
end
endmodule
