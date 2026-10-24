`timescale 1ns/1ps
module tb_camera_denoise #(parameter W=20,H=10,HT=20,COUNT=1300,PIXELS=800);
reg clk=0;always #5 clk=~clk;
reg rst_n=0,i_hs=0,i_vs=0,i_de=0;
reg [47:0] i_rgb=0;
wire o_hs,o_vs,o_de;wire [47:0] o_rgb;
camera_denoise_2px #(.H_TOTAL(HT),.H_ACTIVE(W/2),.V_ACTIVE(H)) dut(.*);
reg [50:0] stim[0:COUNT-1];reg [47:0] expected[0:PIXELS-1];
reg [2047:0] path_in,path_ref;
localparam DELAY=HT+4;
reg [2:0] controls[0:DELAY-1];
integer checked=0,cycle,k;
always @(posedge clk)begin
 if(!rst_n)for(integer d=0;d<DELAY;d=d+1)controls[d]<=0;
 else begin
  controls[0]<={i_hs,i_vs,i_de};
  for(integer d=1;d<DELAY;d=d+1)controls[d]<=controls[d-1];
 end
end
always @(negedge clk)if(rst_n)begin
 if({o_hs,o_vs,o_de}!==controls[DELAY-1])$fatal(1,"raster mismatch cycle=%d got=%b expected=%b",cycle,{o_hs,o_vs,o_de},controls[DELAY-1]);
 if(o_de)begin
  if(checked>=PIXELS || o_rgb!==expected[checked])$fatal(1,"camera pixel pair %d got=%h expected=%h",checked,o_rgb,expected[checked]);
  checked=checked+1;
 end
end
initial begin
 if(!$value$plusargs("IN=%s",path_in) || !$value$plusargs("REF=%s",path_ref))$fatal(1,"missing fixtures");
 $readmemh(path_in,stim);$readmemh(path_ref,expected);
 repeat(5)@(negedge clk);#1;rst_n=1;
 for(cycle=0;cycle<COUNT;cycle=cycle+1)begin
  @(negedge clk);#1;{i_hs,i_vs,i_de,i_rgb}=stim[cycle];
 end
 for(k=0;k<DELAY+5;k=k+1)begin @(negedge clk);#1;i_hs=0;i_vs=0;i_de=0;i_rgb=0;end
 if(checked!=PIXELS)$fatal(1,"wrong camera count %d/%d",checked,PIXELS);
 $display("PASS native camera Gaussian3 %dx%d: %d pairs, exact 2D convolution, RGB order, four replicated borders and complete raster",W,H,checked);$finish;
end
endmodule
