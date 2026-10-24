`timescale 1ns/1ps
module tb_tinyml_panels;
reg clk=0,video_clk=0,rst_n=0;
always #5 clk=~clk;always #7 video_clk=~video_clk;
reg commit=0;reg [1:0] pair=0;
reg hs=0,vs=0,de=0;reg [47:0] rgb=48'h123456abcdef;
wire ack,have;wire [1:0] active;
wire oh,ov,od;wire [47:0] out;
wire [31:0] uf,err,addr;wire [7:0] len;wire av,rr;
reg arready=0,rv=0;reg [127:0] rd=0;
integer cycle=0,delay_r=0;reg pending=0;reg [31:0] captured_addr;
reg inject_error=0;reg [1:0] resp=0;
iris_tinyml_panels dut(.clk(clk),.video_clk(video_clk),.rst_n(rst_n),
 .commit_toggle(commit),.commit_pair(pair),.commit_ack(ack),.have_frame(have),.active_pair(active),
 .i_hs(hs),.i_vs(vs),.i_de(de),.i_rgb(rgb),.o_hs(oh),.o_vs(ov),.o_de(od),.o_rgb(out),
 .underflows(uf),.read_errors(err),.araddr(addr),.arlen(len),.arvalid(av),.arready(arready),
 .rdata(rd),.rresp(resp),.rlast(1'b1),.rvalid(rv),.rready(rr));
reg [7:0] quant_ref[0:255];
reg [2047:0] ref_file;
function [7:0] tensor_byte;
 input integer p,is_output,offset;
 integer x,y,c;
 begin x=(offset/3)%128;y=(offset/3)/128;c=offset%3;
 tensor_byte=(x*3+y*7+c*67+p*29+(is_output ? 101 : 0))%256;end
endfunction
function [7:0] memory_byte;
 input [31:0] a;
 integer p,is_output,offset;
 begin
 if(a>=32'h03a00000)begin p=2;is_output=1;offset=a-32'h03a00000;end
 else if(a>=32'h03800000)begin p=2;is_output=0;offset=a-32'h03800000;end
 else if(a>=32'h03600000)begin p=1;is_output=1;offset=a-32'h03600000;end
 else if(a>=32'h03400000)begin p=0;is_output=1;offset=a-32'h03400000;end
 else if(a>=32'h03200000)begin p=1;is_output=0;offset=a-32'h03200000;end
 else begin p=0;is_output=0;offset=a-32'h03000000;end
 if(offset>=49152)$fatal(1,"read outside tensor");
 memory_byte=tensor_byte(p,is_output,offset);
 end
endfunction
integer b;
always @(posedge clk)if(rst_n)begin
 cycle<=cycle+1;arready<=cycle%5!=0;
 if(av && arready)begin
  if(pending || len!=0 || addr[3:0])$fatal(1,"invalid read transaction");
  pending<=1;captured_addr<=addr;delay_r<=3+cycle%17;
 end
 if(delay_r>0)begin
  delay_r<=delay_r-1;
  if(delay_r==1)begin
   rv<=1;resp<=inject_error ? 2 : 0;
   for(b=0;b<16;b=b+1)rd[b*8+:8]<=memory_byte(captured_addr+b);
  end
 end
 if(rv && rr)begin rv<=0;pending<=0;end
end
integer px=0,py=0,expected_pair=0,checks=0;reg check=0,expect_frame=0;
reg [47:0] expected[0:2];reg [2:0] dh,dv,dd,check_pipe;
reg [47:0] value;reg [23:0] p;reg [7:0] code;
integer c,mx,my,off,lane;reg [47:0] rect_value;
always @(posedge video_clk)begin
 if(!rst_n)begin dh=0;dv=0;dd=0;check_pipe=0;expected[0]=0;expected[1]=0;expected[2]=0;end
 else begin
  expected[2]=expected[1];expected[1]=expected[0];
  value=rgb;
  if(expect_frame && px>=960 && de)begin
   value=0;
   if(!inject_error)begin
    for(lane=0;lane<2;lane=lane+1)begin
     mx=(px+lane)/15;my=(py*128)/1080;off=(my*128+mx)*3;
     for(c=0;c<3;c=c+1)begin
      code=tensor_byte(expected_pair,1,off+c);p[23-c*8-:8]=quant_ref[code];
     end
     value[47-lane*24-:24]=p;
    end
   end
  end
  expected[0]=value;
  dh={dh[1:0],hs};dv={dv[1:0],vs};dd={dd[1:0],de};check_pipe={check_pipe[1:0],check};
  #1;
  if(check_pipe[2])begin
   if(oh!==dh[2] || ov!==dv[2] || od!==dd[2])$fatal(1,"sync pipeline mismatch");
   if(od && out!==expected[2])$fatal(1,"split pixel (%0d,%0d) got=%h expected=%h",px,py,out,expected[2]);
   if(od)checks=checks+1;
  end
 end
end
task frame;
 input integer pnum,do_commit;
 integer x,y;
 begin
  @(negedge video_clk);check=0;vs=1;de=0;
  if(do_commit)begin pair=pnum;commit=~commit;end
  repeat(12)@(negedge video_clk);
  // Commit must have crossed and be accepted at a VS edge, so raise VS
  // only after the synchronized request is stable.
  vs=0;repeat(8)@(negedge video_clk);vs=1;
  repeat(40)@(negedge video_clk);vs=0;
  if(do_commit)begin
   if(ack!==commit || !have || active!=pnum)$fatal(1,"VS ownership acknowledgement");
   expected_pair=pnum;expect_frame=1;
  end
  check=1;
  for(y=0;y<1080;y=y+1)begin
   for(x=0;x<1920;x=x+2)begin
    @(negedge video_clk);de=1;hs=0;px=x;py=y;rgb={24'(x+y+pnum*33),24'(x+y+pnum*33+1)};
   end
   @(negedge video_clk);de=0;hs=1;repeat(100)@(negedge video_clk);
  end
  check=0;repeat(50)@(negedge video_clk);
 end
endtask
initial begin
 if(!$value$plusargs("REF=%s",ref_file))$fatal(1,"missing quantization oracle");
 $readmemh(ref_file,quant_ref);
 #100;rst_n=1;frame(0,0);frame(0,1);frame(2,1);
 if(uf || err || checks<3000000)$fatal(1,"display diagnostic failure %0d %0d %0d",uf,err,checks);
 // A read error must not publish the partially updated row.
 inject_error=1;frame(1,1);
 if(err==0 || uf==0)$fatal(1,"read failure not visible");
 $display("PASS TinyML HDMI: full split raster, all RGB codes, full 1920x1080, live left, exact 15x/1080 scaling, sync, bank 0/2, stalls and read failure");$finish;
end
initial begin #80000000;$fatal(1,"timeout");end
endmodule
