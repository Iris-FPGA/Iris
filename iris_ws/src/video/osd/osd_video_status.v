// Camera and HDMI resolution/FPS. 5x7 font enlarged 2x, white on black.
// Source buses are captured after their update toggles cross the domains.
// Binary-to-decimal conversion runs serially in vertical blanking.
module osd_video_status (
 input clk, rst_n, i_hs, i_vs, i_de,
 input [23:0] i_rgb,
 input [11:0] i_cam_width, i_cam_height,
 input i_cam_toggle,
 input [11:0] i_hdmi_width, i_hdmi_height,
 input [7:0] i_cam_fps, i_wr_fps, i_hdmi_fps,
 input i_cam_fps_upd, i_wr_fps_upd, i_hdmi_fps_upd,
 output wire [23:0] o_rgb
);
reg [2:0] cam_sync, cf_sync, wf_sync, hf_sync;
reg [11:0] cam_w, cam_h;
reg [7:0] cam_f, wr_f, hdmi_f;
reg [11:0] x,y;
reg de_d,vs_d;
wire vs_rise=i_vs && !vs_d;
always @(posedge clk or negedge rst_n) begin
 if (!rst_n) begin
  cam_sync<=0; cf_sync<=0; wf_sync<=0; hf_sync<=0;
  cam_w<=0;cam_h<=0;cam_f<=0;wr_f<=0;hdmi_f<=0;
  x<=0;y<=0;de_d<=0;vs_d<=0;
 end else begin
  cam_sync<={cam_sync[1:0],i_cam_toggle};
  cf_sync<={cf_sync[1:0],i_cam_fps_upd};
  wf_sync<={wf_sync[1:0],i_wr_fps_upd};
  hf_sync<={hf_sync[1:0],i_hdmi_fps_upd};
  if (cam_sync[2]^cam_sync[1]) begin cam_w<=i_cam_width;cam_h<=i_cam_height;end
  if (cf_sync[2]^cf_sync[1]) cam_f<=i_cam_fps;
  if (wf_sync[2]^wf_sync[1]) wr_f<=i_wr_fps;
  if (hf_sync[2]^hf_sync[1]) hdmi_f<=i_hdmi_fps;
  vs_d<=i_vs;de_d<=i_de;
  if (vs_rise) y<=0; else if (de_d && !i_de) y<=y+1'b1;
  if (vs_rise || !i_de) x<=0; else x<=x+1'b1;
 end
end
reg [11:0] values [0:6];
reg [15:0] digits [0:6];
reg [15:0] bcd,adjusted;
reg [11:0] binary;
reg [3:0] bits_left;
reg [2:0] field;
reg busy;
integer n,j;
always @(*) begin
 adjusted=bcd;
 for (j=0;j<4;j=j+1)
  if (bcd[j*4+:4]>=5) adjusted[j*4+:4]=bcd[j*4+:4]+4'd3;
end
always @(posedge clk or negedge rst_n) begin
 if (!rst_n) begin
  busy<=0;field<=0;bits_left<=0;bcd<=0;binary<=0;
  for (n=0;n<7;n=n+1) begin values[n]<=0;digits[n]<=0;end
 end else if (vs_rise && !busy) begin
  values[0]<=cam_w;values[1]<=cam_h;values[2]<={4'b0,cam_f};
  values[3]<={4'b0,wr_f};values[4]<=i_hdmi_width;values[5]<=i_hdmi_height;
  values[6]<={4'b0,hdmi_f};
  binary<=cam_w;bcd<=0;bits_left<=12;field<=0;busy<=1;
 end else if (busy) begin
  if (bits_left!=0) begin
   bcd<={adjusted[14:0],binary[11]};binary<={binary[10:0],1'b0};
   bits_left<=bits_left-1'b1;
  end else begin
   digits[field]<=bcd;
   if (field==6) busy<=0;
   else begin field<=field+1'b1;binary<=values[field+1'b1];bcd<=0;bits_left<=12;end
  end
 end
end
function [7:0] decchar;
 input [15:0] d;
 input [1:0] pos;
 begin decchar=8'd48+((d >> ((3-pos)*4)) & 4'hf); end
endfunction
wire camera_row=(y>=16 && y<32);
wire hdmi_row=(y>=80 && y<96);
wire text_area=(camera_row || hdmi_row) && x>=16 && x<352;
wire [11:0] dx=x-12'd16;
wire [4:0] slot=dx/12;
wire [3:0] col=(dx%12)>>1;
wire [3:0] row=(camera_row ? (y-12'd16) : (y-12'd80))>>1;
reg [7:0] ch;
always @(*) begin
 ch=8'd32;
 if (camera_row) begin
  case(slot)
   0:ch="C";1:ch="A";2:ch="M";
   4,5,6,7:ch=decchar(digits[0],slot-4);
   8:ch="x";
   9,10,11,12:ch=decchar(digits[1],slot-9);
   14,15:ch=decchar(digits[2],slot-12);
   17:ch="F";18:ch="P";19:ch="S";
   21:ch="W";22:ch="R";
   24,25:ch=decchar(digits[3],slot-22);
   default:ch=8'd32;
  endcase
 end else begin
  case(slot)
   0:ch="H";1:ch="D";2:ch="M";3:ch="I";
   5,6,7,8:ch=decchar(digits[4],slot-5);
   9:ch="x";
   10,11,12,13:ch=decchar(digits[5],slot-10);
   15,16:ch=decchar(digits[6],slot-13);
   18:ch="F";19:ch="P";20:ch="S";
   default:ch=8'd32;
  endcase
 end
end
function [34:0] font;
 input [7:0] ch;
 begin
  case(ch)
   8'd48:font=35'b01110100011001110101110011000101110;
   8'd49:font=35'b00100011000010000100001000010001110;
   8'd50:font=35'b01110100010000100010001000100011111;
   8'd51:font=35'b11110000010000101110000010000111110;
   8'd52:font=35'b00010001100101010010111110001000010;
   8'd53:font=35'b11111100001000011110000010000111110;
   8'd54:font=35'b01110100001000011110100011000101110;
   8'd55:font=35'b11111000010001000100010000100001000;
   8'd56:font=35'b01110100011000101110100011000101110;
   8'd57:font=35'b01110100011000101111000010000101110;
   8'd67:font=35'b01111100001000010000100001000001111;
   8'd65:font=35'b01110100011000111111100011000110001;
   8'd77:font=35'b10001110111010110101100011000110001;
   8'd72:font=35'b10001100011000111111100011000110001;
   8'd68:font=35'b11110100011000110001100011000111110;
   8'd73:font=35'b01110001000010000100001000010001110;
   8'd70:font=35'b11111100001000011110100001000010000;
   8'd80:font=35'b11110100011000111110100001000010000;
   8'd83:font=35'b01111100001000001110000010000111110;
   8'd87:font=35'b10001100011000110101101011101110001;
   8'd82:font=35'b11110100011000111110101001001010001;
   8'd120:font=35'b00000000001000101010001000101010001;
   default:font=0;
  endcase
 end
endfunction
wire [34:0] glyph=font(ch);
wire white=(col<5 && row<7) ? glyph[34-row*5-col] : 1'b0;
assign o_rgb=(i_de && text_area)?(white?24'hffffff:24'h000000):i_rgb;
endmodule
