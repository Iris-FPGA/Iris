// One centred 1440x1080 image: original left half, styled right half.
// Compute contours at native resolution before the common 9/4 enlargement.
// Six banks retain five stencil rows while row+3 is prefetched separately.
// The deadline is checked once at each line start. A missed
// deadline paints the complete line black instead of exposing partial DMA.
module iris_style_contour_panels #(parameter [24:0] SCALE_Q24=25'd20591742,parameter ENABLE_VISIBILITY=0,parameter NATIVE_CAMERA_LEFT=1)(
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
// Four compact full-colour banks; six camera-grey banks.
// Retain only the visible original 0..319 and neural 320..639 columns.
// Hidden camera columns still populate the complete grey contour stencil.
// The grey stencil keeps row-2..row+2 while row+3 fills the spare bank.
// Share one read port across the four rows. A row occupies a 256-word
// address slice; only 160 words are used. Strip the unused INT8 alpha bytes
// explicitly so the block RAM maps as 1024x96 instead of four wide RAMs.
(* syn_ramdecomp="area" *) reg [95:0] colour_rows[0:1023];
reg [31:0] grey0[0:159],grey1[0:159],grey2[0:159],grey3[0:159],grey4[0:159],grey5[0:159];
reg [95:0] colour_q;
reg [31:0] grey_q[0:5];
reg word_half_q;
reg line_good,first_right_q,last_right_q,right_q;
reg [14:0] stencil_banks,stencil_banks_q;
reg [11:0] tag0,tag1,tag2,tag3,tag4,tag5;
reg [5:0] ready_toggle;
reg [2:0] ready0_sync,ready1_sync,ready2_sync,ready3_sync,ready4_sync,ready5_sync;
reg [11:0] video_tag0,video_tag1,video_tag2,video_tag3,video_tag4,video_tag5;
reg [31:0] video_underflows;
wire frame_start=i_vs && !vs_d;
wire line_start=i_de && !de_d;
// Scan all native style columns, including hidden columns left of the seam,
// to preserve the full-frame 5x5 contour at source column 320.
wire panel_left=x<160;
wire panel_right=x>=320 && x<480;
wire [7:0] grey_index=x>=160 && x<480 ? ((x-11'd160)>>1) : 8'd0;
wire [7:0] word_index=panel_left ? (x>>1) : x<480 ? grey_index : 8'd0;
wire [2:0] current_bank=current_row%6;
// Make every tag an explicit function input, so a DDR-ready update also
// re-evaluates row zero and neighbours when the source row has not changed.
wire [71:0] video_tags={video_tag5,video_tag4,video_tag3,video_tag2,video_tag1,video_tag0};
function [11:0] video_tag;
 input [2:0] bank;
 input [71:0] tags;
 begin case(bank)
  0:video_tag=tags[11:0];1:video_tag=tags[23:12];2:video_tag=tags[35:24];
  3:video_tag=tags[47:36];4:video_tag=tags[59:48];default:video_tag=tags[71:60];
 endcase end
endfunction
wire row_ready=have_frame && video_tag(current_bank,video_tags)=={1'b1,active_pair,current_row};
function [2:0] neighbour_bank;
 input [8:0] centre;
 input integer offset;
 input [71:0] tags;
 input [1:0] pair;
 integer row_index;
 reg [2:0] bank;
 begin
  row_index=centre+offset;
  if(row_index<0)row_index=0;
  if(row_index>479)row_index=479;
  bank=row_index[8:0]%6;
  neighbour_bank=video_tag(bank,tags)=={1'b1,pair,row_index[8:0]} ? bank : centre%6;
 end
endfunction
wire [14:0] ready_banks={neighbour_bank(current_row,2,video_tags,active_pair),neighbour_bank(current_row,1,video_tags,active_pair),
 current_bank,neighbour_bank(current_row,-1,video_tags,active_pair),neighbour_bank(current_row,-2,video_tags,active_pair)};
wire [47:0] colour_pair=word_half_q ? colour_q[95:48] : colour_q[47:0];
wire [63:0] plain_pair={8'h80,colour_pair[47:24],8'h80,colour_pair[23:0]};
wire [63:0] neural_pair=plain_pair;
wire [79:0] grey_rows;
function [7:0] grey;
 input [31:0] rgba;
 reg [9:0] sum;
 begin
  sum={2'b0,(rgba[7:0]^8'h80)}+({2'b0,(rgba[15:8]^8'h80)}<<1)+{2'b0,(rgba[23:16]^8'h80)}+10'd2;
  grey=sum[9:2];
 end
endfunction
genvar r;
generate for(r=0;r<5;r=r+1)begin : g_grey
 wire [31:0] row_word=grey_q[stencil_banks_q[r*3+:3]];
 assign grey_rows[r*16+:16]=word_half_q ? row_word[31:16] : row_word[15:0];
end endgenerate
wire [47:0] styled;
iris_style_contour #(.SCALE_Q24(SCALE_Q24)) u_contour(
 .clk(video_clk),.rst_n(rst_n),.i_valid(right_q),.i_first(first_right_q),.i_last(last_right_q),
 .i_mode(mode_live),.i_grey_rows(grey_rows),.i_neural_rgba(neural_pair),.o_valid(),.o_rgb(styled));
localparam DELAY=7;
reg [47:0] plain_pipe[0:DELAY-2];
reg [DELAY-1:0] inside_pipe,good_pipe,panel_pipe;
reg [8:0] column_pipe[0:DELAY-1];
integer stage;
wire scaled_hs,scaled_vs,scaled_de;
wire [47:0] scaled_rgb;
reg [47:0] camera0,camera1;
reg [1:0] camera_valid;
always @(posedge video_clk or negedge rst_n)begin
 if(!rst_n)begin camera0<=0;camera1<=0;camera_valid<=0;end
 else begin
  camera0<=i_rgb;camera1<=camera0;
  camera_valid<={camera_valid[0],NATIVE_CAMERA_LEFT && have_frame && i_de && x>=120 && x<480};
 end
end
assign o_hs=scaled_hs;assign o_vs=scaled_vs;assign o_de=scaled_de;
// Original screen pixels 240..959 come directly from the native camera.
// The right half retains the existing CNN renderer and 9/4 enlargement.
assign o_rgb=camera_valid[1] ? camera1 : scaled_rgb;
iris_style_split_scaler u_split_scaler(
 .clk(video_clk),.rst_n(rst_n),.i_hs(i_hs),.i_vs(i_vs),.i_de(i_de),
 .i_have_frame(have_frame),.i_good(line_good),.i_x(x),
 .i_source_valid(inside_pipe[DELAY-1] && good_pipe[DELAY-1]),
 .i_source_addr(column_pipe[DELAY-1]),
 .i_source_rgb(panel_pipe[DELAY-1] ? styled : plain_pipe[DELAY-2]),
 .o_hs(scaled_hs),.o_vs(scaled_vs),.o_de(scaled_de),.o_rgb(scaled_rgb));
// Memory ports have no reset, so Efinity can infer true dual-clock block RAM.
always @(posedge video_clk)begin
 colour_q<=colour_rows[{current_row[1:0],word_index}];
 grey_q[0]<=grey0[grey_index];grey_q[1]<=grey1[grey_index];grey_q[2]<=grey2[grey_index];
 grey_q[3]<=grey3[grey_index];grey_q[4]<=grey4[grey_index];grey_q[5]<=grey5[grey_index];
end
always @(posedge video_clk or negedge rst_n)begin
 if(!rst_n)begin
  commit_sync<=0;commit_ack<=0;active_pair<=0;have_frame<=0;
  visibility_sync<=0;visibility_ack<=0;mode_live<=ENABLE_VISIBILITY ? 2 : 0;
  vs_d<=0;de_d<=0;x<=0;y<=0;req_toggle<=0;req_pair<=0;req_row<=0;req_prime<=0;current_row<=0;row_phase<=0;
  ready0_sync<=0;ready1_sync<=0;ready2_sync<=0;ready3_sync<=0;ready4_sync<=0;ready5_sync<=0;video_tag4<=0;video_tag5<=0;video_tag0<=0;video_tag1<=0;video_tag2<=0;video_tag3<=0;video_underflows<=0;
  word_half_q<=0;line_good<=0;first_right_q<=0;last_right_q<=0;right_q<=0;stencil_banks<=0;stencil_banks_q<=0;
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
  ready4_sync<={ready4_sync[1:0],ready_toggle[4]};
  ready5_sync<={ready5_sync[1:0],ready_toggle[5]};
  if(ready5_sync[2]!=ready5_sync[1])video_tag5<=tag5;
  if(ready4_sync[2]!=ready4_sync[1])video_tag4<=tag4;
  if(ready2_sync[2]!=ready2_sync[1])video_tag2<=tag2;
  if(ready3_sync[2]!=ready3_sync[1])video_tag3<=tag3;
  if(ready0_sync[2]!=ready0_sync[1])video_tag0<=tag0;
  if(ready1_sync[2]!=ready1_sync[1])video_tag1<=tag1;
  if(frame_start)begin
   x<=0;y<=0;current_row<=0;row_phase<=0;
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
    if(have_frame && current_row<480 && !row_ready)video_underflows<=video_underflows+1'b1;
   end
  end else begin
   x<=0;
   if(de_d)begin
    y<=y+1'b1;
    if(row_phase>=5)begin
     row_phase<=row_phase-4'd5;current_row<=current_row+1'b1;
     if(have_frame && current_row<476)begin
      req_row<=current_row+9'd4;req_pair<=active_pair;req_prime<=0;req_toggle<=~req_toggle;
     end
    end else row_phase<=row_phase+4'd4;
   end
  end
  // Modulo-six row+3 occupies row-3, preserving both previous stencil rows.
  if(i_de && x==160)stencil_banks<=ready_banks;
  stencil_banks_q<=i_de && x==160 ? ready_banks : stencil_banks;
  word_half_q<=x[0];
  first_right_q<=x==160;last_right_q<=x==479;right_q<=i_de && x>=160 && x<480;
  plain_pipe[0]<={plain_pair[7:0]^8'h80,plain_pair[15:8]^8'h80,plain_pair[23:16]^8'h80,
             plain_pair[39:32]^8'h80,plain_pair[47:40]^8'h80,plain_pair[55:48]^8'h80};
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
wire [2:0] refill_bank=row%6;
wire [7:0] refill_index=word_count<160 ? word_count : word_count-160;
wire [31:0] refill_grey={grey(rdata[127:96]),grey(rdata[95:64]),grey(rdata[63:32]),grey(rdata[31:0])};
wire colour_visible=word_count<80 || word_count>=240;
wire [7:0] colour_index=word_count<80 ? word_count[7:0] : word_count-9'd160;
always @(posedge clk)begin
 if(rvalid && rready && rresp==0)begin
  if(colour_visible)colour_rows[{row[1:0],colour_index}]<=
    {rdata[119:96],rdata[87:64],rdata[55:32],rdata[23:0]};
  if(word_count<160)case(refill_bank)
   0:grey0[refill_index]<=refill_grey;1:grey1[refill_index]<=refill_grey;2:grey2[refill_index]<=refill_grey;
   3:grey3[refill_index]<=refill_grey;4:grey4[refill_index]<=refill_grey;5:grey5[refill_index]<=refill_grey;
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
  araddr<=0;arlen<=0;tag0<=0;tag1<=0;tag2<=0;tag3<=0;tag4<=0;tag5<=0;ready_toggle<=0;
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
      case(refill_bank)
       0:begin tag0<={1'b1,pair_q,row};ready_toggle[0]<=~ready_toggle[0];end
       1:begin tag1<={1'b1,pair_q,row};ready_toggle[1]<=~ready_toggle[1];end
       2:begin tag2<={1'b1,pair_q,row};ready_toggle[2]<=~ready_toggle[2];end
       3:begin tag3<={1'b1,pair_q,row};ready_toggle[3]<=~ready_toggle[3];end
       4:begin tag4<={1'b1,pair_q,row};ready_toggle[4]<=~ready_toggle[4];end
       5:begin tag5<={1'b1,pair_q,row};ready_toggle[5]<=~ready_toggle[5];end
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
