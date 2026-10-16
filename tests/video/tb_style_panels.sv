`timescale 1ns/1ps
module tb_style_panels #(parameter NEGATIVE=0,parameter VISIBILITY=0,parameter CONTOUR=0,parameter FIRST_MODE=2,parameter SECOND_MODE=1,parameter FIRST_BANK=0,parameter SECOND_BANK=1,parameter NATIVE_CAMERA=0);
reg clk=0,video_clk=0,rst_n=0;
always #5 clk=~clk;
always #7 video_clk=~video_clk;
reg commit_toggle=0,i_hs=0,i_vs=0,i_de=0;
reg [1:0] commit_pair=FIRST_BANK;
reg [47:0] i_rgb=48'h123456abcdef;
wire commit_ack,have_frame,o_hs,o_vs,o_de,arvalid,rready;
wire [1:0] active_pair;
reg [1:0] visibility_mode=FIRST_MODE;reg visibility_toggle=FIRST_MODE!=2;wire visibility_ack;
integer expected_mode=FIRST_MODE;
wire [47:0] o_rgb;wire [31:0] underflows,read_errors,araddr;wire [7:0] arlen;
reg arready=0,rvalid=0,rlast=0;reg [1:0] rresp=0;reg [127:0] rdata=0;
`ifdef TEST_CONTOUR
iris_style_contour_panels #(.ENABLE_VISIBILITY(1),.SCALE_Q24(20596120),.NATIVE_CAMERA_LEFT(NATIVE_CAMERA)) dut(.*);
`else
iris_style_panels #(.ENABLE_VISIBILITY(VISIBILITY),.SCALE_Q24(VISIBILITY ? 20596120 : 20591742)) dut(.*);
`endif
reg [23:0] contour_reference[0:614399];reg [1023:0] contour_path;
initial if(CONTOUR)begin
 if(!$value$plusargs("CONTOUR_REF=%s",contour_path))$fatal(1,"contour reference missing");
 $readmemh(contour_path,contour_reference);
end
integer cyc=0,beat=0,burst_len=0;reg servicing=0;
reg [31:0] address;
function [7:0] colour(input integer y,input integer x,input integer c,input integer style,input integer pair);
 colour=(y*3+x*7+c*43+style*31+pair*23)%256;
endfunction
function [127:0] memory_word(input reg [31:0] a);
 integer offset,pair,style,y,x;
 reg [127:0] v;
 begin
  pair=a>=32'h03800000 ? 2 : (a & 32'h00200000)!=0;
  style=pair==2 ? a>=32'h03a00000 : a>=32'h03400000;
  offset=a-(pair==2 ? (style ? 32'h03a00000 : 32'h03800000) :
             (style ? 32'h03400000 : 32'h03000000)+pair*32'h00200000);
  y=offset/2560;x=(offset%2560)/4;v=0;
  for(integer p=0;p<4;p=p+1)begin
   for(integer c=0;c<3;c=c+1)v[p*32+c*8+:8]=colour(y,x+p,c,style,pair)^8'h80;
   v[p*32+24+:8]=8'h80;
  end
  memory_word=v;
 end
endfunction
always @(posedge clk)begin
 if(!rst_n)begin arready<=0;rvalid<=0;servicing<=0;cyc<=0;end
 else begin
  cyc<=cyc+1;arready<=!servicing && cyc%7!=0;
  if(arvalid && arready)begin
   if(servicing || arlen>127 || ((araddr%4096)+(arlen+1)*16)>4096)$fatal(1,"AXI boundary");
   address<=araddr;burst_len<=arlen;beat<=0;servicing<=1;rvalid<=0;
  end
  if(rvalid && rready)begin
   rvalid<=0;
   if(rlast)servicing<=0;
   else begin beat<=beat+1;address<=address+16;end
  end
  if(servicing && !rvalid && cyc%5!=0)begin
   rdata<=memory_word(address);rvalid<=1;rlast<=beat==burst_len;
   rresp<=NEGATIVE && address==(FIRST_BANK==2 ? 32'h03800000 : 32'h03000000+FIRST_BANK*32'h00200000)+32'h6400 ? 2'b10 : 0;
  end
 end
end
integer tx=0,ty=0,checked=0;
localparam DELAY=2;
reg [50:0] reference[0:DELAY-1];
reg check_enable=0;
function [23:0] rgb(input integer y,input integer x,input integer style,input integer pair);
 integer val,minimum,ink,threshold,ny,nx;reg [23:0] v;
 begin
  v=0;
  for(integer c=0;c<3;c=c+1)begin
   val=colour(y,x,c,style,pair);
   if(style)begin
    if(VISIBILITY && !CONTOUR && expected_mode>=2)begin
     ny=y<479 && !(NEGATIVE && pair==FIRST_BANK && y==9) ? y+1 : y;nx=x>0 ? x-1 : x;
     if(colour(ny,x,c,style,pair)<val)val=colour(ny,x,c,style,pair);
     if(colour(y,nx,c,style,pair)<val)val=colour(y,nx,c,style,pair);
     if(colour(ny,nx,c,style,pair)<val)val=colour(ny,nx,c,style,pair);
    end
    val=$rtoi(val*(VISIBILITY ? 1.2276244163513184 : 1.2273634672164917)+0.5);if(val>255)val=255;
   end
   v={v[15:0],8'(val)};
  end
  if(style && VISIBILITY && expected_mode!=0)begin
   minimum=v[23:16];if(v[15:8]<minimum)minimum=v[15:8];if(v[7:0]<minimum)minimum=v[7:0];
   threshold=expected_mode==3 ? 235 : 239;
   ink=minimum<threshold ? (threshold-minimum)*(expected_mode==3 ? 8 : 4) : 0;
   for(integer c=0;c<3;c=c+1)v[c*8+:8]=v[c*8+:8]>ink ? v[c*8+:8]-ink : 0;
  end
  rgb=style && CONTOUR && expected_mode>=2 ? contour_reference[(pair==FIRST_BANK ? 0 : 307200)+y*640+x] : v;
 end
endfunction
reg [47:0] expected;
integer source_y,source_x;
always @(posedge video_clk)begin
 expected=0;
 source_y=ty*4/9;
 if(have_frame && i_de && tx>=240 && tx<1680)begin
  source_x=(tx-240)*4/9;
  expected[47:24]=rgb(source_y,source_x,source_x>=320,active_pair);
  source_x=(tx-239)*4/9;
  expected[23:0]=rgb(source_y,source_x,source_x>=320,active_pair);
  if(NEGATIVE && active_pair==FIRST_BANK && source_y==10)expected=0;
  if(CONTOUR && NATIVE_CAMERA && tx<960)expected=i_rgb;
 end
 reference[0]<={i_hs,i_vs,i_de,expected};
 for(integer d=1;d<DELAY;d=d+1)reference[d]<=reference[d-1];
end
always @(negedge video_clk)if(check_enable)begin
 if({o_hs,o_vs,o_de,o_rgb}!==reference[DELAY-1])begin
  $display("row=%d good=%b ready=%b source0=%h native=%h valid=%b",dut.current_row,dut.line_good,dut.row_ready,dut.u_split_scaler.row_rgb[0],dut.plain_pipe[0],dut.inside_pipe);
  $fatal(1,"panel mismatch tx=%d ty=%d got=%h ref=%h",tx,ty,{o_hs,o_vs,o_de,o_rgb},reference[DELAY-1]);
 end
 if(o_de)checked=checked+1;
end
task frame;
 begin
  for(integer v=0;v<1125;v=v+1)begin
   for(integer h=0;h<1100;h=h+1)begin
    @(negedge video_clk);
    i_vs=v<5;i_hs=h<22;i_de=v>=45 && v<1125 && h>=74 && h<1034;
    tx=(h-74)*2;ty=v-45;
    i_rgb={8'(tx*3+ty*13),8'(tx*7+ty*5),8'(tx+ty*17),
           8'((tx+1)*3+ty*13),8'((tx+1)*7+ty*5),8'(tx+1+ty*17)};
    if(VISIBILITY && expected_mode==FIRST_MODE && v==500 && h==0)begin visibility_mode=SECOND_MODE;visibility_toggle=FIRST_MODE==2;end
    if(VISIBILITY && expected_mode==FIRST_MODE && v>500 && dut.mode_live!=FIRST_MODE)$fatal(1,"visibility changed during active frame");
   end
  end
 end
endtask
initial begin
 for(integer d=0;d<DELAY;d=d+1)reference[d]=0;
 repeat(4)@(negedge clk);rst_n=1;
 // No committed frame must display black, even with a live RGB input.
 check_enable=1;i_de=1;
 repeat(960)@(negedge video_clk);
 if(arvalid || have_frame)$fatal(1,"uncommitted frame displayed or fetched");
 i_de=0;repeat(8)@(negedge video_clk);commit_toggle=1;
 repeat(8)@(negedge video_clk);
 check_enable=1;frame();
 if(!have_frame || commit_ack!=commit_toggle || underflows!=2*NEGATIVE || read_errors!=NEGATIVE)$fatal(1,"ready/errors %d/%d",underflows,read_errors);
 if(VISIBILITY && visibility_ack!=(FIRST_MODE!=2))$fatal(1,"mode request acknowledged before VS");
 commit_pair=SECOND_BANK;commit_toggle=0;
 // The pair change is requested in blanking before the next VS; preserve
 // the old mailbox until the display acknowledges the new frame boundary.
 check_enable=0;i_de=0;i_vs=0;repeat(8)@(negedge video_clk);
 if(VISIBILITY)expected_mode=SECOND_MODE;
 check_enable=1;frame();
 if(active_pair!=SECOND_BANK || underflows!=2*NEGATIVE || read_errors!=NEGATIVE)$fatal(1,"pair transition");
 if(VISIBILITY && (visibility_ack!=(FIRST_MODE==2) || dut.mode_live!=SECOND_MODE))$fatal(1,"mode request missed VS");
 $display("PASS single split image %d samples, pixel oracle, source seam, pairing",checked);$finish;
end
initial begin #50000000;$fatal(1,"panel timeout");end
endmodule
