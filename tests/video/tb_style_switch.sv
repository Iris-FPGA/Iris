`timescale 1ns/1ps
module tb_style_switch;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,key_n=0,error=0,request=0;
wire [1:0] select0,select1;
wire ena,config_request;
wire [31:0] status;
iris_style_switch #(.CLK_HZ(1000),.DEB_MS(5)) dut(
 .clk(clk),.rst_n(rst_n),.key_n(key_n),.config_error(error),.request_toggle(request),
 .cbsel(select0),.ena(ena),.config_request(config_request),.status(status));
iris_style_switch #(.CLK_HZ(1000),.DEB_MS(5),.CURRENT_IMAGE(1)) rain(
 .clk(clk),.rst_n(rst_n),.key_n(key_n),.config_error(error),.request_toggle(request),
 .cbsel(select1),.ena(),.config_request(),.status());
task clocks(input integer n); repeat(n)begin @(posedge clk);#1;end endtask
task reset; begin rst_n=0;clocks(2);rst_n=1;clocks(2);end endtask
initial begin
 reset();clocks(30);
 if(ena || config_request || status[2])$fatal(1,"boot-held key armed or triggered");
 key_n=1;clocks(10);
 if(!status[2] || ena)$fatal(1,"release did not arm");
 repeat(3)begin key_n=0;clocks(2);key_n=1;clocks(4);end
 if(ena)$fatal(1,"bounce caused reconfiguration");
 key_n=0;clocks(8);
 if(!ena || config_request)$fatal(1,"press/capture sequencing");
 if(select0!=1 || select1!=0)$fatal(1,"wrong alternate image");
 clocks(8);if(!config_request)$fatal(1,"capture settle not followed by CONFIG");
 clocks(30);if(!config_request)$fatal(1,"CONFIG was not held");
 // Model reconfiguration while the user continues holding KEY3.
 reset();clocks(30);if(ena)$fatal(1,"held key bounced between images");
 key_n=1;clocks(10);key_n=0;clocks(18);
 if(!config_request)$fatal(1,"second physical press failed");
 reset();error=1;request=~request;key_n=1;clocks(20);key_n=0;clocks(20);
 if(ena || config_request)$fatal(1,"error status allowed another reconfiguration");
 error=0;reset();request=0;clocks(10);request=1;clocks(15);
 if(!config_request)$fatal(1,"service toggle did not reach the same sequencer");
 $display("PASS style switch: both directions, debounce, boot-held release, capture settle, error guard, service CDC");
 $finish;
end
initial begin #10000;$fatal(1,"timeout");end
endmodule
