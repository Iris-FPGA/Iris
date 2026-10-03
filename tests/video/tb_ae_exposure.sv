`timescale 1ns/1ps
module tb_ae_exposure;
 reg clk=0,rst=0,tgl=0,ack=0,up=0,dn=0;
 always #5 clk=~clk;
 reg [31:0] sum=0;
 wire req,wr;
 wire [15:0] addr;
 wire [7:0] data;
 wire [11:0] exp;
 wire [3:0] gain;
 wire [1:0] st;
 reg [7:0] r0=0,r1=0,r2=0;
 reg group_open=0,is_exp=0;
 integer sequences=0,t,low_seen=0,high_seen=0;
 ae_ctrl #(.NPX(1000)) dut(
  .clk(clk),.rst_n(rst),.init_done(1'b1),.stats_tgl(tgl),
  .sum_r(sum),.sum_g(sum),.sum_b(sum),.ae_req(req),.ae_wr_en(wr),
  .ae_addr(addr),.ae_data(data),.ae_busy(1'b0),.ae_done(ack),
  .i_tgt_up(up),.i_tgt_dn(dn),.dbg_exp(exp),.dbg_gain(gain),.dbg_state(st));
 always @(posedge clk)begin
  ack<=wr;
  if(rst&&wr)begin
   case(addr)
    16'h3812:begin
     if(data==0)begin
      if(group_open)$fatal(1,"Nested sensor group hold");
      group_open=1;is_exp=0;
     end else if(data==8'h30)begin
      if(!group_open)$fatal(1,"Release without group hold");
      if(is_exp)begin
       if({r0[3:0],r1,r2[7:4]}!=={4'b0,exp})$fatal(1,"Sensor exposure mismatch: encoded=%h controller=%h",{r0[3:0],r1,r2[7:4]},exp);
       if(exp<4||exp>2289)$fatal(1,"Exposure exceeds 2*VTS-11");
       if(exp==4)low_seen=1;if(exp==2289)high_seen=1;
       sequences=sequences+1;
      end
      group_open=0;
     end else $fatal(1,"Unexpected hold value");
    end
    16'h3e00:begin r0=data;is_exp=1;end
    16'h3e01:r1=data;
    16'h3e02:r2=data;
    default:;
   endcase
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;
  // Automatic exposure follows changing brightness, preserving sensor units.
  for(t=0;t<60000;t=t+1)begin
   if(t%70==0)tgl=~tgl;
   sum=(t<25000)?0:1000000;
   up=0;dn=0;
   @(negedge clk);
  end
  if(!high_seen||!low_seen||sequences<60)$fatal(1,"Exposure sweep incomplete %0d %0d %0d",high_seen,low_seen,sequences);
  $display("PASS exposure sensor contract: I2C sequences decode to controller half-lines, 4..2289, group hold and automatic exposure");$finish;
 end
endmodule
