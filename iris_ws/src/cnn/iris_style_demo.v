// APB0 control plane for paired camera/style presentation.
// Three DDR input/output pairs. Capture, inference and VS-pending display
// retain independent bank leases; config writes never change an active lease.
module iris_style_demo #(parameter [24:0] SCALE_Q24=25'd20591742,parameter ENABLE_VISIBILITY=0,parameter ENABLE_CONTOUR=0,parameter TINYML_RGB=0,parameter ENABLE_INTERP=1,parameter HEIGHT=720)(
 input wire clk,video_clk,rst_n,
 input wire [15:0] paddr,input wire psel,penable,pwrite,
 input wire [31:0] pwdata,output reg [31:0] prdata,
 input wire [31:0] bus_write_dummy_bad,output reg ddr_serial_enable,
 output wire frame_commit_pulse,
 output reg [11:0] ai_centifps,output reg ai_rate_toggle,
 input wire i_hs,i_vs,i_de,input wire [47:0] i_rgb,
 output wire o_hs,o_vs,o_de,output wire [47:0] o_rgb,
 output wire [31:0] awaddr,output wire [7:0] awlen,
 output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire wvalid,wlast,input wire wready,
 input wire [1:0] bresp,input wire bvalid,output wire bready,
 output wire [31:0] araddr,output wire [7:0] arlen,
 output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,input wire rvalid,rlast,
 output wire rready
);
reg [1:0] pair_cfg,capture_pair,commit_pair,inference_pair;
reg capture_request,commit_toggle,inference_busy;
reg [2:0] captured_valid;
reg [1:0] visibility_mode;
reg visibility_toggle;
wire visibility_ack;
reg [2:0] visibility_ack_sync;
wire visibility_pending=visibility_toggle!=visibility_ack_sync[2];
wire cap_busy,cap_done,cap_error,capture_enable;
wire [31:0] capture_write_dummy_bad;
wire commit_ack,interp_step_toggle,video_have;
wire [1:0] video_pair;
reg [2:0] ack_sync,step_sync,have_sync;
reg [1:0] pair_sync1,pair_sync2;
reg ack_previous,step_previous,done_previous;
reg [31:0] displayed_count,captured_count,rejected_count;
reg [31:0] rate_age;
wire pending_commit=commit_toggle!=ack_sync[2];
// Each VS-confirmed bank change or 60 Hz interpolated->true sub-frame step pulses OSD FPS.
assign frame_commit_pulse=(ack_sync[2]^ack_previous) | (step_sync[2]^step_previous);
wire write_reg=psel && penable && pwrite;
wire [31:0] underflows,read_errors;
wire valid,dual,sof,eol,eof;wire [31:0] rgba,rgba_b;
wire [9:0] pixel_x;wire [8:0] pixel_y;
generate if(TINYML_RGB)begin : g_rgb_capture
iris_tinyml_preprocess u_preprocess(
 .clk(video_clk),.rst_n(rst_n),.enable(capture_enable),
 .i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
 .o_valid(valid),.o_word(rgba),.o_sof(sof),.o_eof(eof));
assign dual=0;assign rgba_b=0;assign eol=0;assign pixel_x=0;assign pixel_y=0;
end else begin : g_rgba_capture
iris_style_preprocess #(.HEIGHT(HEIGHT)) u_preprocess(
 .clk(video_clk),.rst_n(rst_n),.enable(capture_enable),
 .i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
 .o_valid(valid),.o_rgba(rgba),.o_dual(dual),.o_rgba_b(rgba_b),.o_sof(sof),.o_eol(eol),.o_eof(eof),.o_x(pixel_x),.o_y(pixel_y)
);
end endgenerate
iris_style_capture #(.FRAME_WORDS(TINYML_RGB ? 3072 : (HEIGHT*160)),
 .FIFO_AW(TINYML_RGB ? 5 : 8),.BURST_BITS(TINYML_RGB ? 2 : 4),.AUDIT_DUMMY(!TINYML_RGB),
 .STAGING_STYLE(TINYML_RGB ? "hybrid" : "registers")) u_capture(
 .clk(clk),.video_clk(video_clk),.rst_n(rst_n),.request(capture_request),.pair(capture_pair),
 .busy(cap_busy),.done(cap_done),.error(cap_error),.capture_enable(capture_enable),
 .write_dummy_bad(capture_write_dummy_bad),
 .i_vs(i_vs),.i_valid(valid),.i_sof(sof),.i_eof(eof),.i_rgba(rgba),.i_dual(dual),.i_rgba_b(rgba_b),
 .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
 .wdata(wdata),.wlast(wlast),.wvalid(wvalid),.wready(wready),
 .bresp(bresp),.bvalid(bvalid),.bready(bready)
);
generate if(TINYML_RGB)begin : g_tinyml_panels
iris_tinyml_panels u_panels(
 .clk(clk),.video_clk(video_clk),.rst_n(rst_n),
 .commit_toggle(commit_toggle),.commit_pair(commit_pair),.commit_ack(commit_ack),
 .active_pair(video_pair),.have_frame(video_have),
 .i_hs(i_hs),.i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
 .o_hs(o_hs),.o_vs(o_vs),.o_de(o_de),.o_rgb(o_rgb),
 .underflows(underflows),.read_errors(read_errors),
 .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
 .rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready));
assign visibility_ack=visibility_toggle;
assign interp_step_toggle=1'b0;
end else if(ENABLE_CONTOUR)begin : g_contour
iris_style_contour_panels #(.SCALE_Q24(SCALE_Q24),.ENABLE_VISIBILITY(ENABLE_VISIBILITY),.ENABLE_INTERP(ENABLE_INTERP),.HEIGHT(HEIGHT)) u_panels(
 .clk(clk),.video_clk(video_clk),.rst_n(rst_n),
 .commit_toggle(commit_toggle),.commit_pair(commit_pair),.commit_ack(commit_ack),
 .interp_step_toggle(interp_step_toggle),
 .active_pair(video_pair),.have_frame(video_have),
 .visibility_mode(visibility_mode),.visibility_toggle(visibility_toggle),.visibility_ack(visibility_ack),
 .i_hs(i_hs),.i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
 .o_hs(o_hs),.o_vs(o_vs),.o_de(o_de),.o_rgb(o_rgb),
 .underflows(underflows),.read_errors(read_errors),
 .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
 .rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready)
);
end else begin : g_legacy
iris_style_panels #(.SCALE_Q24(SCALE_Q24),.ENABLE_VISIBILITY(ENABLE_VISIBILITY),.ENABLE_INTERP(ENABLE_INTERP)) u_panels(
 .clk(clk),.video_clk(video_clk),.rst_n(rst_n),
 .commit_toggle(commit_toggle),.commit_pair(commit_pair),.commit_ack(commit_ack),
 .interp_step_toggle(interp_step_toggle),
 .active_pair(video_pair),.have_frame(video_have),
 .visibility_mode(visibility_mode),.visibility_toggle(visibility_toggle),.visibility_ack(visibility_ack),
 .i_hs(i_hs),.i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
 .o_hs(o_hs),.o_vs(o_vs),.o_de(o_de),.o_rgb(o_rgb),
 .underflows(underflows),.read_errors(read_errors),
 .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
 .rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready)
);
end endgenerate
always @*begin
 case(paddr[7:2])
  0:prdata={16'h4953,7'd0,pair_cfg[1],pair_sync2[1],pair_cfg[0],pending_commit,pair_sync2[0],have_sync[2],cap_error,cap_done,cap_busy};
  1:prdata={30'd0,pair_cfg};
  2:prdata=pair_cfg==2 ? 32'h03800000 : pair_cfg==1 ? 32'h03200000 : 32'h03000000;
  3:prdata=pair_cfg==2 ? 32'h03a00000 : pair_cfg==1 ? 32'h03600000 : 32'h03400000;
  4:prdata=displayed_count;
  5:prdata=captured_count;
  6:prdata=underflows;
  7:prdata=read_errors;
  8:prdata=rejected_count;
  9:prdata=TINYML_RGB ? 32'h00030003 : 32'h00030002; // Three banks, independent capture/commit ABI 2.
  10:prdata=capture_write_dummy_bad;
  11:prdata=bus_write_dummy_bad;
  12:prdata={31'd0,ddr_serial_enable};
  13:prdata={30'd0,visibility_mode};
  14:prdata={31'd0,visibility_pending};
  15:prdata=ENABLE_CONTOUR ? 32'h494b0002 : ENABLE_VISIBILITY ? 32'h494b0001 : 0;
  16:prdata=32'h49500301; // Pipeline ownership ABI, three DDR bank pairs.
  17:prdata={29'd0,captured_valid};
  18:prdata={29'd0,inference_busy,inference_pair};
  19:prdata={29'd0,have_sync[2],pair_sync2};
  20:prdata={30'd0,capture_pair};
  21:prdata={30'd0,commit_pair};
  22:prdata={20'd0,ai_centifps};
  default:prdata=0;
 endcase
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  pair_cfg<=0;capture_pair<=0;commit_pair<=0;inference_pair<=0;
  capture_request<=0;commit_toggle<=0;inference_busy<=0;captured_valid<=0;
  ack_sync<=0;step_sync<=0;pair_sync1<=0;pair_sync2<=0;have_sync<=0;ack_previous<=0;step_previous<=0;done_previous<=0;
  displayed_count<=0;captured_count<=0;rejected_count<=0;
  ai_centifps<=0;ai_rate_toggle<=0;rate_age<=0;
  ddr_serial_enable<=0;
  visibility_mode<=ENABLE_VISIBILITY ? 2 : 0;visibility_toggle<=0;visibility_ack_sync<=0;
 end else begin
  capture_request<=0;
  if(TINYML_RGB)begin
   if(rate_age<32'd3000000000)rate_age<=rate_age+1'b1;
   else if(ai_centifps!=0)begin ai_centifps<=0;ai_rate_toggle<=~ai_rate_toggle;end
  end
  ack_sync<={ack_sync[1:0],commit_ack};
  step_sync<={step_sync[1:0],interp_step_toggle};
  visibility_ack_sync<={visibility_ack_sync[1:0],visibility_ack};
  pair_sync1<=video_pair;pair_sync2<=pair_sync1;
  have_sync<={have_sync[1:0],video_have};
  ack_previous<=ack_sync[2];step_previous<=step_sync[2];done_previous<=cap_done;
  if(ack_sync[2]!=ack_previous)displayed_count<=displayed_count+1'b1;
  if(cap_done && !done_previous && !cap_error)begin
   captured_count<=captured_count+1'b1;captured_valid[capture_pair]<=1;
  end
  if(write_reg)begin
   if(TINYML_RGB && paddr[7:2]==22)begin
    ai_centifps<=pwdata[11:0];ai_rate_toggle<=~ai_rate_toggle;rate_age<=0;
   end
   if(ENABLE_VISIBILITY && paddr[7:2]==13 && !visibility_pending)begin visibility_mode<=pwdata[1:0];visibility_toggle<=~visibility_toggle;end
   if(paddr[7:2]==12)ddr_serial_enable<=pwdata[0];
   if(paddr[7:2]==1)begin
    if(pwdata<3)pair_cfg<=pwdata[1:0];
    else rejected_count<=rejected_count+1'b1;
   end
   if(paddr[7:2]==18)begin
    if(pwdata[1:0]<3 && pwdata[31:3]==0)begin
     if(pwdata[2])begin
      if(!inference_busy && captured_valid[pwdata[1:0]] &&
         (!(cap_busy || capture_request) || capture_pair!=pwdata[1:0]) &&
         (!pending_commit || commit_pair!=pwdata[1:0]) &&
         (!have_sync[2] || pair_sync2!=pwdata[1:0]))begin
       inference_pair<=pwdata[1:0];inference_busy<=1;
      end else rejected_count<=rejected_count+1'b1;
     end else if(inference_busy && inference_pair==pwdata[1:0])inference_busy<=0;
     else rejected_count<=rejected_count+1'b1;
    end else rejected_count<=rejected_count+1'b1;
   end
   if(paddr[7:2]==0)begin
    if(pwdata[1:0]==3)rejected_count<=rejected_count+1'b1;
    else if(pwdata[0])begin
     if(!cap_busy && !capture_request && (!have_sync[2] || pair_cfg!=pair_sync2) &&
        (!pending_commit || pair_cfg!=commit_pair) &&
        (!inference_busy || pair_cfg!=inference_pair))begin
      capture_pair<=pair_cfg;capture_request<=1;captured_valid[pair_cfg]<=0;
     end
     else rejected_count<=rejected_count+1'b1;
    end
    else if(pwdata[1])begin
     if(captured_valid[pair_cfg] && (!(cap_busy || capture_request) || pair_cfg!=capture_pair) &&
        !pending_commit && (!have_sync[2] || pair_cfg!=pair_sync2) &&
        (!inference_busy || pair_cfg!=inference_pair))begin
      commit_pair<=pair_cfg;commit_toggle<=~commit_toggle;
     end
     else rejected_count<=rejected_count+1'b1;
    end
   end
  end
 end
end
endmodule
