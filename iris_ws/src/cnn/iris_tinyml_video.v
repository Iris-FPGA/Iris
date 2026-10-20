// Full 1920x1080 RGB -> model-native 128x128 INT8 NHWC, tightly packed C3.
// Point sample src_x=15*dst_x, src_y=floor(135*dst_y/16).
// HDMI expands to the original rectangular geometry after inference.
module iris_tinyml_preprocess(
 input wire clk,rst_n,enable,i_vs,i_de,input wire [47:0] i_rgb,
 output reg o_valid,o_sof,o_eof,output reg [31:0] o_word
);
reg vs_d,de_d,active;
reg [10:0] x,y,next_x,next_y;
reg [6:0] sx,sy;
reg [3:0] phase_y;
reg [1:0] bytes_held;
reg [23:0] held;
reg first_word;
wire frame_start=i_vs && !vs_d;
wire selected=active && enable && i_de && y==next_y &&
              x<=next_x && x+11'd1>=next_x;
wire [23:0] rgb=next_x[0] ? i_rgb[23:0] : i_rgb[47:24];
wire [23:0] rgb_bytes={rgb[7:0]^8'h80,rgb[15:8]^8'h80,rgb[23:16]^8'h80};
wire [55:0] joined={32'd0,held} | ({32'd0,rgb_bytes} << (bytes_held*8));
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  vs_d<=0;de_d<=0;active<=0;x<=0;y<=0;next_x<=0;next_y<=0;sx<=0;sy<=0;phase_y<=0;
  bytes_held<=0;held<=0;first_word<=1;o_valid<=0;o_sof<=0;o_eof<=0;o_word<=0;
 end else begin
  vs_d<=i_vs;de_d<=i_de;o_valid<=0;o_sof<=0;o_eof<=0;
  if(frame_start || !enable)begin
   active<=frame_start && enable;x<=0;y<=0;next_x<=0;next_y<=0;sx<=0;sy<=0;phase_y<=0;
   bytes_held<=0;held<=0;first_word<=1;
  end else begin
   if(i_de)x<=x+2'd2;
   else if(de_d)begin
    x<=0;y<=y+1'b1;next_x<=0;sx<=0;
    if(y==next_y)begin
     next_y<=next_y+(phase_y>=9 ? 11'd9 : 11'd8);
     phase_y<=phase_y+4'd7;sy<=sy+1'b1;
    end
   end
   if(selected)begin
    if(bytes_held!=0)begin
     o_word<=joined[31:0];o_valid<=1;o_sof<=first_word;first_word<=0;
     o_eof<=sx==127 && sy==127;
     bytes_held<=bytes_held-1'b1;held<=joined[55:32];
    end else begin held<=rgb_bytes;bytes_held<=3;end
    sx<=sx+1'b1;next_x<=next_x+11'd15;
    if(sx==127 && sy==127)active<=0;
   end
  end
 end
end
endmodule

// Left 960x1080: live camera. Right 960x1080: latest complete neural result.
// The model uses 128 square samples of the full rectangular camera raster.
// Two line banks cache only the visible right half (64 RGB model pixels).
// Adjacent pixel pairs allow exact 15x horizontal expansion at two pixels/clk.
module iris_tinyml_panels(
 input wire clk,video_clk,rst_n,commit_toggle,input wire [1:0] commit_pair,
 output reg commit_ack,have_frame,output reg [1:0] active_pair,
 input wire i_hs,i_vs,i_de,input wire [47:0] i_rgb,
 output wire o_hs,o_vs,o_de,output wire [47:0] o_rgb,
 output reg [31:0] underflows,read_errors,
 output reg [31:0] araddr,output wire [7:0] arlen,
 output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready
);
reg [47:0] line0[0:63],line1[0:63];
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
reg [1:0] request_pair;
reg [9:0] tag0,tag1;
reg [1:0] ready_toggle;
reg [2:0] ready0_sync,ready1_sync;
reg [9:0] video_tag0,video_tag1;
wire row_good=(model_row[0] ? video_tag1 : video_tag0)=={1'b1,active_pair,model_row};
reg bank_q,second_q;
wire [47:0] pixels=bank_q ? pixel1 : pixel0;
wire [23:0] styled0,styled1;
iris_style_dequant #(.SCALE_Q24(26'd38309724),.ZERO_POINT(-89)) u_dequant0(
 .clk(video_clk),.rst_n(rst_n),.i_valid(1'b1),.i_rgba({8'd0,pixels[23:0]}),.o_valid(),.o_rgb(styled0));
iris_style_dequant #(.SCALE_Q24(26'd38309724),.ZERO_POINT(-89)) u_dequant1(
 .clk(video_clk),.rst_n(rst_n),.i_valid(1'b1),.i_rgba({8'd0,second_q ? pixels[47:24] : pixels[23:0]}),.o_valid(),.o_rgb(styled1));
reg [2:0] hs_pipe,vs_pipe,de_pipe,good_pipe,right_pipe,have_pipe;
reg [47:0] camera0,camera1,camera2;
assign o_hs=hs_pipe[2];assign o_vs=vs_pipe[2];assign o_de=de_pipe[2];
assign o_rgb=!have_pipe[2] || !right_pipe[2] ? camera2 :
             good_pipe[2] ? {styled0,styled1} : 48'd0;
always @(posedge video_clk)begin
 pixel0<=line0[model_column[5:0]];pixel1<=line1[model_column[5:0]];
end
reg [31:0] video_underflows;
always @(posedge video_clk or negedge rst_n)begin
 if(!rst_n)begin
  commit_sync<=0;commit_ack<=0;have_frame<=0;active_pair<=0;
  vs_d<=0;de_d<=0;x<=0;model_row<=0;model_column<=0;phase_x<=0;phase_y<=0;last_requested<=127;
  request_toggle<=0;request_row<=0;request_pair<=0;
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
   if(have_frame || commit_sync[2]!=commit_ack)begin
    request_row<=0;request_pair<=commit_sync[2]!=commit_ack ? commit_pair : active_pair;
    request_toggle<=~request_toggle;
   end
   if(commit_sync[2]!=commit_ack)begin active_pair<=commit_pair;have_frame<=1;commit_ack<=commit_sync[2];end
  end else if(i_de)begin
   x<=x+1'b1;
   if(phase_x>=13)begin phase_x<=phase_x-4'd13;model_column<=model_column+1'b1;end
   else phase_x<=phase_x+2'd2;
   if(x==480 && have_frame && !row_good)video_underflows<=video_underflows+1'b1;
  end else if(de_d)begin
   x<=0;model_column<=0;phase_x<=0;
   if(phase_y>=119)begin phase_y<=phase_y-8'd119;model_row<=model_row+1'b1;end
   else phase_y<=phase_y+8'd16;
   if(have_frame && model_row<127 && last_requested!=model_row)begin
    request_row<=model_row+1'b1;request_pair<=active_pair;request_toggle<=~request_toggle;last_requested<=model_row;
   end
  end
  bank_q<=model_row[0];second_q<=phase_x==14;
  hs_pipe<={hs_pipe[1:0],i_hs};vs_pipe<={vs_pipe[1:0],i_vs};de_pipe<={de_pipe[1:0],i_de};
  good_pipe<={good_pipe[1:0],row_good};right_pipe<={right_pipe[1:0],x>=480};have_pipe<={have_pipe[1:0],have_frame};
  camera0<=i_rgb;camera1<=camera0;camera2<=camera1;
 end
end
localparam IDLE=0,ADDR=1,DATA=2,UNPACK=3,FINISH=4;
reg [2:0] state;
reg [2:0] request_sync;
reg pending,read_bad;
reg [6:0] pending_row,row;
reg [1:0] pending_pair,pair;
reg [3:0] beat;
reg [6:0] column;
reg [4:0] byte_count;
reg [143:0] reservoir;
reg [23:0] previous_pixel;
wire request_edge=request_sync[2]!=request_sync[1];
assign arlen=0;assign arvalid=state==ADDR;assign rready=state==DATA;
wire write_pixel=(state==UNPACK && byte_count>=3 && column!=0) || state==FINISH;
wire [5:0] write_column=state==FINISH ? 6'd63 : column[5:0]-1'b1;
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
  state<=IDLE;request_sync<=0;pending<=0;read_bad<=0;pending_row<=0;pending_pair<=0;pair<=0;
  row<=0;beat<=0;column<=0;byte_count<=0;reservoir<=0;previous_pixel<=0;
  araddr<=0;tag0<=0;tag1<=0;ready_toggle<=0;read_errors<=0;underflows<=0;uf_sync1<=0;uf_sync2<=0;
 end else begin
  request_sync<={request_sync[1:0],request_toggle};
  if(request_edge)begin pending<=1;pending_row<=request_row;pending_pair<=request_pair;end
  uf_sync1<=underflow_gray;uf_sync2<=uf_sync1;
  for(k=31;k>=0;k=k-1)underflows[k]<=^(uf_sync2>>k);
  case(state)
   IDLE:if(pending)begin
    row<=pending_row;pair<=pending_pair;pending<=request_edge;read_bad<=0;
    if(pending_row[0])begin tag1<=0;ready_toggle[1]<=~ready_toggle[1];end
    else begin tag0<=0;ready_toggle[0]<=~ready_toggle[0];end
    beat<=0;column<=0;byte_count<=0;reservoir<=0;
    araddr<=(pending_pair==2 ? 32'h03a00000 : pending_pair==1 ? 32'h03600000 : 32'h03400000)+
            ({25'd0,pending_row}<<8)+({25'd0,pending_row}<<7)+32'd192;
    state<=ADDR;
   end
   ADDR:if(arready)state<=DATA;
   DATA:if(rvalid)begin
    if(rresp!=0 || !rlast || read_bad)begin
     read_bad<=1;
     if(rlast)begin read_errors<=read_errors+1'b1;state<=IDLE;end
    end else begin
     case(byte_count)
      0:reservoir<={16'd0,rdata};
      1:reservoir<={8'd0,rdata,reservoir[7:0]};
      2:reservoir<={rdata,reservoir[15:0]};
      default:reservoir<=0;
     endcase
     byte_count<=byte_count+5'd16;state<=UNPACK;
    end
   end
   UNPACK:if(byte_count>=3)begin
    previous_pixel<=reservoir[23:0];reservoir<=reservoir>>24;byte_count<=byte_count-2'd3;column<=column+1'b1;
   end else if(beat==11)begin
    if(column==64 && byte_count==0)state<=FINISH;
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
