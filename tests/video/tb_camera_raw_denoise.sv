`timescale 1ns/1ps
module tb_camera_raw_denoise #(parameter W=24,H=12,HT=20,COUNT=340,PIXELS=144,SOURCE=0);
reg clk=0;always #5 clk=~clk;
reg rst_n=0,i_hs=0,i_vs=0,i_de=0;
reg [15:0] i_raw=0;
wire raw_hs,raw_vs,raw_de;wire [15:0] raw_clean;
wire o_hs,o_vs,o_de;wire [(SOURCE?48:16)-1:0] observed;
camera_raw_denoise_2px #(.H_TOTAL(HT),.H_ACTIVE(W/2),.V_ACTIVE(H)) dut(
 .clk(clk),.rst_n(rst_n),.i_hs(i_hs),.i_vs(i_vs),.i_de(i_de),.i_raw(i_raw),
 .o_hs(raw_hs),.o_vs(raw_vs),.o_de(raw_de),.o_raw(raw_clean));
generate if(SOURCE)begin : g_source
 wire rgb_hs,rgb_vs,rgb_de;wire [47:0] rgb;
 debayer_top_2to1 #(.H_TOTAL(HT),.H_ACTIVE(W/2),.V_ACTIVE(H)) debayer(
  .in_pclk(clk),.in_rstn(rst_n),.raw_hs_i(raw_hs),.raw_vs_i(raw_vs),.raw_de_i(raw_de),
  .raw_valid_i(raw_de),.raw_datax4_i(raw_clean),.i_r_gain(3'd4),.i_g_gain(3'd4),.i_b_gain(3'd4),
  .rgb_hs_o(rgb_hs),.rgb_vs_o(rgb_vs),.rgb_de_o(rgb_de),.rgb_datax2_o(rgb));
 camera_denoise_2px #(.H_TOTAL(HT),.H_ACTIVE(W/2),.V_ACTIVE(H)) gaussian(
  .clk(clk),.rst_n(rst_n),.i_hs(rgb_hs),.i_vs(rgb_vs),.i_de(rgb_de),.i_rgb(rgb),
  .o_hs(o_hs),.o_vs(o_vs),.o_de(o_de),.o_rgb(observed));
end else begin : g_raw
 assign o_hs=raw_hs;assign o_vs=raw_vs;assign o_de=raw_de;assign observed=raw_clean;
end endgenerate
reg [18:0] stim[0:COUNT-1];reg [(SOURCE?48:16)-1:0] expected[0:PIXELS-1];
reg [2047:0] path_in,path_ref;
localparam DELAY=SOURCE ? 4*HT+16 : 2*HT+9;
reg [2:0] control_ring[0:DELAY-1];
reg [2:0] expected_control;
integer checked=0,cycle,k,control_addr=0,control_fill=0;
always @(posedge clk)begin
 if(!rst_n)begin control_addr=0;control_fill=0;expected_control=0;end
 else begin
  expected_control=control_fill<DELAY-1 ? 3'b0 : control_ring[control_addr];
  control_ring[control_addr]={i_hs,i_vs,i_de};
  control_addr=control_addr==DELAY-2 ? 0 : control_addr+1;
  control_fill=control_fill+1;
 end
end
always @(negedge clk)if(rst_n)begin
 if({o_hs,o_vs,o_de}!==expected_control)$fatal(1,"RAW raster cycle=%d got=%b expected=%b",cycle,{o_hs,o_vs,o_de},expected_control);
 if(o_de)begin
  if(checked>=PIXELS || observed!==expected[checked])$fatal(1,"source=%d pair %d got=%h expected=%h",SOURCE,checked,observed,expected[checked]);
  checked=checked+1;
 end
end
initial begin
 if(!$value$plusargs("IN=%s",path_in) || !$value$plusargs("REF=%s",path_ref))$fatal(1,"missing fixtures");
 $readmemh(path_in,stim);$readmemh(path_ref,expected);
 repeat(5)@(negedge clk);#1;rst_n=1;
 for(cycle=0;cycle<COUNT;cycle=cycle+1)begin
  @(negedge clk);#1;{i_hs,i_vs,i_de,i_raw}=stim[cycle];
 end
 for(k=0;k<DELAY+5;k=k+1)begin @(negedge clk);#1;i_hs=0;i_vs=0;i_de=0;i_raw=0;end
 if(checked!=PIXELS)$fatal(1,"wrong RAW count %d/%d",checked,PIXELS);
 $display("PASS native Bayer denoise %dx%d: %d pairs, RGB source=%d, same-colour median/clipped mean, parity, four borders, back-to-back frames and complete raster",W,H,checked,SOURCE);$finish;
end
endmodule
