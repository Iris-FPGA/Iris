// APB0 control plane for paired camera/style presentation.
// Two disjoint input/output pairs. CPU can capture only the non-displayed pair;
// display ownership changes at VS and is acknowledged before pair reuse.
module iris_style_demo #(parameter [24:0] SCALE_Q24=25'd20591742)(
 input wire clk,video_clk,rst_n,
 input wire [15:0] paddr,input wire psel,penable,pwrite,
 input wire [31:0] pwdata,output reg [31:0] prdata,
 input wire [31:0] bus_write_dummy_bad,output reg ddr_serial_enable,
 output wire frame_commit_pulse,
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
reg pair_cfg,capture_request,commit_toggle;
wire cap_busy,cap_done,cap_error,capture_enable;
wire [31:0] capture_write_dummy_bad;
wire commit_ack,video_pair,video_have;
reg [2:0] ack_sync,pair_sync,have_sync;
reg ack_previous,done_previous;
reg [31:0] displayed_count,captured_count,rejected_count;
wire pending_commit=commit_toggle!=ack_sync[2];
// Each VS-confirmed bank change counts once, on either toggle edge.
assign frame_commit_pulse=ack_sync[2]^ack_previous;
wire write_reg=psel && penable && pwrite;
wire [31:0] underflows,read_errors;
wire valid,sof,eol,eof;wire [31:0] rgba;
wire [9:0] pixel_x;wire [8:0] pixel_y;
iris_style_preprocess u_preprocess(
 .clk(video_clk),.rst_n(rst_n),.enable(capture_enable),
 .i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
 .o_valid(valid),.o_rgba(rgba),.o_sof(sof),.o_eol(eol),.o_eof(eof),.o_x(pixel_x),.o_y(pixel_y)
);
iris_style_capture u_capture(
 .clk(clk),.video_clk(video_clk),.rst_n(rst_n),.request(capture_request),.pair(pair_cfg),
 .busy(cap_busy),.done(cap_done),.error(cap_error),.capture_enable(capture_enable),
 .write_dummy_bad(capture_write_dummy_bad),
 .i_vs(i_vs),.i_valid(valid),.i_sof(sof),.i_eof(eof),.i_rgba(rgba),
 .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
 .wdata(wdata),.wlast(wlast),.wvalid(wvalid),.wready(wready),
 .bresp(bresp),.bvalid(bvalid),.bready(bready)
);
iris_style_panels #(.SCALE_Q24(SCALE_Q24)) u_panels(
 .clk(clk),.video_clk(video_clk),.rst_n(rst_n),
 .commit_toggle(commit_toggle),.commit_pair(pair_cfg),.commit_ack(commit_ack),
 .active_pair(video_pair),.have_frame(video_have),
 .i_hs(i_hs),.i_vs(i_vs),.i_de(i_de),.i_rgb(i_rgb),
 .o_hs(o_hs),.o_vs(o_vs),.o_de(o_de),.o_rgb(o_rgb),
 .underflows(underflows),.read_errors(read_errors),
 .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
 .rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready)
);
always @*begin
 case(paddr[5:2])
  0:prdata={16'h4953,9'd0,pair_cfg,pending_commit,pair_sync[2],have_sync[2],cap_error,cap_done,cap_busy};
  1:prdata={31'd0,pair_cfg};
  2:prdata=pair_cfg ? 32'h03200000 : 32'h03000000;
  3:prdata=pair_cfg ? 32'h03600000 : 32'h03400000;
  4:prdata=displayed_count;
  5:prdata=captured_count;
  6:prdata=underflows;
  7:prdata=read_errors;
  8:prdata=rejected_count;
  9:prdata=32'h000a0001; // ABI 1; ten hardware operators in demo model.
  10:prdata=capture_write_dummy_bad;
  11:prdata=bus_write_dummy_bad;
  12:prdata={31'd0,ddr_serial_enable};
  default:prdata=0;
 endcase
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  pair_cfg<=0;capture_request<=0;commit_toggle<=0;
  ack_sync<=0;pair_sync<=0;have_sync<=0;ack_previous<=0;done_previous<=0;
  displayed_count<=0;captured_count<=0;rejected_count<=0;
  ddr_serial_enable<=0;
 end else begin
  capture_request<=0;
  ack_sync<={ack_sync[1:0],commit_ack};
  pair_sync<={pair_sync[1:0],video_pair};
  have_sync<={have_sync[1:0],video_have};
  ack_previous<=ack_sync[2];done_previous<=cap_done;
  if(ack_sync[2]!=ack_previous)displayed_count<=displayed_count+1'b1;
  if(cap_done && !done_previous && !cap_error)captured_count<=captured_count+1'b1;
  if(write_reg)begin
   if(paddr[5:2]==12)ddr_serial_enable<=pwdata[0];
   if(paddr[5:2]==1)begin
    if(!cap_busy && !pending_commit)pair_cfg<=pwdata[0];
    else rejected_count<=rejected_count+1'b1;
   end
   if(paddr[5:2]==0)begin
    if(pwdata[0])begin
     if(!cap_busy && !pending_commit && (!have_sync[2] || pair_cfg!=pair_sync[2]))capture_request<=1;
     else rejected_count<=rejected_count+1'b1;
    end
    if(pwdata[1])begin
     if(cap_done && !cap_error && !cap_busy && !pending_commit &&
        (!have_sync[2] || pair_cfg!=pair_sync[2]))commit_toggle<=~commit_toggle;
     else rejected_count<=rejected_count+1'b1;
    end
   end
  end
 end
end
endmodule
