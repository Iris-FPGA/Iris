// One-shot neutral-pixel white balance, Q8 gains (256 = unity).
// Scene/exposure changes cannot pump locked colour gains.
// Serial restoring division avoids a wide combinational divider.
module awb_ctrl #(
    parameter SETTLE_FRAMES=8, MIN_WB_PIXELS=4096
)(
    input clk,rst_n,i_upd,i_calibrate,i_black_calibrate,
    input [11:0] i_exposure,
    input [31:0] i_sum_r,i_sum_g,i_sum_b,
    input [31:0] i_wb_r,i_wb_g,i_wb_b,
    input [23:0] i_wb_pixels,i_pixels,
    output reg [9:0] o_r_gain,o_g_gain,o_b_gain,
    output reg [7:0] o_black_r,o_black_g,o_black_b,
    output wire o_locked
);
localparam IDLE=0,WAIT_STATS=1,DIVIDE=2,COMMIT=3;
reg [1:0] state;
reg black_mode;
reg [7:0] settled;
reg [11:0] exposure_seen;
reg [5:0] bits_left;
reg [39:0] num_r,num_g,num_b,q_r,q_g,q_b;
reg [32:0] rem_r,rem_g,rem_b;
reg [31:0] den_r,den_g,den_b;
wire [32:0] trial_r={rem_r[31:0],num_r[39]};
wire [32:0] trial_g={rem_g[31:0],num_g[39]};
wire [32:0] trial_b={rem_b[31:0],num_b[39]};
wire take_r=trial_r>={1'b0,den_r};
wire take_g=trial_g>={1'b0,den_g};
wire take_b=trial_b>={1'b0,den_b};
assign o_locked=(state==IDLE);
function [9:0] clamp_gain;
 input [39:0] q;
 begin clamp_gain=(q<128)?10'd128:(q>768)?10'd768:q[9:0];end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=WAIT_STATS;black_mode<=0;settled<=0;exposure_seen<=0;bits_left<=0;
  num_r<=0;num_g<=0;num_b<=0;q_r<=0;q_g<=0;q_b<=0;
  rem_r<=0;rem_g<=0;rem_b<=0;den_r<=1;den_g<=1;den_b<=1;
  o_r_gain<=256;o_g_gain<=256;o_b_gain<=256;
  o_black_r<=0;o_black_g<=0;o_black_b<=0;
 end else if(i_calibrate || i_black_calibrate)begin
  state<=WAIT_STATS;black_mode<=i_black_calibrate;settled<=0;
 end else if(i_upd && state!=IDLE && i_exposure!=exposure_seen)begin
  exposure_seen<=i_exposure;settled<=0;state<=WAIT_STATS;
 end else case(state)
  WAIT_STATS:if(i_upd)begin
   if(settled<SETTLE_FRAMES)settled<=settled+1'b1;
   else if((black_mode && i_pixels!=0) ||
           (!black_mode && i_wb_pixels>=MIN_WB_PIXELS && i_wb_r!=0 && i_wb_g!=0 && i_wb_b!=0))begin
    state<=DIVIDE;bits_left<=40;q_r<=0;q_g<=0;q_b<=0;rem_r<=0;rem_g<=0;rem_b<=0;
    if(black_mode)begin
     den_r<={8'b0,i_pixels};den_g<={8'b0,i_pixels};den_b<={8'b0,i_pixels};
     num_r<={8'b0,i_sum_r}+{17'b0,i_pixels[23:1]};
     num_g<={8'b0,i_sum_g}+{17'b0,i_pixels[23:1]};
     num_b<={8'b0,i_sum_b}+{17'b0,i_pixels[23:1]};
    end else begin
     den_r<=i_wb_r;den_g<=i_wb_g;den_b<=i_wb_b;
     num_r<={i_wb_g,8'b0}+{9'b0,i_wb_r[31:1]};
     num_g<={i_wb_g,8'b0}+{9'b0,i_wb_g[31:1]};
     num_b<={i_wb_g,8'b0}+{9'b0,i_wb_b[31:1]};
    end
   end
  end
  DIVIDE:begin
   num_r<=num_r<<1;num_g<=num_g<<1;num_b<=num_b<<1;
   rem_r<=take_r?trial_r-{1'b0,den_r}:trial_r;
   rem_g<=take_g?trial_g-{1'b0,den_g}:trial_g;
   rem_b<=take_b?trial_b-{1'b0,den_b}:trial_b;
   q_r<={q_r[38:0],take_r};q_g<={q_g[38:0],take_g};q_b<={q_b[38:0],take_b};
   bits_left<=bits_left-1'b1;
   if(bits_left==1)state<=COMMIT;
  end
  COMMIT:if(i_upd)begin
   // Apply only at frame boundary, never during active image pixels.
   if(black_mode)begin
    // Reject a bright frame: black calibration requires a covered lens.
    if(q_r<=64 && q_g<=64 && q_b<=64)begin
     o_black_r<=q_r[7:0];o_black_g<=q_g[7:0];o_black_b<=q_b[7:0];
    end
    black_mode<=0;settled<=0;state<=WAIT_STATS;
   end else begin
    o_r_gain<=clamp_gain(q_r);o_g_gain<=256;o_b_gain<=clamp_gain(q_b);state<=IDLE;
   end
  end
  default:;
 endcase
end
endmodule
