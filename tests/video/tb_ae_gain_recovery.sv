`timescale 1ns/1ps
module tb_ae_gain_recovery;
reg clk=0,rst_n=0,stats_tgl=0,ack=0;
always #5 clk=~clk;
reg [31:0] sum=0;
wire req,wr;wire [15:0] addr;wire [7:0] data;
wire [11:0] exposure;wire [3:0] gain;wire [1:0] state;
ae_ctrl #(.NPX(1000)) dut(
 .clk(clk),.rst_n(rst_n),.init_done(1'b1),.stats_tgl(stats_tgl),
 .sum_r(sum),.sum_g(sum),.sum_b(sum),.ae_req(req),.ae_wr_en(wr),
 .ae_addr(addr),.ae_data(data),.ae_busy(1'b0),.ae_done(ack),
 .i_tgt_up(1'b0),.i_tgt_dn(1'b0),.dbg_exp(exposure),.dbg_gain(gain),.dbg_state(state));
// Independent sensor model: only a released group updates its settings.
reg [7:0] ana=0,fine=8'h20,exp0=0,exp1=8'h20,exp2=0;
reg group_open=0;integer words=0,gain_words=0,exp_words=0;
integer sensor_exp=512,sensor_gain=1000,combined=0,groups=0,old_exp,old_gain;
function integer gain_milli(input [15:0] registers);
 case(registers)
  16'h0020:gain_milli=1000;16'h0030:gain_milli=1500;
  16'h802a:gain_milli=2021;16'h8034:gain_milli=2503;
  16'h8120:gain_milli=3080;16'h812a:gain_milli=4043;
  16'h813f:gain_milli=6064;16'h832a:gain_milli=8085;
  16'h833f:gain_milli=12128;16'h872a:gain_milli=16170;
  16'h8f20:gain_milli=24640;16'h8f2a:gain_milli=32340;
  16'h8f3f:gain_milli=48510;
  default:gain_milli=0;
 endcase
endfunction
real old_product,new_product;
always @(posedge clk)begin
 ack<=wr;
 if(rst_n && wr)begin
  if(addr==16'h3812 && data==0)begin
   if(group_open)$fatal(1,"nested group hold");
   group_open=1;words=1;gain_words=0;exp_words=0;
   old_exp=sensor_exp;old_gain=sensor_gain;
  end else begin
   if(!group_open)$fatal(1,"sensor write outside group hold");
   words=words+1;
   case(addr)
    16'h3e08:begin ana=data;gain_words=gain_words+1;end
    16'h3e09:begin fine=data;gain_words=gain_words+1;end
    16'h3e00:begin exp0=data;exp_words=exp_words+1;end
    16'h3e01:begin exp1=data;exp_words=exp_words+1;end
    16'h3e02:begin exp2=data;exp_words=exp_words+1;end
    16'h3812:begin
     if(data!=8'h30)$fatal(1,"invalid group release");
     sensor_exp={exp0[3:0],exp1,exp2[7:4]};sensor_gain=gain_milli({ana,fine});
     if(sensor_exp<4 || sensor_exp>2289 || sensor_gain==0)$fatal(1,"invalid sensor setting");
     if(exp_words!=0 && exp_words!=3)$fatal(1,"incomplete exposure group");
     if(gain_words!=0 && gain_words!=2)$fatal(1,"incomplete gain group");
     if(exp_words && gain_words)begin
      if(words!=7 || sensor_gain>=old_gain || sensor_exp<=old_exp)$fatal(1,"invalid compensation group");
      old_product=1.0*old_gain*old_exp;new_product=1.0*sensor_gain*sensor_exp;
      if(new_product<old_product*0.995 || new_product>old_product*1.005)$fatal(1,"rebalance changes brightness by >0.5%%");
      combined=combined+1;
     end
     group_open=0;groups=groups+1;
    end
    default:$fatal(1,"unexpected sensor register");
   endcase
  end
 end
end
integer previous_luma=0,older_luma=0,last_luma=0;
task automatic frames(input integer count,input real target_product);
 integer n,luma;
 real value;
 begin
  for(n=0;n<count;n=n+1)begin
   // Propagate two frames of statistics delay, matching sensor N+2 latency.
   value=target_product==0 ? 0 : 72.0*sensor_gain*sensor_exp/target_product;
   luma=value>255 ? 255 : $rtoi(value+0.5);
   @(negedge clk);sum=older_luma*1000;last_luma=older_luma;
   older_luma=previous_luma;previous_luma=luma;stats_tgl=~stats_tgl;
   repeat(160)@(negedge clk);
  end
 end
endtask
task automatic settled(input integer expected_gain);
 begin
  if(gain!=expected_gain || last_luma<69 || last_luma>75)
   $fatal(1,"AE not settled: G=%d expected=%d E=%d L=%d",gain,expected_gain,exposure,last_luma);
 end
endtask
integer groups_before;
initial begin
 repeat(5)@(negedge clk);rst_n=1;
 frames(250,0);if(gain!=12 || exposure!=2289)$fatal(1,"dark precondition incomplete");
 // User-observed equivalent E=0x200, G=0xA: target exposure*gain=12615.68.
 frames(350,12615680.0);settled(6);
 groups_before=groups;frames(80,12615680.0);settled(6);
 if(groups!=groups_before)$fatal(1,"gain/exposure hunts in a constant scene");
 // The other end of the observed range, E=0x410/G=A, needs gain index 8.
 frames(250,0);if(gain!=12 || exposure!=2289)$fatal(1,"second dark precondition incomplete");
 frames(350,25625600.0);settled(8);
 groups_before=groups;frames(80,25625600.0);settled(8);
 if(groups!=groups_before)$fatal(1,"gain/exposure hunts at E=410 equivalent");
 frames(350,512000.0);settled(0);
 frames(350,40000000.0);settled(10);
 if(combined<12 || group_open)$fatal(1,"gain normalization coverage incomplete");
 $display("PASS AE gain recovery: dark-to-light, G=A/E=200..410 equivalent -> G=6..8, low-light G=A retained when needed, atomic groups, <0.5%% brightness change, two-frame delay and no hunting (%0d combined groups)",combined);
 $finish;
end
endmodule
