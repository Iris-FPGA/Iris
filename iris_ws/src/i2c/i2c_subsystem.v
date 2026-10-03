//=====================================================================
// I2C subsystem (generic, device-agnostic)
//
//   Three requesters share one I2C master core:
//     - auto : ROM sequence engine + 16-bit-reg/8-bit-data byte layer
//              (used for power-on device initialisation)
//     - cpu  : memory-mapped register port for an external CPU / RISC-V
//              (bus agnostic; later adapt to APB / AXI4-Lite)
//     - ae   : auto-exposure register writes (ae_req/ae_wr_en), takes
//              the byte layer only after boot; gates the ID check loop
//
//   mode = 0 -> auto (ROM), cpu port ignored
//   mode = 1 -> cpu, auto engine held idle
//
//   The device-specific register table is supplied through the ROM port
//   (rom_addr / rom_data), keeping this module reusable for other chips.
//=====================================================================

module i2c_subsystem #(
    parameter DATA_LENGTH        = 165,
    parameter I2C_REG_ADDR_WIDTH = 16,
    parameter I2C_DATA_WIDTH     = 8,
    parameter I2C_DEVICE_ADDR    = 8'h60,
    parameter CLK_DIV            = 16'h0020,
    parameter ROM_ADDR_WIDTH     = $clog2(DATA_LENGTH)
)(
    input  wire                             clk,
    input  wire                             rst_n,

    // I2C pads
    input  wire                             scl_pad_i,
    output wire                             scl_pad_o,
    output wire                             scl_padoen_o,
    input  wire                             sda_pad_i,
    output wire                             sda_pad_o,
    output wire                             sda_padoen_o,

    // control / status
    input  wire                             start,      // run the auto ROM table
    input  wire                             mode,       // 0 = auto, 1 = cpu
    output wire                             busy,
    output wire                             done,
    output wire                             sensor_id_ok,  // read back 0xCD6B
    output reg [255:0] sensor_readback, // published only after one complete 32-register scan
    output wire [15:0]                      sensor_dout,   // last two read bytes

    // external device ROM
    output wire [ROM_ADDR_WIDTH-1:0]                    rom_addr,
    input  wire [I2C_REG_ADDR_WIDTH+I2C_DATA_WIDTH:0]   rom_data,

    // CPU register port (bus agnostic, maps the 8 I2C core registers)
    input  wire [2:0]                       cpu_addr,
    input  wire [7:0]                       cpu_wdata,
    input  wire                             cpu_we,
    input  wire                             cpu_stb,
    output wire [7:0]                       cpu_rdata,
    output wire                             cpu_ack,

    // AE register-write requester (3rd master, post-boot; writes one
    // register per ae_wr_en pulse while ae_req is held high)
    input  wire                             ae_req,
    input  wire                             ae_wr_en,
    input  wire [I2C_REG_ADDR_WIDTH-1:0]    ae_addr,
    input  wire [I2C_DATA_WIDTH-1:0]        ae_data,
    output wire                             ae_done   // wr_done while ae_req
);

// ---------------------------------------------------------------- auto path
wire        init_done;
wire        wr_done, rd_done;
wire        wr_en, rd_en;
wire [I2C_REG_ADDR_WIDTH-1:0] addr;
wire [I2C_DATA_WIDTH-1:0]     set_data;
wire [I2C_DATA_WIDTH-1:0]     get_data;
wire                          get_valid;
wire [7:0]                    dev_addr;

wire [2:0]  i2c_addr;
wire        i2c_waitrequest;
wire [7:0]  i2c_readdata;
wire [7:0]  i2c_writedata;
wire        i2c_read;
wire        i2c_write;
wire        i2c_chipselect;

wire        seq_done;

// run control: once the table completes, latch done and stop
reg         run;
reg         done_r;

always @(posedge clk or negedge rst_n)
begin
    if (~rst_n) begin
        run    <= 1'b0;
        done_r <= 1'b0;
    end else begin
        if (mode) begin
            run    <= 1'b0;
        end else if (seq_done) begin
            run    <= 1'b0;
            done_r <= 1'b1;
        end else if (start && !done_r) begin
            run    <= 1'b1;
        end
    end
end

//---------------------------------------------------------------------
// sensor ID read-back check (device-agnostic: reads two 8-bit registers
// at 0x3107/0x3108 after the write table completes and compares 0xCD6B)
//---------------------------------------------------------------------
localparam ID_IDLE=0, ID_ISSUE=1, ID_WAIT=2;
reg id_req,id_rd_en;
reg [1:0] id_state;
reg [4:0] id_index;
reg [15:0] id_addr;
reg [7:0] id_byte0,id_byte1;
reg sensor_id_ok_r;
reg [255:0] readback_work;
assign sensor_id_ok=sensor_id_ok_r;
assign sensor_dout={id_byte1,id_byte0};
function [15:0] readback_addr;
 input [4:0] n;
 begin
  case(n)
   0:readback_addr=16'h3107;1:readback_addr=16'h3108;
   24:readback_addr=16'h301f;25:readback_addr=16'h3018;
   26:readback_addr=16'h3031;27:readback_addr=16'h3037;
   28:readback_addr=16'h3e00;29:readback_addr=16'h3e01;30:readback_addr=16'h3e02;
   31:readback_addr=16'h0100;
   default:begin
    if(n<10)readback_addr=16'h3208+{11'd0,n}-16'd2;
    else if(n<14)readback_addr=16'h3210+{11'd0,n}-16'd10;
    else if(n<19)readback_addr=16'h36e9+{11'd0,n}-16'd14;
    else readback_addr=16'h37f9+{11'd0,n}-16'd19;
   end
  endcase
 end
endfunction
// Diagnostic reads own the byte engine while busy. AE asserts its request
// then waits busy=0; the scanner never starts a new pass with AE pending.
wire [I2C_REG_ADDR_WIDTH-1:0] blk_addr=id_req?id_addr:ae_req?ae_addr:addr;
wire blk_rd_en=id_req?id_rd_en:rd_en;
wire blk_wr_en=ae_req?ae_wr_en:wr_en;
wire [I2C_DATA_WIDTH-1:0] blk_din=ae_req?ae_data:set_data;
assign busy=run|id_req;
assign done=done_r;
assign ae_done=wr_done & ae_req;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  id_req<=0;id_rd_en<=0;id_state<=ID_IDLE;id_index<=0;id_addr<=0;
  id_byte0<=0;id_byte1<=0;sensor_id_ok_r<=0;readback_work<=0;sensor_readback<=0;
 end else begin
  id_rd_en<=0;
  case(id_state)
   ID_IDLE:if(done_r && !mode && !ae_req)begin
    id_req<=1;id_index<=0;id_addr<=readback_addr(0);id_rd_en<=1;id_state<=ID_ISSUE;
   end
   ID_ISSUE:id_state<=ID_WAIT;
   ID_WAIT:if(rd_done)begin
    readback_work[255-id_index*8-:8]<=get_data;
    if(id_index==0)id_byte0<=get_data;
    if(id_index==1)begin id_byte1<=get_data;sensor_id_ok_r<=(id_byte0==8'hcd && get_data==8'h6b);end
    if(id_index==31)begin
     sensor_readback<={readback_work[255:8],get_data};id_req<=0;id_state<=ID_IDLE;
    end else begin
     id_index<=id_index+1'b1;id_addr<=readback_addr(id_index+1'b1);id_rd_en<=1;id_state<=ID_ISSUE;
    end
   end
   default:id_state<=ID_IDLE;
  endcase
 end
end

i2c_master_reg_set #(
    .DATA_LENGTH        (DATA_LENGTH),
    .I2C_REG_ADDR_WIDTH (I2C_REG_ADDR_WIDTH),
    .I2C_DATA_WIDTH     (I2C_DATA_WIDTH),
    .I2C_DEVICE_ADDR    (I2C_DEVICE_ADDR)
) u_reg_set (
    .clk        (clk),
    .rst_n      (rst_n),
    .init_done  (init_done),
    .rd_done    (rd_done),
    .wr_done    (wr_done),
    .run        (run),
    .wr_en      (wr_en),
    .rd_en      (rd_en),
    .addr       (addr),
    .dout       (set_data),
    .dev_addr   (dev_addr),
    .rom_addr   (rom_addr),
    .rom_data   (rom_data),
    .done       (seq_done)
);

i2c_16addr_8data #(
    .CLK_DIV    (CLK_DIV),
    .IRQ_EN     (1'b0),
    .I2C_EN     (1'b1)
) u_i2c_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
        .init_done       (init_done),
        .rd_done         (rd_done),
        .wr_done         (wr_done),
        .wr_en           (blk_wr_en),
        .rd_en           (blk_rd_en),
        .addr            (blk_addr),
        .dev_addr        (dev_addr),
        .din             (blk_din),
    .dout            (get_data),
    .dout_valid      (get_valid),
    .i2c_address     (i2c_addr),
    .i2c_write       (i2c_write),
    .i2c_readdata    (i2c_readdata),
    .i2c_writedata   (i2c_writedata),
    .i2c_chipselect  (i2c_chipselect),
    .i2c_waitrequest (i2c_waitrequest)
);

// ------------------------------------------------------------------ wb mux
wire [2:0] wb_adr   = mode ? cpu_addr  : i2c_addr;
wire [7:0] wb_dat_i = mode ? cpu_wdata : i2c_writedata;
wire       wb_we    = mode ? cpu_we    : i2c_write;
wire       wb_stb   = mode ? cpu_stb   : i2c_chipselect;
wire [7:0] wb_dat_o;
wire       wb_ack;

assign i2c_waitrequest = wb_ack;
assign i2c_readdata    = wb_dat_o;
assign cpu_ack         = wb_ack;
assign cpu_rdata       = wb_dat_o;

i2c_master_top u_i2c_master_top (
    .arst_i         (1'b1),
    .scl_pad_i      (scl_pad_i),
    .scl_pad_o      (scl_pad_o),
    .scl_padoen_o   (scl_padoen_o),
    .sda_pad_i      (sda_pad_i),
    .sda_pad_o      (sda_pad_o),
    .sda_padoen_o   (sda_padoen_o),
    .wb_ack_o       (wb_ack),
    .wb_adr_i       (wb_adr),
    .wb_clk_i       (clk),
    .wb_dat_i       (wb_dat_i),
    .wb_dat_o       (wb_dat_o),
    .wb_rst_i       (~rst_n),
    .wb_stb_i       (wb_stb),
    .wb_we_i        (wb_we),
    .wb_inta_o      ()
);

endmodule
