// Request is a stable GPIO-domain level; mode changes only on read-frame VS.
// Pixel-domain payload is also stable and crosses through three flip-flops.
module video_mode_commit(input read_clk,pixel_clk,rst_n,request_4k,read_vs,
 output reg read_4k,output wire pixel_4k);
reg [2:0] req_sync,mode_sync;
reg vs_d;
always @(posedge read_clk or negedge rst_n)begin
 if(!rst_n)begin req_sync<=0;read_4k<=0;vs_d<=0;end
 else begin
  req_sync<={req_sync[1:0],request_4k};vs_d<=read_vs;
  if(read_vs&&!vs_d)read_4k<=req_sync[2];
 end
end
always @(posedge pixel_clk or negedge rst_n)begin
 if(!rst_n)mode_sync<=0;else mode_sync<={mode_sync[1:0],read_4k};
end
assign pixel_4k=mode_sync[2];
endmodule
