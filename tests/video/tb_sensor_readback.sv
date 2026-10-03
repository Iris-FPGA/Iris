`timescale 1ns/1ps
module tb_sensor_readback;
reg clk=0,rst=0,ae_req=0,ae_wr=0;
always #5 clk=~clk;
wire busy,done,idok,ae_done;
wire [7:0] rom_addr;
wire [255:0] regs;
i2c_subsystem dut(.clk(clk),.rst_n(rst),.scl_pad_i(1'b1),.sda_pad_i(1'b1),
 .start(1'b1),.mode(1'b0),.busy(busy),.done(done),.sensor_id_ok(idok),.sensor_readback(regs),
 .rom_addr(rom_addr),.rom_data(25'd0),.cpu_addr(3'd0),.cpu_wdata(8'd0),.cpu_we(1'b0),.cpu_stb(1'b0),
 .ae_req(ae_req),.ae_wr_en(ae_wr),.ae_addr(16'h3e01),.ae_data(8'h20),.ae_done(ae_done));
localparam [255:0] EXPECTED=256'hcd6b08090a0b0c0d0e0f10111213e9eaebecedf9fafbfcfd1f18313700010200;
integer cycles=0;
always @(posedge clk)begin cycles=cycles+1;if(cycles>500)$fatal(1,"Readback arbitration timeout");end
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
initial begin
 repeat(4)tick();rst=1;
 wait(idok);@(negedge clk);ae_req=1;
 // ID is checked early, but complete diagnostic pass keeps AE waiting.
 if(!busy)$fatal(1,"Scanner lost ownership mid-pass");
 wait(!busy);@(negedge clk);
 if(regs!==EXPECTED)$fatal(1,"Register scan addressing/packing %h",regs);
 repeat(4)tick();if(busy)$fatal(1,"Scanner starved pending exposure");
 ae_wr=1;tick();ae_wr=0;wait(ae_done);@(negedge clk);ae_req=0;
 repeat(5)tick();if(!busy)$fatal(1,"Scanner did not resume");
 $display("PASS sensor readback: exact 32 addresses/snapshot, early ID check, pending AE arbitration and resume");$finish;
end
endmodule
// Transaction boundary models; scanner and ownership logic are actual RTL.
module i2c_master_reg_set #(parameter DATA_LENGTH=165,I2C_REG_ADDR_WIDTH=16,I2C_DATA_WIDTH=8,I2C_DEVICE_ADDR=8'h60)(
 input clk,rst_n,init_done,rd_done,wr_done,run,
 output wire wr_en,rd_en,output wire[15:0]addr,output wire[7:0]dout,dev_addr,rom_addr,
 input[24:0]rom_data,output wire done);
assign wr_en=0;assign rd_en=0;assign addr=0;assign dout=0;assign dev_addr=I2C_DEVICE_ADDR;assign rom_addr=0;assign done=run;
endmodule
module i2c_16addr_8data #(parameter CLK_DIV=0,IRQ_EN=0,I2C_EN=1)(
 input clk,rst_n,wr_en,rd_en,input[15:0]addr,input[7:0]dev_addr,din,
 output wire init_done,output reg rd_done=0,wr_done=0,output reg[7:0]dout=0,output wire dout_valid,
 output wire[2:0]i2c_address,output wire i2c_write,output wire[7:0]i2c_writedata,
 input[7:0]i2c_readdata,input i2c_waitrequest,output wire i2c_chipselect);
assign init_done=1;assign dout_valid=rd_done;assign i2c_address=0;assign i2c_write=0;assign i2c_writedata=0;assign i2c_chipselect=0;
reg[2:0]delay=0;reg writing=0;reg[15:0]saved;
always @(posedge clk)begin
 rd_done<=0;wr_done<=0;
 if(!rst_n)delay<=0;
 else if(rd_en || wr_en)begin
  if(delay!=0)$fatal(1,"Overlapping I2C transaction");
  delay<=3;writing<=wr_en;saved<=addr;
 end else if(delay!=0)begin
  delay<=delay-1'b1;
  if(delay==1)begin
   if(writing)wr_done<=1;
   else begin rd_done<=1;dout<=(saved==16'h3107)?8'hcd:(saved==16'h3108)?8'h6b:(saved==16'h0100)?8'h00:saved[7:0];end
  end
 end
end
endmodule
module i2c_master_top(
 input arst_i,scl_pad_i,sda_pad_i,wb_clk_i,wb_rst_i,wb_stb_i,wb_we_i,
 input[2:0]wb_adr_i,input[7:0]wb_dat_i,
 output wire scl_pad_o,scl_padoen_o,sda_pad_o,sda_padoen_o,wb_ack_o,wb_inta_o,
 output wire[7:0]wb_dat_o);
assign scl_pad_o=1;assign scl_padoen_o=1;assign sda_pad_o=1;assign sda_padoen_o=1;assign wb_ack_o=0;assign wb_inta_o=0;assign wb_dat_o=0;
endmodule
