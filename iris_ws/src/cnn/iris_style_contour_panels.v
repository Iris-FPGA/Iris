// 1080p two-pixel stream with matched 640x480 input/style panels.
// Input panel x=160,y=300; style x=1120,y=300; background remains live.
// Six banks retain five stencil rows while row+3 is prefetched separately.
// The deadline is checked once at each line start. A missed
// deadline paints the complete line black instead of exposing partial DMA.
module iris_style_contour_panels #(parameter [24:0] SCALE_Q24=25'd20591742,parameter ENABLE_VISIBILITY=0)(
 input wire clk,video_clk,rst_n,
 input wire commit_toggle,commit_pair,
 output reg commit_ack,active_pair,have_frame,
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
reg req_toggle,req_pair;
reg [8:0] req_row;
// Four original full-colour banks; six compact camera-grey banks.
// The grey stencil keeps row-2..row+2 while row+3 fills the spare bank.
reg [127:0] line0[0:319],line1[0:319],line2[0:319],line3[0:319];
reg [31:0] grey0[0:159],grey1[0:159],grey2[0:159],grey3[0:159],grey4[0:159],grey5[0:159];
reg [127:0] word0_q,word1_q,word2_q,word3_q;
reg [31:0] grey_q[0:5];
reg [1:0] word_bank_q;
reg word_half_q;
reg line_good,first_right_q,last_right_q,right_q;
reg [14:0] stencil_banks,stencil_banks_q;
reg [10:0] tag0,tag1,tag2,tag3,tag4,tag5;
reg [5:0] ready_toggle;
reg [2:0] ready0_sync,ready1_sync,ready2_sync,ready3_sync,ready4_sync,ready5_sync;
reg [10:0] video_tag0,video_tag1,video_tag2,video_tag3,video_tag4,video_tag5;
reg [31:0] video_underflows;
wire frame_start=i_vs && !vs_d;
wire line_start=i_de && !de_d;
wire panel_left=x>=80 && x<400;
wire panel_right=x>=560 && x<880;
wire panel_row=y>=300 && y<780;
wire [8:0] current_row=y-11'd300;
wire [7:0] grey_index=panel_left ? ((x-11'd80)>>1) : ((x-11'd560)>>1);
wire [8:0] word_index=panel_left ? {1'b0,grey_index} : 9'd160+grey_index;
wire [2:0] current_bank=current_row%6;
function [10:0] video_tag;
 input [2:0] bank;
 begin case(bank)
  0:video_tag=video_tag0;1:video_tag=video_tag1;2:video_tag=video_tag2;
  3:video_tag=video_tag3;4:video_tag=video_tag4;default:video_tag=video_tag5;
 endcase end
endfunction
wire row_ready=have_frame && video_tag(current_bank)=={1'b1,active_pair,current_row};
function [2:0] neighbour_bank;
 input [8:0] centre;
 input integer offset;
 integer row_index;
 reg [2:0] bank;
 begin
  row_index=centre+offset;
  if(row_index<0)row_index=0;
  if(row_index>479)row_index=479;
  bank=row_index[8:0]%6;
  neighbour_bank=video_tag(bank)=={1'b1,active_pair,row_index[8:0]} ? bank : centre%6;
 end
endfunction
wire [14:0] ready_banks={neighbour_bank(current_row,2),neighbour_bank(current_row,1),
 current_bank,neighbour_bank(current_row,-1),neighbour_bank(current_row,-2)};
wire [127:0] word_q=word_bank_q==3 ? word3_q : word_bank_q==2 ? word2_q : word_bank_q==1 ? word1_q : word0_q;
wire [63:0] plain_pair=word_half_q ? word_q[127:64] : word_q[63:0];
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
reg [50:0] bg[0:DELAY-1];
reg [DELAY-1:0] inside_pipe,good_pipe,panel_pipe;
integer stage;
assign {o_hs,o_vs,o_de}=bg[DELAY-1][50:48];
assign o_rgb=inside_pipe[DELAY-1] ? (good_pipe[DELAY-1] ? (panel_pipe[DELAY-1] ? styled : plain_pipe[DELAY-2]) : 48'd0) : bg[DELAY-1][47:0];
// Memory ports have no reset, so Efinity can infer true dual-clock block RAM.
always @(posedge video_clk)begin
 word0_q<=line0[word_index];word1_q<=line1[word_index];
 word2_q<=line2[word_index];word3_q<=line3[word_index];
 grey_q[0]<=grey0[grey_index];grey_q[1]<=grey1[grey_index];grey_q[2]<=grey2[grey_index];
 grey_q[3]<=grey3[grey_index];grey_q[4]<=grey4[grey_index];grey_q[5]<=grey5[grey_index];
end
always @(posedge video_clk or negedge rst_n)begin
 if(!rst_n)begin
  commit_sync<=0;commit_ack<=0;active_pair<=0;have_frame<=0;
  visibility_sync<=0;visibility_ack<=0;mode_live<=ENABLE_VISIBILITY ? 2 : 0;
  vs_d<=0;de_d<=0;x<=0;y<=0;req_toggle<=0;req_pair<=0;req_row<=0;
  ready0_sync<=0;ready1_sync<=0;ready2_sync<=0;ready3_sync<=0;ready4_sync<=0;ready5_sync<=0;video_tag4<=0;video_tag5<=0;video_tag0<=0;video_tag1<=0;video_tag2<=0;video_tag3<=0;video_underflows<=0;
  word_bank_q<=0;word_half_q<=0;line_good<=0;first_right_q<=0;last_right_q<=0;right_q<=0;stencil_banks<=0;stencil_banks_q<=0;
  for(stage=0;stage<DELAY;stage=stage+1)bg[stage]<=0;
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
   x<=0;y<=0;
   if(ENABLE_VISIBILITY && visibility_sync[2]!=visibility_ack)begin mode_live<=visibility_mode;visibility_ack<=visibility_sync[2];end
   if(commit_sync[2]!=commit_ack)begin
    active_pair<=commit_pair;have_frame<=1;commit_ack<=commit_sync[2];
   end
  end else if(i_de)begin
   x<=x+1'b1;
   if(line_start)begin
    line_good<=row_ready;
    if(have_frame && panel_row && !row_ready)video_underflows<=video_underflows+1'b1;
    if(have_frame && y>=297 && y<777)begin
     req_row<=y-11'd297;req_pair<=active_pair;req_toggle<=~req_toggle;
    end
   end
  end else begin
   x<=0;
   if(de_d)y<=y+1'b1;
  end
  // Modulo-six row+3 occupies row-3, preserving both previous stencil rows.
  if(i_de && x==560)stencil_banks<=ready_banks;
  stencil_banks_q<=i_de && x==560 ? ready_banks : stencil_banks;
  word_bank_q<=current_row[1:0];word_half_q<=x[0];
  first_right_q<=x==560;last_right_q<=x==879;right_q<=i_de && panel_row && panel_right;
  plain_pipe[0]<={plain_pair[7:0]^8'h80,plain_pair[15:8]^8'h80,plain_pair[23:16]^8'h80,
             plain_pair[39:32]^8'h80,plain_pair[47:40]^8'h80,plain_pair[55:48]^8'h80};
  for(stage=1;stage<DELAY-1;stage=stage+1)plain_pipe[stage]<=plain_pipe[stage-1];
  bg[0]<={i_hs,i_vs,i_de,i_rgb};for(stage=1;stage<DELAY;stage=stage+1)bg[stage]<=bg[stage-1];
  inside_pipe<={inside_pipe[DELAY-2:0],i_de && have_frame && panel_row && (panel_left || panel_right)};
  good_pipe<={good_pipe[DELAY-2:0],line_good};panel_pipe<={panel_pipe[DELAY-2:0],panel_right};
 end
end
reg [2:0] req_sync;
reg pending,pending_pair;
reg [8:0] pending_row;
localparam IDLE=0,ADDR=1,DATA=2,PLAN=3;
reg [1:0] state;
reg [8:0] row,word_count;
reg pair_q,bad;
reg [7:0] remaining;
wire request_edge=req_sync[2]!=req_sync[1];
wire [31:0] input_base=pair_q ? 32'h03200000 : 32'h03000000;
wire [31:0] output_base=pair_q ? 32'h03600000 : 32'h03400000;
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
always @(posedge clk)begin
 if(rvalid && rready && rresp==0)begin
  case(row[1:0])
   0:line0[word_count]<=rdata;1:line1[word_count]<=rdata;
   2:line2[word_count]<=rdata;3:line3[word_count]<=rdata;
  endcase
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
  req_sync<=0;pending<=0;pending_row<=0;pending_pair<=0;
  row<=0;pair_q<=0;word_count<=0;state<=IDLE;bad<=0;remaining<=0;
  araddr<=0;arlen<=0;tag0<=0;tag1<=0;tag2<=0;tag3<=0;tag4<=0;tag5<=0;ready_toggle<=0;
  read_errors<=0;underflows<=0;uf_sync1<=0;uf_sync2<=0;
 end else begin
  req_sync<={req_sync[1:0],req_toggle};
  uf_sync1<=underflow_gray;uf_sync2<=uf_sync1;
  underflows[31]<=uf_sync2[31];
  for(k=30;k>=0;k=k-1)underflows[k]<=^(uf_sync2>>k);
  if(request_edge)begin pending<=1;pending_row<=req_row;pending_pair<=req_pair;end
  case(state)
   IDLE:if(pending)begin
    row<=pending_row;pair_q<=pending_pair;word_count<=0;bad<=0;
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
      read_errors<=read_errors+1'b1;state<=IDLE;
     end else if(word_count==319)begin
      case(refill_bank)
       0:begin tag0<={1'b1,pair_q,row};ready_toggle[0]<=~ready_toggle[0];end
       1:begin tag1<={1'b1,pair_q,row};ready_toggle[1]<=~ready_toggle[1];end
       2:begin tag2<={1'b1,pair_q,row};ready_toggle[2]<=~ready_toggle[2];end
       3:begin tag3<={1'b1,pair_q,row};ready_toggle[3]<=~ready_toggle[3];end
       4:begin tag4<={1'b1,pair_q,row};ready_toggle[4]<=~ready_toggle[4];end
       5:begin tag5<={1'b1,pair_q,row};ready_toggle[5]<=~ready_toggle[5];end
      endcase
      state<=IDLE;
     end else state<=PLAN;
    end
   end
  endcase
 end
end
endmodule
