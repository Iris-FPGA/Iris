// HDMI420 video + AVI v3 (VIC95, BT.709 limited range), one packet/frame.
// Protocol references: Intel HDMI FPGA IP User Guide sections 5.2/5.3,
// HDMI data-island BCH/TERC4 definitions. No audio or FRL is required.
// Input/output use the existing 10-bit half-rate LVDS serializer.
module hdmi_420_tx(input clk,rst_n,i_hs,i_vs,i_de,
 input [23:0] i_channels,input [11:0] i_x,i_y,
 output [9:0] ch0,ch1,ch2);
localparam [31:0] HEADER=32'h150d0382;
localparam [63:0] SUB0=64'h3600005f00a86007,SUB1=64'h0000000000000000,SUB2=64'h0000000000000000,SUB3=64'h0000000000000000;
wire island_pre=i_y==0&&i_x>=64&&i_x<72;
wire island_guard=i_y==0&&((i_x>=72&&i_x<74)||(i_x>=106&&i_x<108));
wire island=i_y==0&&i_x>=74&&i_x<106;
wire active_line=i_y>=82&&i_y<2242;
wire video_pre=active_line&&i_x>=182&&i_x<190;
wire video_guard=active_line&&i_x>=190&&i_x<192;
wire [4:0] pi=i_x-74;
wire [5:0] bit0={pi,1'b0},bit1={pi,1'b1};
wire [3:0] nib0={1'b1,HEADER[pi],i_vs,i_hs};
wire [3:0] nib1={SUB3[bit0],SUB2[bit0],SUB1[bit0],SUB0[bit0]};
wire [3:0] nib2={SUB3[bit1],SUB2[bit1],SUB1[bit1],SUB0[bit1]};
function [9:0] terc4;
 input [3:0] n;
 begin case(n)
 0:terc4=10'b1010011100;1:terc4=10'b1001100011;
 2:terc4=10'b1011100100;3:terc4=10'b1011100010;
 4:terc4=10'b0101110001;5:terc4=10'b0100011110;
 6:terc4=10'b0110001110;7:terc4=10'b0100111100;
 8:terc4=10'b1011001100;9:terc4=10'b0100111001;
 10:terc4=10'b0110011100;11:terc4=10'b1011000110;
 12:terc4=10'b1010001110;13:terc4=10'b1001110001;
 14:terc4=10'b0101100011;15:terc4=10'b1011000011;
 endcase end
endfunction
wire special=island_guard||island||video_guard;
wire [29:0] token=island_guard ? {10'b0100110011,10'b0100110011,terc4({2'b11,i_vs,i_hs})} :
 island ? {terc4(nib2),terc4(nib1),terc4(nib0)} :
 {10'b1011001100,10'b0100110011,10'b1011001100};
wire [9:0] e0,e1,e2;
// i_channels = {Yodd, Yeven, Cb/Cr}; each Y is a duplicated source pixel.
encode b(.clkin(clk),.rstin(!rst_n),.din(i_channels[7:0]),.c0(i_hs),.c1(i_vs),.de(i_de),.dout(e0));
encode g(.clkin(clk),.rstin(!rst_n),.din(i_channels[15:8]),.c0(video_pre||island_pre),.c1(1'b0),.de(i_de),.dout(e1));
encode r(.clkin(clk),.rstin(!rst_n),.din(i_channels[23:16]),.c0(island_pre),.c1(1'b0),.de(i_de),.dout(e2));
// encode.v has three edge stages; special symbols must have exactly that latency.
reg [2:0] special_d;
reg [29:0] token1,token2,token3;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin special_d<=0;token1<=0;token2<=0;token3<=0;end
 else begin special_d<={special_d[1:0],special};token1<=token;token2<=token1;token3<=token2;end
end
assign {ch2,ch1,ch0}=special_d[2]?token3:{e2,e1,e0};
endmodule
