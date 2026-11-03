// Full 1920x1080 RGB -> model-native 128x128 INT8 NHWC, tightly packed C3.
// In mode 2 (full style), sample 720p (1280x720) down to 128x128 (step_x=10, step_y=5.625).
// In mode 0 (split screen), sample 720p-half (640x720) down to 128x128 (step_x=5, step_y=5.625).
module iris_tinyml_preprocess(
 input wire clk,rst_n,enable,i_vs,i_de,input wire [47:0] i_rgb,
 input wire [1:0] mode,
 output reg o_valid,o_sof,o_eof,output reg [31:0] o_word
);
reg vs_d,de_d,active,line_done;
reg [10:0] x,y,next_x,next_y;
reg [6:0] sx,sy;
reg [3:0] phase_y;
reg [1:0] bytes_held;
reg [23:0] held;
reg first_word;
wire frame_start=i_vs && !vs_d;
wire selected=active && enable && i_de && y==next_y &&
              x<=next_x && x+11'd1>=next_x && !line_done;
wire [23:0] rgb=next_x[0] ? i_rgb[23:0] : i_rgb[47:24];
wire [23:0] rgb_bytes={rgb[7:0]^8'h80,rgb[15:8]^8'h80,rgb[23:16]^8'h80};
wire [55:0] joined={32'd0,held} | ({32'd0,rgb_bytes} << (bytes_held*8));

wire [10:0] init_next_x = (mode == 2'd2) ? 11'd320 : 11'd960;
wire [10:0] step_x      = (mode == 2'd2) ? 11'd10  : 11'd5;

always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  vs_d<=0;de_d<=0;active<=0;line_done<=0;x<=0;y<=0;next_x<=0;next_y<=0;sx<=0;sy<=0;phase_y<=0;
  bytes_held<=0;held<=0;first_word<=1;o_valid<=0;o_sof<=0;o_eof<=0;o_word<=0;
 end else begin
  vs_d<=i_vs;de_d<=i_de;o_valid<=0;o_sof<=0;o_eof<=0;
  if(frame_start || !enable)begin
   active<=frame_start && enable;line_done<=0;x<=0;y<=0;
   next_x<=init_next_x;next_y<=11'd180;
   sx<=0;sy<=0;phase_y<=0;
   bytes_held<=0;held<=0;first_word<=1;
  end else begin
   if(i_de)x<=x+2'd2;
   else if(de_d)begin
    x<=0;y<=y+1'b1;next_x<=init_next_x;sx<=0;line_done<=0;
    if(y==next_y)begin
     next_y<=next_y+(phase_y>=6 ? 11'd6 : 11'd5);
     phase_y<=phase_y>=6 ? (phase_y-4'd6) : (phase_y+4'd10);
     if(sy<127)sy<=sy+1'b1;
    end
   end
   if(selected)begin
    if(bytes_held!=0)begin
     o_word<=joined[31:0];o_valid<=1;o_sof<=first_word;first_word<=0;
     o_eof<=sx==127 && sy==127;
     bytes_held<=bytes_held-1'b1;held<=joined[55:32];
    end else begin held<=rgb_bytes;bytes_held<=3;end
    if(sx==127)begin
     line_done<=1;
     if(sy==127)active<=0;
    end else begin
     sx<=sx+1'b1;
     next_x<=next_x+step_x;
    end
   end
  end
 end
end
endmodule

// Supports:
// display_mode 0: Left 960x1080 native 1080p camera, Right 960x1080 styled (720p half crop).
// display_mode 1: Full 1920x1080 native 1080p camera direct passthrough.
// display_mode 2: Full 1920x1080 styled (720p crop expanded to full screen).
module iris_tinyml_panels #(
 parameter [1:0] DEFAULT_BLEND = 2'd1
)(
 input wire clk,video_clk,rst_n,commit_toggle,input wire [1:0] commit_pair,
 input wire [25:0] scale_q24,
 input wire signed [8:0] zero_point,
 output reg interp_step_toggle,
 input wire [1:0] blend_mode,
 input wire [1:0] display_mode,
 output reg commit_ack,have_frame,output reg [1:0] active_pair,
 input wire i_hs,i_vs,i_de,input wire [47:0] i_rgb,
 output wire o_hs,o_vs,o_de,output wire [47:0] o_rgb,
 output reg [31:0] underflows,read_errors,
 output reg [31:0] araddr,output wire [7:0] arlen,
 output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready
);
reg [47:0] line0[0:127],line1[0:127];
reg [47:0] pixel0,pixel1;
reg [2:0] commit_sync;
reg vs_d,de_d;
reg [9:0] x;
reg [6:0] model_row,model_column,last_requested;
reg [3:0] phase_x;
reg [7:0] phase_y;
wire frame_start=i_vs && !vs_d;
reg request_toggle;
reg [6:0] request_row;
reg [1:0] request_pair,request_prev_pair;
reg [1:0] request_weight;
reg [1:0] prev_pair;
reg [2:0] display_tick;
reg [2:0] measured_period;
reg [9:0] tag0,tag1;
reg [1:0] ready_toggle;
reg [2:0] ready0_sync,ready1_sync;
reg [9:0] video_tag0,video_tag1;
wire row_good=(model_row[0] ? video_tag1 : video_tag0)=={1'b1,active_pair,model_row};
reg bank_q,second_q;
wire [47:0] pixels=bank_q ? pixel1 : pixel0;

function signed [7:0] blend_step;
  input signed [7:0] a;
  input signed [7:0] b;
  input [1:0] step;
  reg signed [9:0] sum;
  begin
    case(step)
      2'd0: blend_step = a;
      2'd1: begin
        sum = (($signed(a) <<< 1) + $signed(a) + $signed(b) + 10'sd2) >>> 2;
        blend_step = (sum < -128) ? -8'sd128 : (sum > 127) ? 8'sd127 : sum[7:0];
      end
      2'd2: begin
        sum = ($signed(a) + $signed(b) + 10'sd1) >>> 1;
        blend_step = (sum < -128) ? -8'sd128 : (sum > 127) ? 8'sd127 : sum[7:0];
      end
      default: begin
        sum = ($signed(a) + ($signed(b) <<< 1) + $signed(b) + 10'sd2) >>> 2;
        blend_step = (sum < -128) ? -8'sd128 : (sum > 127) ? 8'sd127 : sum[7:0];
      end
    endcase
  end
endfunction

function [23:0] blend_rgb_step;
  input [23:0] a;
  input [23:0] b;
  input [1:0] step;
  begin
    blend_rgb_step = {
      blend_step(a[23:16], b[23:16], step),
      blend_step(a[15:8],  b[15:8],  step),
      blend_step(a[7:0],   b[7:0],   step)
    };
  end
endfunction

function signed [7:0] blend_interp;
  input signed [7:0] p0;
  input signed [7:0] p1;
  input [1:0] weight;
  reg signed [10:0] sum;
  begin
    case(weight)
      2'd0: blend_interp = p1;
      2'd1: begin
        sum = (($signed(p0) <<< 1) + $signed(p0) + $signed(p1) + 11'sd2) >>> 2;
        blend_interp = (sum < -128) ? -8'sd128 : (sum > 127) ? 8'sd127 : sum[7:0];
      end
      2'd2: begin
        sum = ($signed(p0) + $signed(p1) + 11'sd1) >>> 1;
        blend_interp = (sum < -128) ? -8'sd128 : (sum > 127) ? 8'sd127 : sum[7:0];
      end
      default: begin
        sum = ($signed(p0) + ($signed(p1) <<< 1) + $signed(p1) + 11'sd2) >>> 2;
        blend_interp = (sum < -128) ? -8'sd128 : (sum > 127) ? 8'sd127 : sum[7:0];
      end
    endcase
  end
endfunction

function [23:0] blend_pixel_interp;
  input [23:0] px0;
  input [23:0] px1;
  input [1:0] weight;
  begin
    blend_pixel_interp = {
      blend_interp(px0[23:16], px1[23:16], weight),
      blend_interp(px0[15:8],  px1[15:8],  weight),
      blend_interp(px0[7:0],   px1[7:0],   weight)
    };
  end
endfunction

wire [1:0] step0 = (phase_x < 4'd4)  ? 2'd0 :
                   (phase_x < 4'd8)  ? 2'd1 :
                   (phase_x < 4'd12) ? 2'd2 : 2'd3;

wire [1:0] step1 = (phase_x < 4'd3)  ? 2'd0 :
                   (phase_x < 4'd7)  ? 2'd1 :
                   (phase_x < 4'd11) ? 2'd2 : 2'd3;

wire [23:0] in_px0 = (blend_mode == 2'd0) ? pixels[23:0] :
                     blend_rgb_step(pixels[23:0], pixels[47:24], step0);

wire [23:0] in_px1 = (blend_mode == 2'd0) ? (second_q ? pixels[47:24] : pixels[23:0]) :
                     (phase_x == 4'd14)   ? pixels[47:24] :
                     blend_rgb_step(pixels[23:0], pixels[47:24], step1);

wire [23:0] styled0,styled1;
iris_style_dequant u_dequant0(
 .clk(video_clk),.rst_n(rst_n),.scale_q24(scale_q24),.zero_point(zero_point),.i_valid(1'b1),.i_rgba({8'd0,in_px0}),.o_valid(),.o_rgb(styled0));
iris_style_dequant u_dequant1(
 .clk(video_clk),.rst_n(rst_n),.scale_q24(scale_q24),.zero_point(zero_point),.i_valid(1'b1),.i_rgba({8'd0,in_px1}),.o_valid(),.o_rgb(styled1));
reg [2:0] hs_pipe,vs_pipe,de_pipe,good_pipe,right_pipe,have_pipe;
reg [47:0] camera0,camera1,camera2;

wire show_style = (display_mode == 2'd2) ? have_pipe[2] :
                  (display_mode == 2'd0) ? (have_pipe[2] && right_pipe[2]) :
                  1'b0;

assign o_hs=hs_pipe[2];assign o_vs=vs_pipe[2];assign o_de=de_pipe[2];
assign o_rgb=!show_style ? camera2 :
             good_pipe[2] ? {styled0,styled1} : 48'd0;

always @(posedge video_clk)begin
 pixel0<=line0[model_column];pixel1<=line1[model_column];
end
reg [31:0] video_underflows;
wire new_commit = (commit_sync[2] != commit_ack);
wire [1:0] next_pair = new_commit ? commit_pair : active_pair;
wire [1:0] next_prev_pair = new_commit ? (have_frame ? active_pair : commit_pair) : prev_pair;
wire [2:0] next_tick = new_commit ? 3'd0 : (display_tick < 3'd7 ? display_tick + 1'b1 : 3'd7);
wire [2:0] cur_period = new_commit ? ((display_tick > 0 && display_tick < 7) ? display_tick : 3'd3) : measured_period;

wire [1:0] video_weight =
  (!have_frame || next_prev_pair == next_pair || cur_period <= 3'd1) ? 2'd0 :
  (cur_period == 3'd2) ? (next_tick == 3'd0 ? 2'd2 : 2'd0) :
  (cur_period == 3'd3) ? (next_tick == 3'd0 ? 2'd1 : next_tick == 3'd1 ? 2'd2 : 2'd0) :
  (next_tick == 3'd0 ? 2'd1 : next_tick == 3'd1 ? 2'd2 : next_tick == 3'd2 ? 2'd3 : 2'd0);

always @(posedge video_clk or negedge rst_n)begin
 if(!rst_n)begin
  commit_sync<=0;commit_ack<=0;have_frame<=0;active_pair<=0;prev_pair<=0;
  interp_step_toggle<=0;display_tick<=0;measured_period<=3'd3;
  vs_d<=0;de_d<=0;x<=0;model_row<=0;model_column<=0;phase_x<=0;phase_y<=0;last_requested<=127;
  request_toggle<=0;request_row<=0;request_pair<=0;request_prev_pair<=0;request_weight<=0;
  ready0_sync<=0;ready1_sync<=0;video_tag0<=0;video_tag1<=0;bank_q<=0;second_q<=0;
  hs_pipe<=0;vs_pipe<=0;de_pipe<=0;good_pipe<=0;right_pipe<=0;have_pipe<=0;
  camera0<=0;camera1<=0;camera2<=0;video_underflows<=0;
 end else begin
  commit_sync<={commit_sync[1:0],commit_toggle};vs_d<=i_vs;de_d<=i_de;
  ready0_sync<={ready0_sync[1:0],ready_toggle[0]};
  ready1_sync<={ready1_sync[1:0],ready_toggle[1]};
  if(ready0_sync[2]!=ready0_sync[1])video_tag0<=tag0;
  if(ready1_sync[2]!=ready1_sync[1])video_tag1<=tag1;
  if(frame_start)begin
   x<=0;model_row<=0;model_column<=0;phase_x<=0;phase_y<=0;last_requested<=127;
   if(new_commit)begin
    prev_pair<=have_frame ? active_pair : commit_pair;
    active_pair<=commit_pair;have_frame<=1;commit_ack<=commit_sync[2];
    measured_period<=(display_tick>0 && display_tick<7) ? display_tick : 3'd3;
    display_tick<=3'd0;
   end else if(have_frame)begin
    if(display_tick<3'd7)display_tick<=display_tick+1'b1;
    interp_step_toggle<=~interp_step_toggle;
   end
   if(have_frame || new_commit)begin
    request_row<=0;
    request_pair<=next_pair;
    request_prev_pair<=next_prev_pair;
    request_weight<=video_weight;
    request_toggle<=~request_toggle;
   end
  end else if(i_de)begin
   x<=x+1'b1;
   if(display_mode == 2'd2) begin
    // Full screen style: 128 columns across 960 clocks (add 2 each clock, modulo 15)
    if(phase_x>=13)begin phase_x<=phase_x-4'd13;if(model_column<127)model_column<=model_column+1'b1;end
    else phase_x<=phase_x+4'd2;
   end else if(display_mode == 2'd0 && x>=480) begin
    // Split screen: 128 columns across right 480 clocks (add 4 each clock, modulo 15)
    if(phase_x>=11)begin phase_x<=phase_x-4'd11;if(model_column<127)model_column<=model_column+1'b1;end
    else phase_x<=phase_x+4'd4;
   end
   if(display_mode != 2'd1 && x==480 && have_frame && !row_good)video_underflows<=video_underflows+1'b1;
  end else if(de_d)begin
   x<=0;model_column<=0;phase_x<=0;
   if(phase_y>=119)begin phase_y<=phase_y-8'd119;model_row<=model_row+1'b1;end
   else phase_y<=phase_y+8'd16;
   if(have_frame && model_row<127 && last_requested!=model_row)begin
    request_row<=model_row+1'b1;
    request_pair<=active_pair;
    request_prev_pair<=prev_pair;
    request_weight<=video_weight;
    request_toggle<=~request_toggle;
    last_requested<=model_row;
   end
  end
  bank_q<=model_row[0];second_q<=phase_x==14;
  hs_pipe<={hs_pipe[1:0],i_hs};vs_pipe<={vs_pipe[1:0],i_vs};de_pipe<={de_pipe[1:0],i_de};
  good_pipe<={good_pipe[1:0],row_good};right_pipe<={right_pipe[1:0],x>=480};have_pipe<={have_pipe[1:0],have_frame};
  camera0<=i_rgb;camera1<=camera0;camera2<=camera1;
 end
end

function [127:0] blend_beat;
  input [127:0] b0;
  input [127:0] b1;
  input [1:0] w;
  integer idx;
  begin
    for (idx = 0; idx < 16; idx = idx + 1) begin
      blend_beat[idx*8 +: 8] = blend_interp(b0[idx*8 +: 8], b1[idx*8 +: 8], w);
    end
  end
endfunction

localparam IDLE=0,ADDR=1,DATA=2,UNPACK=3,FINISH=4;
reg [2:0] state;
reg [2:0] request_sync;
reg pending,read_bad,pass;
reg [6:0] pending_row,row;
reg [1:0] pending_pair,pending_prev_pair,pending_weight;
reg [1:0] pair,prev_pair_q,cur_weight;
reg [4:0] beat;
reg [7:0] column;
reg [4:0] byte_count;
reg [143:0] reservoir;
reg [23:0] previous_pixel;
(* syn_ramstyle = "block_ram" *) reg [127:0] prev_beat[0:31];
reg [127:0] prev_beat_reg;

wire request_edge=request_sync[2]!=request_sync[1];
assign arlen=0;assign arvalid=state==ADDR;assign rready=state==DATA;

wire [127:0] beat_data = (cur_weight == 2'd0) ? rdata : blend_beat(prev_beat_reg, rdata, cur_weight);
wire write_pixel=(state==UNPACK && byte_count>=3 && column!=0) || state==FINISH;
wire [6:0] write_column=state==FINISH ? 7'd127 : column[6:0]-1'b1;
wire [47:0] write_pair=state==FINISH ? {previous_pixel,previous_pixel} : {reservoir[23:0],previous_pixel};

always @(posedge clk)begin
 if(write_pixel)begin
  if(row[0])line1[write_column]<=write_pair;else line0[write_column]<=write_pair;
 end
end
reg [31:0] underflow_gray,uf_sync1,uf_sync2;
integer k;
always @(posedge video_clk or negedge rst_n)
 if(!rst_n)underflow_gray<=0;else underflow_gray<=(video_underflows>>1)^video_underflows;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;request_sync<=0;pending<=0;read_bad<=0;pass<=1;
  pending_row<=0;pending_pair<=0;pending_prev_pair<=0;pending_weight<=0;
  pair<=0;prev_pair_q<=0;cur_weight<=0;
  row<=0;beat<=0;column<=0;byte_count<=0;reservoir<=0;previous_pixel<=0;prev_beat_reg<=0;
  araddr<=0;tag0<=0;tag1<=0;ready_toggle<=0;read_errors<=0;underflows<=0;uf_sync1<=0;uf_sync2<=0;
 end else begin
  request_sync<={request_sync[1:0],request_toggle};
  if(request_edge)begin
   pending<=1;
   pending_row<=request_row;
   pending_pair<=request_pair;
   pending_prev_pair<=request_prev_pair;
   pending_weight<=request_weight;
  end
  uf_sync1<=underflow_gray;uf_sync2<=uf_sync1;
  for(k=31;k>=0;k=k-1)underflows[k]<=^(uf_sync2>>k);
  prev_beat_reg<=prev_beat[beat];
  case(state)
   IDLE:if(pending)begin
    row<=pending_row;pair<=pending_pair;prev_pair_q<=pending_prev_pair;cur_weight<=pending_weight;
    pending<=request_edge;read_bad<=0;
    if(pending_row[0])begin tag1<=0;ready_toggle[1]<=~ready_toggle[1];end
    else begin tag0<=0;ready_toggle[0]<=~ready_toggle[0];end
    beat<=0;column<=0;byte_count<=0;reservoir<=0;previous_pixel<=0;
    pass<=(pending_weight==2'd0);
    araddr<=(((pending_weight!=2'd0 ? pending_prev_pair : pending_pair)==2 ? 32'h03a00000 :
              (pending_weight!=2'd0 ? pending_prev_pair : pending_pair)==1 ? 32'h03600000 : 32'h03400000)+
             ({25'd0,pending_row}<<8)+({25'd0,pending_row}<<7));
    state<=ADDR;
   end
   ADDR:if(arready)state<=DATA;
   DATA:if(rvalid)begin
    if(rresp!=0 || !rlast || read_bad)begin
     read_bad<=1;
     if(rlast)begin read_errors<=read_errors+1'b1;state<=IDLE;end
    end else if(!pass)begin
     prev_beat[beat]<=rdata;
     if(beat==23)begin
      pass<=1;beat<=0;column<=0;byte_count<=0;reservoir<=0;previous_pixel<=0;
      araddr<=(pair==2 ? 32'h03a00000 : pair==1 ? 32'h03600000 : 32'h03400000)+
              ({25'd0,row}<<8)+({25'd0,row}<<7);
      state<=ADDR;
     end else begin
      beat<=beat+1'b1;araddr<=araddr+32'd16;state<=ADDR;
     end
    end else begin
     case(byte_count)
      0:reservoir<={16'd0,beat_data};
      1:reservoir<={8'd0,beat_data,reservoir[7:0]};
      2:reservoir<={beat_data,reservoir[15:0]};
      default:reservoir<=0;
     endcase
     byte_count<=byte_count+5'd16;state<=UNPACK;
    end
   end
   UNPACK:if(byte_count>=3)begin
    previous_pixel<=reservoir[23:0];reservoir<=reservoir>>24;byte_count<=byte_count-2'd3;column<=column+1'b1;
   end else if(beat==23)begin
    if(column==128 && byte_count==0)state<=FINISH;
    else begin read_errors<=read_errors+1'b1;state<=IDLE;end
   end else begin beat<=beat+1'b1;araddr<=araddr+32'd16;state<=ADDR;end
   FINISH:begin
    if(row[0])begin tag1<={1'b1,pair,row};ready_toggle[1]<=~ready_toggle[1];end
    else begin tag0<={1'b1,pair,row};ready_toggle[0]<=~ready_toggle[0];end
    state<=IDLE;
   end
  endcase
 end
end
endmodule
