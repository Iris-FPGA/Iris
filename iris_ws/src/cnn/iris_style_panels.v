// One centred 1440x1080 image: original left half, styled right half.
// Render native pixels before enlarging them, so ink keeps source neighbours.
// Four line buffers prefetch three rows ahead to absorb shared-DDR stalls.
// The deadline is checked once at each line start. A missed
// deadline paints the complete line black instead of exposing partial DMA.
module iris_style_panels #(parameter [24:0] SCALE_Q24=25'd20591742,parameter ENABLE_VISIBILITY=0)(
 input wire clk,video_clk,rst_n,
 input wire commit_toggle,input wire [1:0] commit_pair,
 output reg commit_ack,have_frame,output reg [1:0] active_pair,
 input wire [1:0] visibility_mode,input wire visibility_toggle,output reg visibility_ack,
 input wire i_hs,i_vs,i_de,input wire [47:0] i_rgb,
 output wire o_hs,o_vs,o_de,output wire [47:0] o_rgb,
 output reg [31:0] underflows,read_errors,
 output reg [31:0] araddr,output reg [7:0] arlen,
 output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready
);
reg [2:0] commit_sync;
reg [2:0] visibility_sync;
reg [1:0] mode_live;
reg vs_d,de_d;
reg [10:0] x,y;
reg req_toggle;reg [1:0] req_pair;
reg [8:0] req_row;
reg req_prime;
reg [8:0] current_row;
reg [3:0] row_phase;
reg [127:0] line0[0:319],line1[0:319],line2[0:319],line3[0:319];
reg [127:0] word0_q,word1_q,word2_q,word3_q;
reg [1:0] word_bank_q;
reg word_half_q;
wire [127:0] word_q=word_bank_q==3 ? word3_q : word_bank_q==2 ? word2_q : word_bank_q==1 ? word1_q : word0_q;
reg line_good,neighbor_line_good,neighbor_good_q,first_right_q,right_q;
reg [31:0] previous_pixel;
reg [11:0] tag0,tag1,tag2,tag3; // valid,pair,row
reg [3:0] ready_toggle;
reg [2:0] ready0_sync,ready1_sync,ready2_sync,ready3_sync;
reg [11:0] video_tag0,video_tag1,video_tag2,video_tag3;
reg [31:0] video_underflows;
wire frame_start=i_vs && !vs_d;
wire line_start=i_de && !de_d;
// Original columns 0..319 are rendered first. Then scan all 640 style
// columns (including hidden left columns for the ink neighbourhood).
wire panel_left=x<160;
wire panel_right=x>=320 && x<480;
wire [8:0] word_index=x<160 ? (x>>1) : x<480 ? 9'd160+((x-11'd160)>>1) : 9'd0;
wire [11:0] current_tag=current_row[1:0]==3 ? video_tag3 : current_row[1:0]==2 ? video_tag2 : current_row[1:0]==1 ? video_tag1 : video_tag0;
wire row_ready=have_frame && current_tag=={1'b1,active_pair,current_row};
wire [8:0] next_row=current_row+1'b1;
wire [11:0] next_tag=next_row[1:0]==3 ? video_tag3 : next_row[1:0]==2 ? video_tag2 : next_row[1:0]==1 ? video_tag1 : video_tag0;
wire next_ready=current_row<479 && next_tag=={1'b1,active_pair,next_row};
wire [63:0] pixel_pair=word_half_q ? word_q[127:64] : word_q[63:0];
wire [1:0] next_bank=word_bank_q+2'd1;
wire [127:0] next_word=next_bank==3 ? word3_q : next_bank==2 ? word2_q : next_bank==1 ? word1_q : word0_q;
wire [63:0] next_pixels=word_half_q ? next_word[127:64] : next_word[63:0];
function [31:0] darker;
 input [31:0] a,b;
 integer ch;
 begin
  darker=32'h80000000;
  for(ch=0;ch<3;ch=ch+1)darker[ch*8+:8]=$signed(a[ch*8+:8])<$signed(b[ch*8+:8]) ? a[ch*8+:8] : b[ch*8+:8];
 end
endfunction
// Row+1 is resident in a different prefetched bank. Row-1 can be overwritten
// by row+3, so it must never be used as a display neighbourhood.
wire thicken=ENABLE_VISIBILITY && mode_live[1];
wire [31:0] vertical0=thicken && neighbor_good_q ? darker(pixel_pair[31:0],next_pixels[31:0]) : pixel_pair[31:0];
wire [31:0] vertical1=thicken && neighbor_good_q ? darker(pixel_pair[63:32],next_pixels[63:32]) : pixel_pair[63:32];
wire [31:0] filtered0=thicken && !first_right_q ? darker(vertical0,previous_pixel) : vertical0;
wire [31:0] filtered1=thicken ? darker(vertical1,vertical0) : vertical1;
wire [23:0] deq0,deq1;wire deq_valid0,deq_valid1;
iris_style_dequant #(.SCALE_Q24(SCALE_Q24)) u_deq0(.clk(video_clk),.rst_n(rst_n),.i_valid(1'b1),.i_rgba(filtered0),.o_valid(deq_valid0),.o_rgb(deq0));
iris_style_dequant #(.SCALE_Q24(SCALE_Q24)) u_deq1(.clk(video_clk),.rst_n(rst_n),.i_valid(1'b1),.i_rgba(filtered1),.o_valid(deq_valid1),.o_rgb(deq1));
wire [23:0] styled0,styled1;
generate if(ENABLE_VISIBILITY)begin : g_ink
 iris_style_ink u_ink0(.clk(video_clk),.rst_n(rst_n),.i_valid(deq_valid0),.i_mode(mode_live),.i_rgb(deq0),.o_valid(),.o_rgb(styled0));
 iris_style_ink u_ink1(.clk(video_clk),.rst_n(rst_n),.i_valid(deq_valid1),.i_mode(mode_live),.i_rgb(deq1),.o_valid(),.o_rgb(styled1));
end else begin : g_plain
 assign styled0=deq0;assign styled1=deq1;
end endgenerate
localparam DELAY=ENABLE_VISIBILITY ? 5 : 3;
reg [47:0] plain_pipe[0:DELAY-2];
reg [DELAY-1:0] inside_pipe,good_pipe,panel_pipe;
reg [8:0] column_pipe[0:DELAY-1];
integer stage;
iris_style_split_scaler u_split_scaler(
 .clk(video_clk),.rst_n(rst_n),.i_hs(i_hs),.i_vs(i_vs),.i_de(i_de),
 .i_have_frame(have_frame),.i_good(line_good),.i_x(x),
 .i_source_valid(inside_pipe[DELAY-1] && good_pipe[DELAY-1]),
 .i_source_addr(column_pipe[DELAY-1]),
 .i_source_rgb(panel_pipe[DELAY-1] ? {styled0,styled1} : plain_pipe[DELAY-2]),
 .o_hs(o_hs),.o_vs(o_vs),.o_de(o_de),.o_rgb(o_rgb));
// Memory ports have no reset, so Efinity can infer true dual-clock block RAM.
always @(posedge video_clk)begin
 word0_q<=line0[word_index];
 word1_q<=line1[word_index];
 word2_q<=line2[word_index];
 word3_q<=line3[word_index];
end
always @(posedge video_clk or negedge rst_n)begin
 if(!rst_n)begin
  commit_sync<=0;commit_ack<=0;active_pair<=0;have_frame<=0;
  visibility_sync<=0;visibility_ack<=0;mode_live<=ENABLE_VISIBILITY ? 2 : 0;
  vs_d<=0;de_d<=0;x<=0;y<=0;req_toggle<=0;req_pair<=0;req_row<=0;req_prime<=0;current_row<=0;row_phase<=0;
  ready0_sync<=0;ready1_sync<=0;ready2_sync<=0;ready3_sync<=0;video_tag0<=0;video_tag1<=0;video_tag2<=0;video_tag3<=0;video_underflows<=0;
  word_bank_q<=0;word_half_q<=0;line_good<=0;neighbor_line_good<=0;neighbor_good_q<=0;first_right_q<=0;right_q<=0;previous_pixel<=32'h80808080;
  for(stage=0;stage<DELAY;stage=stage+1)column_pipe[stage]<=0;
  for(stage=0;stage<DELAY-1;stage=stage+1)plain_pipe[stage]<=0;
  inside_pipe<=0;good_pipe<=0;panel_pipe<=0;
 end else begin
  commit_sync<={commit_sync[1:0],commit_toggle};vs_d<=i_vs;de_d<=i_de;
  visibility_sync<={visibility_sync[1:0],visibility_toggle};
  ready0_sync<={ready0_sync[1:0],ready_toggle[0]};
  ready1_sync<={ready1_sync[1:0],ready_toggle[1]};
  ready2_sync<={ready2_sync[1:0],ready_toggle[2]};
  ready3_sync<={ready3_sync[1:0],ready_toggle[3]};
  if(ready2_sync[2]!=ready2_sync[1])video_tag2<=tag2;
  if(ready3_sync[2]!=ready3_sync[1])video_tag3<=tag3;
  if(ready0_sync[2]!=ready0_sync[1])video_tag0<=tag0;
  if(ready1_sync[2]!=ready1_sync[1])video_tag1<=tag1;
  if(frame_start)begin
   x<=0;y<=0;current_row<=0;row_phase<=0;
   // Prime rows 0..3 in vertical blanking, including on a pair switch.
   if(have_frame || commit_sync[2]!=commit_ack)begin
    req_row<=0;req_pair<=commit_sync[2]!=commit_ack ? commit_pair : active_pair;
    req_prime<=1;req_toggle<=~req_toggle;
   end
   if(ENABLE_VISIBILITY && visibility_sync[2]!=visibility_ack)begin mode_live<=visibility_mode;visibility_ack<=visibility_sync[2];end
   if(commit_sync[2]!=commit_ack)begin
    active_pair<=commit_pair;have_frame<=1;commit_ack<=commit_sync[2];
   end
  end else if(i_de)begin
   x<=x+1'b1;
   if(line_start)begin
    line_good<=row_ready;
    neighbor_line_good<=next_ready;
    if(have_frame && current_row<480 && !row_ready)video_underflows<=video_underflows+1'b1;
   end
  end else begin
   x<=0;
   if(de_d)begin
    y<=y+1'b1;
    // floor(screen_y*4/9), without a divider in the video clock path.
    if(row_phase>=5)begin
     row_phase<=row_phase-4'd5;current_row<=current_row+1'b1;
     if(have_frame && current_row<476)begin
      req_row<=current_row+9'd4;req_pair<=active_pair;req_prime<=0;req_toggle<=~req_toggle;
     end
    end else row_phase<=row_phase+4'd4;
   end
  end
  word_bank_q<=current_row[1:0];word_half_q<=x[0];
  neighbor_good_q<=neighbor_line_good;first_right_q<=x==160;right_q<=i_de && x>=160 && x<480;
  if(right_q)previous_pixel<=vertical1;
  plain_pipe[0]<={pixel_pair[7:0]^8'h80,pixel_pair[15:8]^8'h80,pixel_pair[23:16]^8'h80,
             pixel_pair[39:32]^8'h80,pixel_pair[47:40]^8'h80,pixel_pair[55:48]^8'h80};
  for(stage=1;stage<DELAY-1;stage=stage+1)plain_pipe[stage]<=plain_pipe[stage-1];
  column_pipe[0]<=panel_left ? x[8:0] : x-11'd160;
  for(stage=1;stage<DELAY;stage=stage+1)column_pipe[stage]<=column_pipe[stage-1];
  inside_pipe<={inside_pipe[DELAY-2:0],i_de && have_frame && (panel_left || panel_right)};
  good_pipe<={good_pipe[DELAY-2:0],line_start ? row_ready : line_good};panel_pipe<={panel_pipe[DELAY-2:0],panel_right};
 end
end
reg [2:0] req_sync;
reg pending;reg [1:0] pending_pair;
reg pending_prime,priming;
reg [8:0] pending_row;
localparam IDLE=0,ADDR=1,DATA=2,PLAN=3;
reg [1:0] state;
reg [8:0] row,word_count;
reg [1:0] pair_q;reg bad;
reg [7:0] remaining;
wire request_edge=req_sync[2]!=req_sync[1];
wire [31:0] input_base=pair_q==2 ? 32'h03800000 : pair_q==1 ? 32'h03200000 : 32'h03000000;
wire [31:0] output_base=pair_q==2 ? 32'h03a00000 : pair_q==1 ? 32'h03600000 : 32'h03400000;
wire [31:0] row_offset=({23'd0,row}<<11)+({23'd0,row}<<9);
wire [31:0] next_addr=(word_count<160 ? input_base : output_base)+row_offset+
                         ((word_count<160 ? {23'd0,word_count} : {23'd0,word_count}-32'd160)<<4);
wire [8:0] page_words=9'd256-{1'b0,next_addr[11:4]};
wire [8:0] panel_words=word_count<160 ? 9'd160-word_count : 9'd320-word_count;
wire [8:0] burst_words=panel_words>128 ? (page_words>128 ? 9'd128 : page_words) :
                                               (page_words>panel_words ? panel_words : page_words);
assign arvalid=state==ADDR;
assign rready=state==DATA;
always @(posedge clk)begin
 if(rvalid && rready && rresp==0)begin
  case(row[1:0])
   0:line0[word_count]<=rdata;
   1:line1[word_count]<=rdata;
   2:line2[word_count]<=rdata;
   3:line3[word_count]<=rdata;
  endcase
 end
end
// Gray counter crosses for diagnostics; not used for ownership or deadlines.
reg [31:0] underflow_gray,uf_sync1,uf_sync2;
integer k;
always @(posedge video_clk or negedge rst_n)
 if(!rst_n)underflow_gray<=0;
 else underflow_gray<=(video_underflows>>1)^video_underflows;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  req_sync<=0;pending<=0;pending_row<=0;pending_pair<=0;pending_prime<=0;priming<=0;
  row<=0;pair_q<=0;word_count<=0;state<=IDLE;bad<=0;remaining<=0;
  araddr<=0;arlen<=0;tag0<=0;tag1<=0;tag2<=0;tag3<=0;ready_toggle<=0;
  read_errors<=0;underflows<=0;uf_sync1<=0;uf_sync2<=0;
 end else begin
  req_sync<={req_sync[1:0],req_toggle};
  uf_sync1<=underflow_gray;uf_sync2<=uf_sync1;
  underflows[31]<=uf_sync2[31];
  for(k=30;k>=0;k=k-1)underflows[k]<=^(uf_sync2>>k);
  if(request_edge)begin pending<=1;pending_row<=req_row;pending_pair<=req_pair;pending_prime<=req_prime;end
  case(state)
   IDLE:if(pending)begin
    row<=pending_row;pair_q<=pending_pair;priming<=pending_prime;word_count<=0;bad<=0;
    pending<=request_edge;state<=PLAN;
   end
   PLAN:begin
    araddr<=next_addr;arlen<=burst_words-1'b1;remaining<=burst_words;state<=ADDR;
   end
   ADDR:if(arready)state<=DATA;
   DATA:if(rvalid)begin
    word_count<=word_count+1'b1;remaining<=remaining-1'b1;
    if(rresp!=0 || rlast!=(remaining==1))bad<=1;
    if(rlast)begin
     if(remaining!=1 || rresp!=0 || bad)begin
      read_errors<=read_errors+1'b1;
      if(priming && row<3)begin row<=row+1'b1;word_count<=0;bad<=0;state<=PLAN;end
      else state<=IDLE;
     end else if(word_count==319)begin
      case(row[1:0])
       0:begin tag0<={1'b1,pair_q,row};ready_toggle[0]<=~ready_toggle[0];end
       1:begin tag1<={1'b1,pair_q,row};ready_toggle[1]<=~ready_toggle[1];end
       2:begin tag2<={1'b1,pair_q,row};ready_toggle[2]<=~ready_toggle[2];end
       3:begin tag3<={1'b1,pair_q,row};ready_toggle[3]<=~ready_toggle[3];end
      endcase
      if(priming && row<3)begin row<=row+1'b1;word_count<=0;bad<=0;state<=PLAN;end
      else state<=IDLE;
     end else state<=PLAN;
    end
   end
  endcase
 end
end
endmodule
