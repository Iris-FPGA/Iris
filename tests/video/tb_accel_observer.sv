`timescale 1ns/1ps
module tb_accel_observer;
reg clk=0,rst_n=0,cmd_fire=0,irq=0;
always #5 clk=~clk;
reg [9:0] function_id=0;
reg [31:0] inputs_0=0,inputs_1=0,araddr=0,awaddr=0;
reg arvalid=0,arready=0,rvalid=0,rready=0,rlast=0;
reg awvalid=0,awready=0,wvalid=0,wready=0,wlast=0,bvalid=0,bready=0;
wire [31:0] obs0,obs1,obs2,obs3,obs4,obs5,obs6,obs7,obs8;
iris_accel_observer dut(.*);
task tick;begin @(posedge clk);#1;end endtask
task command(input [9:0] f,input [31:0] a);begin
 @(negedge clk);function_id=f;inputs_0=a;inputs_1=32'hcafef00d;cmd_fire=1;tick();
 @(negedge clk);cmd_fire=0;
end endtask
initial begin
 tick();@(negedge clk);rst_n=1;tick();
 command(10'h010,1);command(10'h02e,32'h1234);
 if(obs5!==32'h00010000)$fatal(1,"incorrect start decoding");
 @(negedge clk);irq=1;tick();repeat(5)tick();
 if(obs0[31:16]!==1)$fatal(1,"held interrupt counted repeatedly");
 command(10'h010,2);
 if(obs5!==32'h00010001)$fatal(1,"incorrect Conv acknowledgement decoding");
 @(negedge clk);irq=0;tick();
 command(10'h029,1);@(negedge clk);irq=1;tick();
 command(10'h02f,0);
 if(obs0[31:16]!==2||obs5!==32'h00020002)$fatal(1,"Add interrupt accounting");
 @(negedge clk);arvalid=1;araddr=32'h12340000;awvalid=1;awaddr=32'h23450000;
 repeat(3)tick();
 if(obs1!==0||obs2!==0||obs3!==0)$fatal(1,"counted blocked address");
 @(negedge clk);arready=1;awready=1;tick();
 @(negedge clk);arvalid=0;awvalid=0;arready=0;awready=0;
 if(obs1!==32'h00010001||obs2!==araddr||obs3!==awaddr)$fatal(1,"missing accepted address");
 rvalid=1;rlast=1;bvalid=1;repeat(2)tick();
 if(obs1!==32'h00010001||obs4!==0)$fatal(1,"counted blocked completion");
 @(negedge clk);rready=1;bready=1;tick();
 @(negedge clk);rvalid=0;bvalid=0;
 if(obs1!==0||obs4!==32'h00010001)$fatal(1,"missing accepted completion");
 if(obs6!==0||obs7!==32'hcafef00d)$fatal(1,"CI operand capture");
 irq=0;rst_n=0;tick();
 if(obs0!==0||obs1!==0||obs4!==0||obs5!==0)$fatal(1,"reset");
 $display("PASS accel observer handshake, interrupt and Conv/Add decoding");$finish;
end
initial begin #5000;$fatal(1,"timeout");end
endmodule
