// 1920x1080 RGB at two pixels/clock -> INT8 NHWC 640x480x4.
// Center crop 1440x1080 to preserve the model's 4:3 aspect ratio, then
// src = floor(dst * 9 / 4). Default is the original point sampler.
// Camera denoising is upstream at native resolution, before colour correction.
// Previous experimental filters remain opt-in for regression comparisons.
// Input RGB is after display color correction and before any OSD.
// This tap cannot backpressure video; its consumer must abort a frame on
// overflow and only publish a complete, committed frame to the CPU.
module iris_style_preprocess #(parameter ENABLE_GAUSSIAN=0,parameter ENABLE_MEDIAN=0,parameter ENABLE_SMOOTH=0,parameter HEIGHT=720)(
    input wire clk, input wire rst_n, input wire enable,
    input wire i_vs, input wire i_de, input wire [47:0] i_rgb,
    output wire o_valid, output wire [31:0] o_rgba,
    output wire o_dual, output wire [31:0] o_rgba_b,
    output wire o_sof, output wire o_eol, output wire o_eof,
    output wire [9:0] o_x, output wire [8:0] o_y
);
generate if(ENABLE_MEDIAN)begin : g_median
    assign o_dual=1'b0;assign o_rgba_b=32'd0;
    wire valid,sof,eol,eof;
    wire [31:0] rgba;
    wire [9:0] x;
    wire [8:0] y;
    wire median_valid,median_sof,median_eol,median_eof;
    wire [31:0] median_rgba;
    wire [9:0] median_x;
    wire [8:0] median_y;
    iris_style_point_preprocess #(.HEIGHT(480)) u_sample(
        .clk(clk),.rst_n(rst_n),.enable(enable),.i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
        .o_valid(valid),.o_rgba(rgba),.o_dual(),.o_rgba_b(),.o_sof(sof),.o_eol(eol),.o_eof(eof),.o_x(x),.o_y(y));
    iris_style_window_filter u_filter(
        .clk(clk),.rst_n(rst_n),.clear(!enable || i_vs),
        .i_valid(valid),.i_rgba(rgba),.i_x(x),.i_y(y),.i_eof(eof),
        .o_valid(median_valid),.o_rgba(median_rgba),.o_sof(median_sof),.o_eol(median_eol),.o_eof(median_eof),.o_x(median_x),.o_y(median_y));
    if(ENABLE_SMOOTH)begin : g_smooth
        wire smooth_valid,smooth_sof,smooth_eol,smooth_eof;
        wire [31:0] smooth_rgba;
        wire [9:0] smooth_x;
        wire [8:0] smooth_y;
        iris_style_window_filter #(.MEDIAN(0)) u_smooth0(
            .clk(clk),.rst_n(rst_n),.clear(!enable || i_vs),
            .i_valid(median_valid),.i_rgba(median_rgba),.i_x(median_x),.i_y(median_y),.i_eof(median_eof),
            .o_valid(smooth_valid),.o_rgba(smooth_rgba),.o_sof(smooth_sof),.o_eol(smooth_eol),.o_eof(smooth_eof),.o_x(smooth_x),.o_y(smooth_y));
        iris_style_window_filter #(.MEDIAN(0)) u_smooth1(
            .clk(clk),.rst_n(rst_n),.clear(!enable || i_vs),
            .i_valid(smooth_valid),.i_rgba(smooth_rgba),.i_x(smooth_x),.i_y(smooth_y),.i_eof(smooth_eof),
            .o_valid(o_valid),.o_rgba(o_rgba),.o_sof(o_sof),.o_eol(o_eol),.o_eof(o_eof),.o_x(o_x),.o_y(o_y));
    end else begin : g_median_only
        assign o_valid=median_valid;assign o_rgba=median_rgba;
        assign o_sof=median_sof;assign o_eol=median_eol;assign o_eof=median_eof;
        assign o_x=median_x;assign o_y=median_y;
    end
end else if(ENABLE_GAUSSIAN)begin : g_gaussian
    assign o_dual=1'b0;assign o_rgba_b=32'd0;
    iris_style_gaussian_preprocess u_filter(
        .clk(clk),.rst_n(rst_n),.enable(enable),.i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
        .o_valid(o_valid),.o_rgba(o_rgba),.o_sof(o_sof),.o_eol(o_eol),.o_eof(o_eof),.o_x(o_x),.o_y(o_y));
end else begin : g_point
    iris_style_point_preprocess #(.HEIGHT(HEIGHT)) u_point(.*);
end endgenerate
endmodule

// Separable [1 2 1] x [1 2 1] / 16, rounded only after both axes.
// Keep all ten bits of each horizontal RGB sum. Alternate row banks are
// read before overwrite, giving row y-2 and y-1 alongside incoming row y.
// Row zero is replicated at the top. The final sampled centre is row 1077,
// so its bottom neighbour (1078) is available without a blanking-time flush.
module iris_style_gaussian_preprocess (
    input wire clk, input wire rst_n, input wire enable,
    input wire i_vs, input wire i_de, input wire [47:0] i_rgb,
    output reg o_valid, output reg [31:0] o_rgba,
    output reg o_sof, output reg o_eol, output reg o_eof,
    output reg [9:0] o_x, output reg [8:0] o_y
);
reg vs_d,de_d,frame_active;
reg [11:0] src_x,src_y,next_x,next_y;
reg [1:0] phase_x,phase_y;
reg [9:0] dst_x;
reg [8:0] dst_y;
reg [47:0] previous_pair;
reg [23:0] previous_left;
wire frame_start=i_vs && !vs_d;
// Wait one pair for the right neighbour of an odd source column.
wire first_selected=src_x==next_x+12'd2;
wire second_selected=src_x==next_x+12'd1;
wire sample=enable && frame_active && !frame_start && i_de &&
            src_x>=2 && dst_x<640 && (first_selected || second_selected);
wire [23:0] left_rgb=first_selected ? previous_left : previous_pair[47:24];
wire [23:0] centre_rgb=first_selected ? previous_pair[47:24] : previous_pair[23:0];
wire [23:0] right_rgb=first_selected ? previous_pair[23:0] : i_rgb[47:24];
function [9:0] horizontal;
    input [7:0] a,b,c;
    begin horizontal={2'b0,a}+{1'b0,b,1'b0}+{2'b0,c};end
endfunction
wire [29:0] horizontal_rgb={horizontal(left_rgb[23:16],centre_rgb[23:16],right_rgb[23:16]),
                           horizontal(left_rgb[15:8],centre_rgb[15:8],right_rgb[15:8]),
                           horizontal(left_rgb[7:0],centre_rgb[7:0],right_rgb[7:0])};
(* syn_ramstyle = "block_ram" *) reg [29:0] even_row[0:639],odd_row[0:639];
reg [29:0] even_q,odd_q,horizontal_q;
reg sample_q,emit_q,parity_q,top_q;
reg [9:0] x_q;
reg [8:0] y_q;
// Unreset synchronous RAM ports permit block RAM inference. Every used
// column is overwritten in row zero before any output from a new frame.
always @(posedge clk)begin
    if(sample)begin
        even_q<=even_row[dst_x];odd_q<=odd_row[dst_x];
    end
    if(sample_q && enable && !frame_start)begin
        if(parity_q)odd_row[x_q]<=horizontal_q;
        else even_row[x_q]<=horizontal_q;
    end
end
wire [29:0] middle_rgb=parity_q ? even_q : odd_q;
wire [29:0] top_rgb=top_q ? middle_rgb : parity_q ? odd_q : even_q;
function [7:0] vertical;
    input [9:0] a,b,c;
    reg [11:0] sum;
    begin sum={2'b0,a}+{1'b0,b,1'b0}+{2'b0,c}+12'd8;vertical=sum[11:4];end
endfunction
wire [23:0] filtered_rgb={vertical(top_rgb[29:20],middle_rgb[29:20],horizontal_q[29:20]),
                         vertical(top_rgb[19:10],middle_rgb[19:10],horizontal_q[19:10]),
                         vertical(top_rgb[9:0],middle_rgb[9:0],horizontal_q[9:0])};
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        vs_d<=0;de_d<=0;frame_active<=0;src_x<=0;src_y<=0;
        next_x<=240;next_y<=0;phase_x<=0;phase_y<=0;dst_x<=0;dst_y<=0;
        previous_pair<=0;previous_left<=0;
        sample_q<=0;emit_q<=0;parity_q<=0;top_q<=0;horizontal_q<=0;x_q<=0;y_q<=0;
        o_valid<=0;o_rgba<=0;o_sof<=0;o_eol<=0;o_eof<=0;o_x<=0;o_y<=0;
    end else begin
        vs_d<=i_vs;de_d<=i_de;
        o_valid<=0;o_sof<=0;o_eol<=0;o_eof<=0;
        sample_q<=sample;
        if(sample)begin
            horizontal_q<=horizontal_rgb;parity_q<=src_y[0];top_q<=src_y==1;
            emit_q<=src_y==next_y+12'd1 && dst_y<480;
            x_q<=dst_x;y_q<=dst_y;
        end
        if(sample_q && emit_q && enable && !frame_start)begin
            o_valid<=1;
            o_rgba<={8'h80,filtered_rgb[7:0]^8'h80,filtered_rgb[15:8]^8'h80,filtered_rgb[23:16]^8'h80};
            o_x<=x_q;o_y<=y_q;
            o_sof<=x_q==0 && y_q==0;o_eol<=x_q==639;o_eof<=x_q==639 && y_q==479;
        end
        if(frame_start || !enable)begin
            frame_active<=frame_start && enable;
            src_x<=0;src_y<=0;next_x<=240;next_y<=0;
            phase_x<=0;phase_y<=0;dst_x<=0;dst_y<=0;
            sample_q<=0;emit_q<=0;
        end else if(i_de && frame_active)begin
            src_x<=src_x+12'd2;
            previous_pair<=i_rgb;previous_left<=previous_pair[23:0];
            if(sample)begin
                dst_x<=dst_x+10'd1;
                next_x<=next_x+(phase_x==3 ? 12'd3 : 12'd2);phase_x<=phase_x+2'd1;
            end
        end else begin
            src_x<=0;next_x<=240;dst_x<=0;phase_x<=0;
            if(de_d && frame_active)begin
                src_y<=src_y+12'd1;
                if(src_y==next_y+12'd1 && dst_y<480)begin
                    dst_y<=dst_y+9'd1;
                    next_y<=next_y+(phase_y==3 ? 12'd3 : 12'd2);phase_y<=phase_y+2'd1;
                end
            end
        end
    end
end
endmodule

// Optional point-sampled reference/bypass for comparing denoising quality.
module iris_style_point_preprocess #(parameter HEIGHT=720)(
    input wire clk, input wire rst_n, input wire enable,
    input wire i_vs, input wire i_de, input wire [47:0] i_rgb,
    output reg o_valid, output reg [31:0] o_rgba,
    output reg o_dual, output reg [31:0] o_rgba_b,
    output reg o_sof, output reg o_eol, output reg o_eof,
    output reg [9:0] o_x, output reg [8:0] o_y
);
reg vs_d, de_d, frame_active;
reg [11:0] src_x, src_y, next_x, next_y;
reg [1:0] phase_x, phase_y;
reg [9:0] dst_x, dst_y;
wire frame_start = i_vs && !vs_d;
wire row_selected = HEIGHT == 720 ? (phase_y != 2'd2 && dst_y < 10'd720) : (src_y == next_y && dst_y < 10'd480);
wire first_selected = src_x == next_x;
wire second_selected = src_x + 12'd1 == next_x;
wire [23:0] selected_rgb = HEIGHT == 720 ? (phase_x == 2'd1 ? i_rgb[23:0] : i_rgb[47:24]) :
                           (first_selected ? i_rgb[47:24] : i_rgb[23:0]);
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d <= 0; de_d <= 0; frame_active <= 0; src_x <= 0; src_y <= 0;
        next_x <= 0; next_y <= 0; phase_x <= 0; phase_y <= 0;
        dst_x <= 0; dst_y <= 0;
        o_valid <= 0; o_rgba <= 0; o_dual <= 0; o_rgba_b <= 0;
        o_sof <= 0; o_eol <= 0; o_eof <= 0;
        o_x <= 0; o_y <= 0;
    end else begin
        vs_d <= i_vs; de_d <= i_de;
        o_valid <= 0; o_dual <= 0; o_sof <= 0; o_eol <= 0; o_eof <= 0;
        if (i_vs || !enable) begin
            frame_active <= i_vs && enable;
            src_x <= 0; src_y <= 0; next_x <= 0; next_y <= 0;
            dst_x <= 0; dst_y <= 0; phase_x <= 0; phase_y <= 0;
        end else if (i_de && frame_active) begin
            src_x <= src_x + 12'd2;
            if (HEIGHT == 720) begin
                if (row_selected && src_x >= 12'd960 && dst_x < 10'd640) begin
                    o_valid <= 1'b1;
                    o_dual <= phase_x == 2'd0;
                    o_rgba <= {8'h80, selected_rgb[7:0] ^ 8'h80,
                                      selected_rgb[15:8] ^ 8'h80,
                                      selected_rgb[23:16] ^ 8'h80};
                    o_rgba_b <= {8'h80, i_rgb[7:0] ^ 8'h80,
                                        i_rgb[15:8] ^ 8'h80,
                                        i_rgb[23:16] ^ 8'h80};
                    o_x <= dst_x; o_y <= dst_y[8:0];
                    o_sof <= dst_x == 10'd0 && dst_y == 10'd0;
                    o_eol <= dst_x == 10'd639;
                    o_eof <= dst_x == 10'd639 && dst_y == 10'd719;
                    dst_x <= dst_x + (phase_x == 2'd0 ? 10'd2 : 10'd1);
                    phase_x <= phase_x == 2'd2 ? 2'd0 : (phase_x + 2'd1);
                end
            end else if (row_selected && dst_x < 640 && (first_selected || second_selected)) begin
                o_valid <= 1;
                // Lowest address byte is R; dummy channel's uint8 value is 0.
                o_rgba <= {8'h80, selected_rgb[7:0] ^ 8'h80,
                                  selected_rgb[15:8] ^ 8'h80,
                                  selected_rgb[23:16] ^ 8'h80};
                o_x <= dst_x; o_y <= dst_y[8:0];
                o_sof <= dst_x == 0 && dst_y == 0;
                o_eol <= dst_x == 639;
                o_eof <= dst_x == 639 && dst_y == 479;
                dst_x <= dst_x + 10'd1;
                next_x <= next_x + 12'd3;
                phase_x <= phase_x + 2'd1;
            end
        end else begin
            src_x <= 0; next_x <= 0; dst_x <= 0; phase_x <= 0;
            if (de_d) begin
                src_y <= src_y + 12'd1;
                if (HEIGHT == 720) begin
                    phase_y <= phase_y == 2'd2 ? 2'd0 : (phase_y + 2'd1);
                    if (row_selected) dst_y <= dst_y + 10'd1;
                end else if (row_selected) begin
                    dst_y <= dst_y + 10'd1;
                    next_y <= next_y + (phase_y == 3 ? 12'd3 : 12'd2);
                    phase_y <= phase_y + 2'd1;
                end
            end
        end
    end
end
endmodule

// True per-channel median of the nine neighbouring tensor pixels. Sorting
// rows, then taking median(max(row minima), median(row medians), min(row maxima))
// is an exact median9 network. Three registered compare stages keep 74.375MHz.
// The last source row is replayed in blanking to replicate the bottom border;
// right borders use one extra column cycle. A fresh VS or disable discards
// every pending pixel, including an interrupted bottom replay.
// MEDIAN=0 reuses the same window and latency for Gaussian3. Each 2D
// [1 2 1] outer-product sum is rounded once, after division by sixteen.
module iris_style_window_filter #(parameter MEDIAN=1)(
 input wire clk,rst_n,clear,i_valid,i_eof,
 input wire [31:0] i_rgba,input wire [9:0] i_x,input wire [8:0] i_y,
 output reg o_valid,output reg [31:0] o_rgba,
 output reg o_sof,o_eol,o_eof,output reg [9:0] o_x,output reg [8:0] o_y
);
(* syn_ramstyle="block_ram" *) reg [23:0] even_row[0:639],odd_row[0:639];
reg [23:0] even_q,odd_q,current_q;
reg bottom_replay;
reg [9:0] replay_x;
wire sample=i_valid || bottom_replay;
wire [9:0] sample_x=bottom_replay ? replay_x : i_x;
wire [9:0] sample_y=bottom_replay ? 10'd480 : {1'b0,i_y};
reg sample_q,bottom_q;
reg [9:0] x_q,y_q;
always @(posedge clk)begin
 if(sample && !clear)begin
  even_q<=even_row[sample_x];odd_q<=odd_row[sample_x];
  if(i_valid && !bottom_replay)begin
   if(i_y[0])odd_row[i_x]<=i_rgba[23:0]^24'h808080;
   else even_row[i_x]<=i_rgba[23:0]^24'h808080;
  end
 end
end
wire [23:0] middle=y_q[0] ? even_q : odd_q;
wire [23:0] top=y_q==1 ? middle : y_q[0] ? odd_q : even_q;
wire [23:0] bottom=bottom_q ? middle : current_q;
wire [71:0] column={bottom,middle,top};
reg [71:0] left_column,centre_column;
reg right_pending;
reg [8:0] right_y;
wire feed=right_pending || (sample_q && y_q>=1 && x_q>=1);
wire [71:0] right_column=right_pending ? centre_column : column;
wire [9:0] feed_x=right_pending ? 10'd639 : x_q-10'd1;
wire [8:0] feed_y=right_pending ? right_y : y_q-10'd1;
function [23:0] sort3;
 input [7:0] a,b,c;
 reg [7:0] lo,mid,hi,t;
 begin
  lo=a;mid=b;hi=c;
  if(lo>mid)begin t=lo;lo=mid;mid=t;end
  if(mid>hi)begin t=mid;mid=hi;hi=t;end
  if(lo>mid)begin t=lo;lo=mid;mid=t;end
  sort3={hi,mid,lo};
 end
endfunction
function [7:0] min3;
 input [7:0] a,b,c;
 reg [7:0] v;
 begin v=a<b ? a : b;min3=v<c ? v : c;end
endfunction
function [7:0] max3;
 input [7:0] a,b,c;
 reg [7:0] v;
 begin v=a>b ? a : b;max3=v>c ? v : c;end
endfunction
function [7:0] median3;
 input [7:0] a,b,c;
 reg [23:0] sorted;
 begin sorted=sort3(a,b,c);median3=sorted[15:8];end
endfunction
reg [71:0] sorted_top,sorted_middle,sorted_bottom,candidates;
reg [29:0] smooth_top,smooth_middle,smooth_bottom;
reg [35:0] smooth_sum;
function [9:0] smooth3;
 input [7:0] a,b,c;
 begin smooth3={2'b0,a}+{1'b0,b,1'b0}+{2'b0,c};end
endfunction
reg v0,v1;
reg [9:0] x0,x1;
reg [8:0] y0,y1;
integer ch;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  bottom_replay<=0;replay_x<=0;sample_q<=0;bottom_q<=0;
  current_q<=0;x_q<=0;y_q<=0;left_column<=0;centre_column<=0;
  right_pending<=0;right_y<=0;v0<=0;v1<=0;x0<=0;x1<=0;y0<=0;y1<=0;
  sorted_top<=0;sorted_middle<=0;sorted_bottom<=0;candidates<=0;
  smooth_top<=0;smooth_middle<=0;smooth_bottom<=0;smooth_sum<=0;
  o_valid<=0;o_rgba<=0;o_sof<=0;o_eol<=0;o_eof<=0;o_x<=0;o_y<=0;
 end else if(clear)begin
  bottom_replay<=0;replay_x<=0;sample_q<=0;right_pending<=0;
  v0<=0;v1<=0;o_valid<=0;o_sof<=0;o_eol<=0;o_eof<=0;
 end else begin
  sample_q<=sample;bottom_q<=bottom_replay;
  if(sample)begin x_q<=sample_x;y_q<=sample_y;current_q<=i_rgba[23:0]^24'h808080;end
  if(i_valid && i_eof)begin bottom_replay<=1;replay_x<=0;end
  else if(bottom_replay)begin
   if(replay_x==639)bottom_replay<=0;
   else replay_x<=replay_x+10'd1;
  end
  right_pending<=sample_q && y_q>=1 && x_q==639;
  if(sample_q && y_q>=1)begin
   if(x_q==0)begin left_column<=column;centre_column<=column;end
   else begin left_column<=centre_column;centre_column<=column;end
   right_y<=y_q-10'd1;
  end
  v0<=feed;x0<=feed_x;y0<=feed_y;
  v1<=v0;x1<=x0;y1<=y0;
  for(ch=0;ch<3;ch=ch+1)begin
   if(MEDIAN)begin
   if(feed)begin
   sorted_top[ch*24+:24]<=sort3(left_column[ch*8+:8],centre_column[ch*8+:8],right_column[ch*8+:8]);
   sorted_middle[ch*24+:24]<=sort3(left_column[24+ch*8+:8],centre_column[24+ch*8+:8],right_column[24+ch*8+:8]);
   sorted_bottom[ch*24+:24]<=sort3(left_column[48+ch*8+:8],centre_column[48+ch*8+:8],right_column[48+ch*8+:8]);
   end
   if(v0)candidates[ch*24+:24]<={min3(sorted_top[ch*24+16+:8],sorted_middle[ch*24+16+:8],sorted_bottom[ch*24+16+:8]),
      median3(sorted_top[ch*24+8+:8],sorted_middle[ch*24+8+:8],sorted_bottom[ch*24+8+:8]),
      max3(sorted_top[ch*24+:8],sorted_middle[ch*24+:8],sorted_bottom[ch*24+:8])};
   if(v1)o_rgba[ch*8+:8]<=median3(candidates[ch*24+:8],candidates[ch*24+8+:8],candidates[ch*24+16+:8])^8'h80;
   end else begin
    if(feed)begin
     smooth_top[ch*10+:10]<=smooth3(left_column[ch*8+:8],centre_column[ch*8+:8],right_column[ch*8+:8]);
     smooth_middle[ch*10+:10]<=smooth3(left_column[24+ch*8+:8],centre_column[24+ch*8+:8],right_column[24+ch*8+:8]);
     smooth_bottom[ch*10+:10]<=smooth3(left_column[48+ch*8+:8],centre_column[48+ch*8+:8],right_column[48+ch*8+:8]);
    end
    if(v0)smooth_sum[ch*12+:12]<={2'b0,smooth_top[ch*10+:10]}+{1'b0,smooth_middle[ch*10+:10],1'b0}+{2'b0,smooth_bottom[ch*10+:10]}+12'd8;
    if(v1)o_rgba[ch*8+:8]<=smooth_sum[ch*12+4+:8]^8'h80;
   end
  end
  o_rgba[31:24]<=8'h80;o_valid<=v1;o_x<=x1;o_y<=y1;
  o_sof<=v1 && x1==0 && y1==0;o_eol<=v1 && x1==639;o_eof<=v1 && x1==639 && y1==479;
 end
end
endmodule
