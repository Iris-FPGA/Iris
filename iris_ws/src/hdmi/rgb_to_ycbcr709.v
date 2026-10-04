// Full-range RGB -> limited-range BT.709, three registered stages.
// Coefficients sum to 220 for Y and zero for chroma. 16..235 / 16..240.
module rgb_to_ycbcr709(input clk,rst_n,i_de,input [23:0] i_rgb,
 output reg o_de,output reg [23:0] o_ycc);
wire [7:0] r=i_rgb[23:16],g=i_rgb[15:8],b=i_rgb[7:0];
reg [15:0] yr,yg,yb,ur,ug,ub,vr,vg,vb;
reg signed [17:0] ys,us,vs;
reg de1,de2;
always @(posedge clk)begin
 yr<=r*16'd47;yg<=g*16'd157;yb<=b*16'd16;
 ur<=r*16'd26;ug<=g*16'd87;ub<=b*16'd113;
 vr<=r*16'd112;vg<=g*16'd102;vb<=b*16'd10;
 ys<=18'sd4224+$signed({2'b0,yr})+$signed({2'b0,yg})+$signed({2'b0,yb});
 us<=18'sd32896-$signed({2'b0,ur})-$signed({2'b0,ug})+$signed({2'b0,ub});
 vs<=18'sd32896+$signed({2'b0,vr})-$signed({2'b0,vg})-$signed({2'b0,vb});
 o_ycc<={ys[15:8],(us[15:8]>240?8'd240:us[15:8]<16?8'd16:us[15:8]),vs[15:8]};
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin de1<=0;de2<=0;o_de<=0;end
 else begin de1<=i_de;de2<=de1;o_de<=de2;end
end
endmodule
