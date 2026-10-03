// Black correction, Q8 white balance, sRGB/contrast LUT, then chroma.
// Keep AE/AWB statistics upstream of this module.
module rgb_display_2px (
 input clk, rst_n, i_hs, i_vs, i_de,
 input [47:0] i_rgb,
 input [9:0] i_r_gain, i_g_gain, i_b_gain,
 input [7:0] i_black_r, i_black_g, i_black_b,
 output reg o_hs, o_vs, o_de,
 output reg [47:0] o_rgb
);
function [7:0] gain;
 input [7:0] value, black;
 input [9:0] code;
 reg [7:0] corrected;
 reg [17:0] product;
 begin
  corrected=(value>black)?value-black:8'd0;
  product=corrected*code+18'd128;
  gain=(product>18'd65407)?8'd255:product[15:8];
 end
endfunction
function [7:0] srgb;
 input [7:0] value;
 begin
  case(value)
   8'd0: srgb=8'd0;
   8'd1: srgb=8'd11;
   8'd2: srgb=8'd19;
   8'd3: srgb=8'd25;
   8'd4: srgb=8'd30;
   8'd5: srgb=8'd35;
   8'd6: srgb=8'd39;
   8'd7: srgb=8'd42;
   8'd8: srgb=8'd46;
   8'd9: srgb=8'd49;
   8'd10: srgb=8'd52;
   8'd11: srgb=8'd55;
   8'd12: srgb=8'd57;
   8'd13: srgb=8'd60;
   8'd14: srgb=8'd62;
   8'd15: srgb=8'd65;
   8'd16: srgb=8'd67;
   8'd17: srgb=8'd69;
   8'd18: srgb=8'd72;
   8'd19: srgb=8'd74;
   8'd20: srgb=8'd76;
   8'd21: srgb=8'd78;
   8'd22: srgb=8'd80;
   8'd23: srgb=8'd82;
   8'd24: srgb=8'd84;
   8'd25: srgb=8'd85;
   8'd26: srgb=8'd87;
   8'd27: srgb=8'd89;
   8'd28: srgb=8'd91;
   8'd29: srgb=8'd92;
   8'd30: srgb=8'd94;
   8'd31: srgb=8'd96;
   8'd32: srgb=8'd97;
   8'd33: srgb=8'd99;
   8'd34: srgb=8'd100;
   8'd35: srgb=8'd102;
   8'd36: srgb=8'd103;
   8'd37: srgb=8'd105;
   8'd38: srgb=8'd106;
   8'd39: srgb=8'd108;
   8'd40: srgb=8'd109;
   8'd41: srgb=8'd110;
   8'd42: srgb=8'd112;
   8'd43: srgb=8'd113;
   8'd44: srgb=8'd114;
   8'd45: srgb=8'd116;
   8'd46: srgb=8'd117;
   8'd47: srgb=8'd118;
   8'd48: srgb=8'd120;
   8'd49: srgb=8'd121;
   8'd50: srgb=8'd122;
   8'd51: srgb=8'd123;
   8'd52: srgb=8'd124;
   8'd53: srgb=8'd126;
   8'd54: srgb=8'd127;
   8'd55: srgb=8'd128;
   8'd56: srgb=8'd129;
   8'd57: srgb=8'd130;
   8'd58: srgb=8'd131;
   8'd59: srgb=8'd133;
   8'd60: srgb=8'd134;
   8'd61: srgb=8'd135;
   8'd62: srgb=8'd136;
   8'd63: srgb=8'd137;
   8'd64: srgb=8'd138;
   8'd65: srgb=8'd139;
   8'd66: srgb=8'd140;
   8'd67: srgb=8'd141;
   8'd68: srgb=8'd142;
   8'd69: srgb=8'd143;
   8'd70: srgb=8'd144;
   8'd71: srgb=8'd145;
   8'd72: srgb=8'd146;
   8'd73: srgb=8'd147;
   8'd74: srgb=8'd148;
   8'd75: srgb=8'd149;
   8'd76: srgb=8'd150;
   8'd77: srgb=8'd151;
   8'd78: srgb=8'd152;
   8'd79: srgb=8'd153;
   8'd80: srgb=8'd154;
   8'd81: srgb=8'd155;
   8'd82: srgb=8'd156;
   8'd83: srgb=8'd157;
   8'd84: srgb=8'd157;
   8'd85: srgb=8'd158;
   8'd86: srgb=8'd159;
   8'd87: srgb=8'd160;
   8'd88: srgb=8'd161;
   8'd89: srgb=8'd162;
   8'd90: srgb=8'd163;
   8'd91: srgb=8'd164;
   8'd92: srgb=8'd164;
   8'd93: srgb=8'd165;
   8'd94: srgb=8'd166;
   8'd95: srgb=8'd167;
   8'd96: srgb=8'd168;
   8'd97: srgb=8'd169;
   8'd98: srgb=8'd169;
   8'd99: srgb=8'd170;
   8'd100: srgb=8'd171;
   8'd101: srgb=8'd172;
   8'd102: srgb=8'd173;
   8'd103: srgb=8'd173;
   8'd104: srgb=8'd174;
   8'd105: srgb=8'd175;
   8'd106: srgb=8'd176;
   8'd107: srgb=8'd177;
   8'd108: srgb=8'd177;
   8'd109: srgb=8'd178;
   8'd110: srgb=8'd179;
   8'd111: srgb=8'd180;
   8'd112: srgb=8'd180;
   8'd113: srgb=8'd181;
   8'd114: srgb=8'd182;
   8'd115: srgb=8'd182;
   8'd116: srgb=8'd183;
   8'd117: srgb=8'd184;
   8'd118: srgb=8'd185;
   8'd119: srgb=8'd185;
   8'd120: srgb=8'd186;
   8'd121: srgb=8'd187;
   8'd122: srgb=8'd187;
   8'd123: srgb=8'd188;
   8'd124: srgb=8'd189;
   8'd125: srgb=8'd190;
   8'd126: srgb=8'd190;
   8'd127: srgb=8'd191;
   8'd128: srgb=8'd192;
   8'd129: srgb=8'd192;
   8'd130: srgb=8'd193;
   8'd131: srgb=8'd194;
   8'd132: srgb=8'd194;
   8'd133: srgb=8'd195;
   8'd134: srgb=8'd196;
   8'd135: srgb=8'd196;
   8'd136: srgb=8'd197;
   8'd137: srgb=8'd198;
   8'd138: srgb=8'd198;
   8'd139: srgb=8'd199;
   8'd140: srgb=8'd199;
   8'd141: srgb=8'd200;
   8'd142: srgb=8'd201;
   8'd143: srgb=8'd201;
   8'd144: srgb=8'd202;
   8'd145: srgb=8'd203;
   8'd146: srgb=8'd203;
   8'd147: srgb=8'd204;
   8'd148: srgb=8'd204;
   8'd149: srgb=8'd205;
   8'd150: srgb=8'd206;
   8'd151: srgb=8'd206;
   8'd152: srgb=8'd207;
   8'd153: srgb=8'd207;
   8'd154: srgb=8'd208;
   8'd155: srgb=8'd209;
   8'd156: srgb=8'd209;
   8'd157: srgb=8'd210;
   8'd158: srgb=8'd210;
   8'd159: srgb=8'd211;
   8'd160: srgb=8'd211;
   8'd161: srgb=8'd212;
   8'd162: srgb=8'd213;
   8'd163: srgb=8'd213;
   8'd164: srgb=8'd214;
   8'd165: srgb=8'd214;
   8'd166: srgb=8'd215;
   8'd167: srgb=8'd215;
   8'd168: srgb=8'd216;
   8'd169: srgb=8'd216;
   8'd170: srgb=8'd217;
   8'd171: srgb=8'd217;
   8'd172: srgb=8'd218;
   8'd173: srgb=8'd219;
   8'd174: srgb=8'd219;
   8'd175: srgb=8'd220;
   8'd176: srgb=8'd220;
   8'd177: srgb=8'd221;
   8'd178: srgb=8'd221;
   8'd179: srgb=8'd222;
   8'd180: srgb=8'd222;
   8'd181: srgb=8'd223;
   8'd182: srgb=8'd223;
   8'd183: srgb=8'd224;
   8'd184: srgb=8'd224;
   8'd185: srgb=8'd225;
   8'd186: srgb=8'd225;
   8'd187: srgb=8'd226;
   8'd188: srgb=8'd226;
   8'd189: srgb=8'd227;
   8'd190: srgb=8'd227;
   8'd191: srgb=8'd228;
   8'd192: srgb=8'd228;
   8'd193: srgb=8'd229;
   8'd194: srgb=8'd229;
   8'd195: srgb=8'd230;
   8'd196: srgb=8'd230;
   8'd197: srgb=8'd231;
   8'd198: srgb=8'd231;
   8'd199: srgb=8'd232;
   8'd200: srgb=8'd232;
   8'd201: srgb=8'd233;
   8'd202: srgb=8'd233;
   8'd203: srgb=8'd233;
   8'd204: srgb=8'd234;
   8'd205: srgb=8'd234;
   8'd206: srgb=8'd235;
   8'd207: srgb=8'd235;
   8'd208: srgb=8'd236;
   8'd209: srgb=8'd236;
   8'd210: srgb=8'd237;
   8'd211: srgb=8'd237;
   8'd212: srgb=8'd238;
   8'd213: srgb=8'd238;
   8'd214: srgb=8'd238;
   8'd215: srgb=8'd239;
   8'd216: srgb=8'd239;
   8'd217: srgb=8'd240;
   8'd218: srgb=8'd240;
   8'd219: srgb=8'd241;
   8'd220: srgb=8'd241;
   8'd221: srgb=8'd241;
   8'd222: srgb=8'd242;
   8'd223: srgb=8'd242;
   8'd224: srgb=8'd243;
   8'd225: srgb=8'd243;
   8'd226: srgb=8'd244;
   8'd227: srgb=8'd244;
   8'd228: srgb=8'd244;
   8'd229: srgb=8'd245;
   8'd230: srgb=8'd245;
   8'd231: srgb=8'd246;
   8'd232: srgb=8'd246;
   8'd233: srgb=8'd246;
   8'd234: srgb=8'd247;
   8'd235: srgb=8'd247;
   8'd236: srgb=8'd248;
   8'd237: srgb=8'd248;
   8'd238: srgb=8'd248;
   8'd239: srgb=8'd249;
   8'd240: srgb=8'd249;
   8'd241: srgb=8'd250;
   8'd242: srgb=8'd250;
   8'd243: srgb=8'd250;
   8'd244: srgb=8'd251;
   8'd245: srgb=8'd251;
   8'd246: srgb=8'd252;
   8'd247: srgb=8'd252;
   8'd248: srgb=8'd252;
   8'd249: srgb=8'd253;
   8'd250: srgb=8'd253;
   8'd251: srgb=8'd254;
   8'd252: srgb=8'd254;
   8'd253: srgb=8'd254;
   8'd254: srgb=8'd255;
   8'd255: srgb=8'd255;
   default: srgb=0;
  endcase
 end
endfunction
// Chroma expansion about luma: 1.25x, preserve grey and clamp both ends.
function [7:0] sat_channel;
 input [7:0] c,y;
 reg signed [11:0] expanded;
 begin
  expanded=$signed({1'b0,c})*12'sd5-$signed({1'b0,y});
  expanded=(expanded+12'sd2)>>>2;
  sat_channel=(expanded<0)?8'd0:(expanded>255)?8'd255:expanded[7:0];
 end
endfunction
function [23:0] saturation;
 input [23:0] rgb;
 reg [9:0] ysum;
 reg [7:0] y;
 begin
  ysum={2'b0,rgb[23:16]}+({2'b0,rgb[15:8]}<<1)+{2'b0,rgb[7:0]}+10'd2;
  y=ysum[9:2];
  saturation={sat_channel(rgb[23:16],y),sat_channel(rgb[15:8],y),sat_channel(rgb[7:0],y)};
 end
endfunction
reg [47:0] balanced,toned;
reg [1:0] hs_d,vs_d,de_d;
always @(posedge clk) begin
 if (!rst_n) begin
  balanced<=0;toned<=0;hs_d<=0;vs_d<=0;de_d<=0;
  o_rgb<=0;o_hs<=0;o_vs<=0;o_de<=0;
 end else begin
  balanced<={gain(i_rgb[47:40],i_black_r,i_r_gain),gain(i_rgb[39:32],i_black_g,i_g_gain),gain(i_rgb[31:24],i_black_b,i_b_gain),
             gain(i_rgb[23:16],i_black_r,i_r_gain),gain(i_rgb[15:8],i_black_g,i_g_gain),gain(i_rgb[7:0],i_black_b,i_b_gain)};
  hs_d<={hs_d[0],i_hs};vs_d<={vs_d[0],i_vs};de_d<={de_d[0],i_de};
  toned<={srgb(balanced[47:40]),srgb(balanced[39:32]),srgb(balanced[31:24]),
          srgb(balanced[23:16]),srgb(balanced[15:8]),srgb(balanced[7:0])};
  o_rgb<={saturation(toned[47:24]),saturation(toned[23:0])};
  o_hs<=hs_d[1];o_vs<=vs_d[1];o_de<=de_d[1];
 end
end
endmodule
