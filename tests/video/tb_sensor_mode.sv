`timescale 1ns/1ps
module tb_sensor_mode;
reg clk=0,rst=0,run=0;
always #5 clk=~clk;
wire[7:0]index;
wire[24:0]rom;
wire[15:0]addr;
wire[7:0]data,dev;
wire wr,rd,done;
reg wr_done=0;
reg [7:0] registers[0:65535];
integer transactions=0,delay=0;
sc431hai_i2c_rom romdut(.clock(clk),.addr_ptr(index),.rdata_out(rom));
i2c_master_reg_set #(.DATA_LENGTH(165)) seq(.clk(clk),.rst_n(rst),.init_done(1'b1),.run(run),.rd_done(1'b0),.wr_done(wr_done),.wr_en(wr),.rd_en(rd),.addr(addr),.dout(data),.dev_addr(dev),.rom_addr(index),.rom_data(rom),.done(done));
always @(posedge clk)begin
 wr_done<=0;
 if(wr)begin
  if(delay!=0)$fatal(1,"ROM overlapping writes");
  if(transactions==0 && {addr,data}!==24'h010000)$fatal(1,"ROM must start stream off");
  if(addr==16'h0100 && data==1 && transactions!=164)$fatal(1,"Stream started before timing/window loaded");
  if(transactions==164 && {addr,data}!==24'h010001)$fatal(1,"Last entry must start stream");
  registers[addr]<=data;transactions<=transactions+1;delay<=4;
 end else if(delay!=0)begin
  delay<=delay-1;
  if(delay==1)wr_done<=1;
 end
 if(rd)$fatal(1,"Unexpected ROM read");
end
initial begin
 repeat(4)@(negedge clk);rst=1;run=1;
 wait(done);@(negedge clk);
 if(transactions!=165)$fatal(1,"ROM write count %0d",transactions);
 if({registers[16'h3208],registers[16'h3209]}!==16'd1920 || {registers[16'h320a],registers[16'h320b]}!==16'd1080)$fatal(1,"Native 1080 window");
 if({registers[16'h320c],registers[16'h320d]}!==16'd1622 || {registers[16'h320e],registers[16'h320f]}!==16'd1150)$fatal(1,"Frame timing");
 if({registers[16'h3e00][3:0],registers[16'h3e01],registers[16'h3e02][7:4]}!==16'd512)$fatal(1,"Exposure units");
 if({registers[16'h36e9],registers[16'h36ea],registers[16'h36eb],registers[16'h36ec],registers[16'h36ed]}!==40'h44230c5518 ||
    {registers[16'h37f9],registers[16'h37fa],registers[16'h37fb],registers[16'h37fc],registers[16'h37fd]}!==40'h442344201c)$fatal(1,"Published sensor clock values");
 if(registers[16'h3250]!==0)$fatal(1,"HDR incorrectly enabled");
 $display("PASS sensor mode contract: exact 165 I2C writes, 1080 window/exposure, published clock values, linear mode, stream on last");$finish;
end
initial begin #100000;$fatal(1,"ROM sequence timeout");end
endmodule
