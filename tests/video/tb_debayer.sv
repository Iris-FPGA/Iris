`timescale 1ns/1ps
module tb_debayer #(parameter BGGR=0,HT=12);
localparam W=16, H=8, VT=12, N=HT*VT;
reg clk=0, rst=0;
always #5 clk=~clk;
reg hs=0,vs=0,de=0;
reg [15:0] raw=0;
wire oh,ov,od,valid;
wire [47:0] rgb;
reg [18:0] stimulus [0:N-1];
reg [47:0] expected [0:W*H/2-1];
reg [2:0] timing [0:N+HT+10];
reg [1023:0] infile,reffile;
integer t,p,n,frames;
debayer_top_2to1 #(.H_TOTAL(HT),.H_ACTIVE(W/2),.V_ACTIVE(H),.BAYER_BGGR(BGGR)) dut
(.in_pclk(clk),.in_rstn(rst),.raw_vs_i(vs),.raw_hs_i(hs),.raw_de_i(de),
 .raw_valid_i(de),.raw_datax4_i(raw),.i_r_gain(3'd4),.i_g_gain(3'd4),.i_b_gain(3'd4),
 .rgb_hs_o(oh),.rgb_vs_o(ov),.rgb_de_o(od),.rgb_valid_o(valid),.rgb_datax2_o(rgb));
initial begin
 if (!$value$plusargs("IN=%s",infile) || !$value$plusargs("REF=%s",reffile)) $fatal(1,"Missing fixtures");
 $readmemh(infile,stimulus); $readmemh(reffile,expected);
 repeat (4) @(negedge clk); rst=1;
 p=0;n=0;frames=0;
 for (t=0;t<3*N+HT+4;t=t+1) begin
  if (t<3*N) {hs,vs,de,raw}=stimulus[t%N]; else {hs,vs,de,raw}=0;
  timing[t% (N+HT+11)]={hs,vs,de};
  @(posedge clk); #1;
  if (t>=HT+2) begin
   if ({oh,ov,od} !== timing[(t-HT-2)%(N+HT+11)])
    $fatal(1,"Raster alignment t=%0d got=%b expected=%b",t,{oh,ov,od},timing[(t-HT-2)%(N+HT+11)]);
  end
  if (valid !== od) $fatal(1,"Valid mismatch");
  if (od) begin
   if (rgb !== expected[p]) $fatal(1,"RGB mismatch pixel=%0d got=%h expected=%h",p*2,rgb,expected[p]);
   p=p+1;n=n+1;
   if (p==W*H/2) begin p=0;frames=frames+1;end
  end
  @(negedge clk);
 end
 if (n!=3*W*H/2 || frames!=3) $fatal(1,"Frame size n=%0d",n);
 $display("PASS debayer: 3 complete frames incl borders, RGB and raster timing");
 $finish;
end
endmodule
