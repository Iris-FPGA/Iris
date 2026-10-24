// Exercise the checked-in Sapphire SPI controller against a Flash mode-0
// timing oracle. Three peripheral clocks preserve MISO across late sampling.
`timescale 1ns/1ps
module tb_style_boot_spi;
reg clk=0;always #5 clk=~clk;
reg reset=1,valid=0,kind=0,rd=0,wr=0;reg[7:0]data=0;
wire ready,rsp;wire[7:0]value;wire sclk,cs;reg miso=1;reg[2:0]delay=7;
always @(posedge clk)delay<={delay[1:0],miso};
parameter LATENCY=3;
wire sampled=LATENCY==0?miso:delay[LATENCY-1];
TopLevel dut(.io_config_kind_cpol(1'b0),.io_config_kind_cpha(1'b0),.io_config_sclkToggle(12'd9),.io_config_mod(2'd0),.io_config_ss_activeHigh(1'b0),.io_config_ss_setup(12'd4),.io_config_ss_hold(12'd4),.io_config_ss_disable(12'd4),.io_cmd_valid(valid),.io_cmd_ready(ready),.io_cmd_payload_kind(kind),.io_cmd_payload_read(rd),.io_cmd_payload_write(wr),.io_cmd_payload_data(data),.io_rsp_valid(rsp),.io_rsp_payload_data(value),.io_spi_sclk_write(sclk),.io_spi_data_0_writeEnable(),.io_spi_data_0_read(1'b0),.io_spi_data_0_write(),.io_spi_data_1_writeEnable(),.io_spi_data_1_read(sampled),.io_spi_data_1_write(),.io_spi_data_2_writeEnable(),.io_spi_data_2_read(1'b0),.io_spi_data_2_write(),.io_spi_data_3_writeEnable(),.io_spi_data_3_read(1'b0),.io_spi_data_3_write(),.io_spi_ss(cs),.io_peripheralClk(clk),.peripheralCd_logic_outputReset(reset));
integer edges=0;reg[31:0]answer=32'hef601700;integer at=31;
always @(negedge cs) begin edges=0;at=31;miso=1;end
always @(posedge sclk)if(!cs)edges=edges+1;
always @(negedge sclk)if(!cs && edges>=8) begin
 if(at>=0)miso<=answer[at];else miso<=1;at=at-1;
end
reg[23:0]got=0;integer replies=0;
always @(posedge clk)if(rsp)begin got<={got[15:0],value};replies<=replies+1;end
task command(input k,input r,input w,input[7:0]d);begin
 @(negedge clk);valid=1;kind=k;rd=r;wr=w;data=d;
 do begin @(posedge clk);end while(!ready);
 @(negedge clk);valid=0;
end endtask
initial begin
 repeat(5)@(negedge clk);reset=0;command(1,0,0,8'h80);command(0,0,1,8'h9f);
 command(0,1,0,0);command(0,1,0,0);command(0,1,0,0);
 repeat(10)@(negedge clk);$display("LATENCY=%0d got=%h replies=%0d",LATENCY,got,replies);
 if(LATENCY==3 && got!==24'hef6017)$fatal(1,"JEDEC sample mismatch");
 if(LATENCY==0 && got!==24'hdec02e)$fatal(1,"direct-input negative control did not reproduce one-bit shift");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
