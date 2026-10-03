`timescale 1ns/1ps
module tb_sensor_telemetry;
reg clk=0,byte_clk=0,rst=0;
always #5 clk=~clk;
always #8 byte_clk=~byte_clk;
wire [31:0] hz;
clock_frequency_meter #(.REF_HZ(1000)) meter(.i_clock(byte_clk),.i_ref_clock(clk),.rst_n(rst),.o_hz(hz));
wire ready,valid,gate,txd;
wire [7:0] data;
wire busy,over;
localparam [255:0] REGS=256'hcd6b078004380708047e0144000553230d6518532354211c107a0a2000200001;
ae_uart_log #(.PERIOD(25000)) log(.clk(clk),.rst_n(rst),
 .i_pause(1'b0),.i_target(8'h40),.i_init(1'b1),.i_state(2'd1),.i_exp(12'h200),.i_gain(4'd0),.i_sum(32'h12345678),.i_writes(8'h0a),.i_touts(8'd0),.i_luma(8'h80),
 .i_sensor_readback(REGS),.i_cam_fps(8'd60),.i_wr_fps(8'd60),.i_hdmi_fps(8'd60),.i_byte_hz(32'd70000000),.i_cam_period(32'h00196629),
 .tx_req(ready),.tx_valid(valid),.tx_data(data),.tx_gate(gate),.fifo_act(1'b0));
uart_tx #(.BPS_CNT(8)) tx(.clk(clk),.tx_data(data),.tx_valid(valid),.tx_req(ready),.tx_over(over),.tx_busy(busy),.txd(txd));
integer i,j,received=0;
reg [7:0] ch;
reg [7:0] line[0:159];
function [7:0] hexchar;input[3:0]v;begin hexchar=(v<10)?"0"+v:"A"+v-10;end endfunction
initial begin
 repeat(4)@(negedge clk);rst=1;
 repeat(3500)@(negedge clk);
 if(hz<624||hz>626)$fatal(1,"Byte-clock counter ratio %0d",hz);
end
initial begin
 for(j=0;j<3;j=j+1)begin
  for(i=0;i<160;i=i+1)begin
   @(negedge txd);repeat(4)@(posedge clk);#1;
   if(txd!==0)$fatal(1,"UART start bit");
   for(integer b=0;b<8;b=b+1)begin repeat(8)@(posedge clk);#1;ch[b]=txd;end
   repeat(8)@(posedge clk);#1;if(txd!==1)$fatal(1,"UART stop bit");
   line[i]=ch;received=received+1;
  end
  if(line[0]!=="A"||line[1]!=="E"||line[158]!==13||line[159]!==10)$fatal(1,"Logger frame/truncation");
  for(i=0;i<64;i=i+1)if(line[49+i]!==hexchar(REGS[255-i*4-:4]))$fatal(1,"Register snapshot byte %0d",i);
  for(i=0;i<8;i=i+1)if(line[145+i]!==hexchar(32'h00196629>>((7-i)*4)))$fatal(1,"Period telemetry");
  if(line[116]!=="3"||line[117]!=="C"||line[121]!=="3"||line[122]!=="C"||line[126]!=="3"||line[127]!=="C")$fatal(1,"FPS telemetry");
 end
 $display("PASS sensor telemetry: 3 decoded UART lines incl 32 register readbacks/CAM/WR/HDMI, Gray byte clock ratio");$finish;
end
initial begin #2000000;$fatal(1,"Telemetry timeout received=%0d",received);end
endmodule
