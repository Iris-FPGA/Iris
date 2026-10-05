//=====================================================================
// tinyml_subsystem: Sapphire RISC-V SoC + Efinix TinyML accelerator,
// integrated for Iris (Ti60F225_DemoBoard_v4, shared DDR3).
//
// Reference: tinyml_hello_world/Ti60F225_tinyml_hello_world/tinyml_soc.v
// (Efinix-Inc/tinyml @ 96886fa).  Differences for Iris:
//   * system / peripheral / memory clocks are all core_clk (100 MHz) so the
//     subsystem is single-clock; efx_soc Frequency/PeriFrequency were set to
//     100 to match (SYSTEM_CLINT_HZ = 100000000).
//   * HyperRAM + axi_interconnect_beta + axi_full_to_half_duplex are removed.
//     The SoC io_ddrA half-duplex port is converted to a full AXI4 master and
//     exported; arbitration against the video frame buffer lives in top.v
//     (axi_ddr_arbiter) and the existing axi_atype_bridge feeds efx_ddr3_axi.
//   * APB slave 0/1 are tied off (the vendor DMA IP is not instantiated yet);
//     userInterruptB stays 0.  userInterruptA = accelerator cmd_int.
//   * The board UART pin is shared: rxd fans out to both UARTs, txd is muxed
//     in top.v (KEY3 held at power-on selects the CPU console).
//
// Reset contract: rst_n must already be gated so that the SoC and its AXI
// master only come out of reset after DDR calibration completes
// (docs/TinyML_移植进度与待办.md #2).
//=====================================================================
module tinyml_subsystem (
    input  wire        clk,             // core_clk 100 MHz (system/peri/memory)
    input  wire        rst_n,           // active-low, gated by DDR cal (see above)

    // board console UART (async pin level)
    output wire        uart_txd,
    input  wire        uart_rxd_async,

    // JTAG_USER1 tap (bound by iris_ws.peri.xml jtag_info)
    input  wire        jtag_inst1_TCK,
    input  wire        jtag_inst1_TDI,
    output wire        jtag_inst1_TDO,
    input  wire        jtag_inst1_SEL,
    input  wire        jtag_inst1_CAPTURE,
    input  wire        jtag_inst1_SHIFT,
    input  wire        jtag_inst1_UPDATE,
    input  wire        jtag_inst1_RESET,

    // AXI4 master: CPU memory port (io_ddrA, converted from half-duplex arw)
    output wire [7:0]  cpu_awid,
    output wire [31:0] cpu_awaddr,
    output wire [7:0]  cpu_awlen,
    output wire [2:0]  cpu_awsize,
    output wire [1:0]  cpu_awburst,
    output wire        cpu_awlock,
    output wire        cpu_awvalid,
    input  wire        cpu_awready,
    output wire [127:0] cpu_wdata,
    output wire [15:0] cpu_wstrb,
    output wire        cpu_wlast,
    output wire        cpu_wvalid,
    input  wire        cpu_wready,
    input  wire [7:0]  cpu_bid,
    input  wire [1:0]  cpu_bresp,
    input  wire        cpu_bvalid,
    output wire        cpu_bready,
    output wire [7:0]  cpu_arid,
    output wire [31:0] cpu_araddr,
    output wire [7:0]  cpu_arlen,
    output wire [2:0]  cpu_arsize,
    output wire [1:0]  cpu_arburst,
    output wire        cpu_arlock,
    output wire        cpu_arvalid,
    input  wire        cpu_arready,
    input  wire [127:0] cpu_rdata,
    input  wire [7:0]  cpu_rid,
    input  wire [1:0]  cpu_rresp,
    input  wire        cpu_rlast,
    input  wire        cpu_rvalid,
    output wire        cpu_rready,

    // AXI4 master: TinyML accelerator (single channel passthrough)
    output wire [7:0]  acc_awid,
    output wire [31:0] acc_awaddr,
    output wire [7:0]  acc_awlen,
    output wire [2:0]  acc_awsize,
    output wire [1:0]  acc_awburst,
    output wire        acc_awlock,
    output wire        acc_awvalid,
    input  wire        acc_awready,
    output wire [127:0] acc_wdata,
    output wire [15:0] acc_wstrb,
    output wire        acc_wlast,
    output wire        acc_wvalid,
    input  wire        acc_wready,
    input  wire [7:0]  acc_bid,
    input  wire [1:0]  acc_bresp,
    input  wire        acc_bvalid,
    output wire        acc_bready,
    output wire [7:0]  acc_arid,
    output wire [31:0] acc_araddr,
    output wire [7:0]  acc_arlen,
    output wire [2:0]  acc_arsize,
    output wire [1:0]  acc_arburst,
    output wire        acc_arlock,
    output wire        acc_arvalid,
    input  wire        acc_arready,
    input  wire [127:0] acc_rdata,
    input  wire [7:0]  acc_rid,
    input  wire [1:0]  acc_rresp,
    input  wire        acc_rlast,
    input  wire        acc_rvalid,
    output wire        acc_rready,

    // status / interrupts
    output wire        subsystem_rst,    // io_systemReset, active high
    output wire        accel_cmd_int,    // accelerator "layer done" -> userInterruptA

    // bring-up observation from the shared-DDR arbiter, readable through
    // APB slave 1 (0xf8110000) - the debug module's SBA can read it while
    // the CPU is halted
    input  wire [31:0] dbg_arb_ar_addr,
    input  wire [7:0]  dbg_arb_ar_len,
    input  wire [2:0]  dbg_arb_ar_size,
    input  wire [1:0]  dbg_arb_ar_burst,
    input  wire [31:0] dbg_arb_aw_addr,
    input  wire [7:0]  dbg_arb_aw_len,
    input  wire [1:0]  dbg_arb_bresp,
    input  wire [1:0]  dbg_arb_rresp,
    input  wire [15:0] dbg_arb_rd_cnt,
    input  wire [15:0] dbg_arb_wr_cnt,
    input  wire [7:0]  dbg_arb_rd_err_cnt,
    input  wire [7:0]  dbg_arb_wr_err_cnt,
    input  wire [7:0]  dbg_arb_state,
    input  wire [31:0] dbg_arb_cpu_ar_addr,
    input  wire [31:0] dbg_arb_fb_ar_addr,
    input  wire [31:0] dbg_arb_cpu_aw_addr,
    input  wire [31:0] dbg_arb_fb_aw_addr,
    input  wire [15:0] dbg_arb_cpu_rd_cnt,
    input  wire [15:0] dbg_arb_fb_rd_cnt,
    input  wire [15:0] dbg_arb_m_ar_cnt,
    input  wire [15:0] dbg_arb_m_aw_cnt
);

    //-----------------------------------------------------------------
    // Sapphire SoC (generated: ip/SapphireSoc, efx_soc 3.4.1)
    //-----------------------------------------------------------------
    wire        io_systemReset;
    wire        io_memoryReset;
    wire        io_peripheralReset;
    wire        soc_async_reset = ~rst_n;

    assign subsystem_rst = io_systemReset;

    // io_ddrA half-duplex shared address channel
    wire        soc_arw_valid;
    wire        soc_arw_ready;
    wire        soc_arw_write;
    wire [31:0] soc_arw_addr;
    wire [7:0]  soc_arw_id;
    wire [7:0]  soc_arw_len;
    wire [2:0]  soc_arw_size;
    wire [1:0]  soc_arw_burst;
    wire        soc_arw_lock;
    wire [3:0]  soc_arw_cache;
    wire [2:0]  soc_arw_prot;
    wire [3:0]  soc_arw_qos;
    wire [3:0]  soc_arw_region;

    wire        soc_w_valid, soc_w_ready, soc_w_last;
    wire [127:0] soc_w_data;
    wire [15:0]  soc_w_strb;
    wire [7:0]   soc_w_id;
    wire        soc_b_valid, soc_b_ready;
    wire [7:0]  soc_b_id;
    wire [1:0]  soc_b_resp;
    wire        soc_r_valid, soc_r_ready, soc_r_last;
    wire [127:0] soc_r_data;
    wire [7:0]   soc_r_id;
    wire [1:0]   soc_r_resp;

    // custom instruction (CPU <-> accelerator)
    wire        ci_cmd_valid, ci_cmd_ready, ci_rsp_valid, ci_rsp_ready, ci_cmd_int;
    wire [9:0]  ci_function_id;
    wire [31:0] ci_inputs_0, ci_inputs_1, ci_outputs_0;

    // unused APB / SPI / I2C peripherals: respond idle so firmware probes
    // (e.g. a stale DMA driver) cannot hang the APB bus.
    wire [15:0] apb0_paddr, apb1_paddr;
    wire        apb0_psel, apb0_penable, apb0_pwrite, apb1_psel, apb1_penable, apb1_pwrite;
    wire [31:0] apb0_pwdata, apb1_pwdata;
    wire [31:0] apb0_prdata = 32'd0;
    // APB1 = shared-DDR arbiter observation bank (see module ports).
    // PADDR is the full APB address; slave base is 0xf8110000.
    reg  [31:0] apb1_prdata;
    always @* begin
        case (apb1_paddr[6:2])
            4'd0:  apb1_prdata = {24'd0, dbg_arb_state};
            4'd1:  apb1_prdata = dbg_arb_ar_addr;
            4'd2:  apb1_prdata = {24'd0, dbg_arb_ar_len};
            4'd3:  apb1_prdata = {27'd0, dbg_arb_ar_size, dbg_arb_ar_burst};
            4'd4:  apb1_prdata = dbg_arb_aw_addr;
            4'd5:  apb1_prdata = {24'd0, dbg_arb_aw_len};
            4'd6:  apb1_prdata = {16'd0, dbg_arb_rd_cnt};
            4'd7:  apb1_prdata = {16'd0, dbg_arb_wr_cnt};
            4'd8:  apb1_prdata = {16'd0, dbg_arb_wr_err_cnt, dbg_arb_rd_err_cnt};
            4'd9:  apb1_prdata = {30'd0, dbg_arb_rresp};
            4'd10: apb1_prdata = {30'd0, dbg_arb_bresp};
            4'd11: apb1_prdata = dbg_arb_cpu_ar_addr;
            4'd12: apb1_prdata = dbg_arb_fb_ar_addr;
            4'd13: apb1_prdata = dbg_arb_cpu_aw_addr;
            4'd14: apb1_prdata = dbg_arb_fb_aw_addr;
            4'd15: apb1_prdata = {dbg_arb_fb_rd_cnt, dbg_arb_cpu_rd_cnt};
            4'd16: apb1_prdata = {dbg_arb_fb_rd_cnt, dbg_arb_cpu_rd_cnt};
            4'd17: apb1_prdata = {16'd0, dbg_arb_m_ar_cnt};
            4'd18: apb1_prdata = {16'd0, dbg_arb_m_aw_cnt};
            default: apb1_prdata = 32'hDEAD_0000 | {27'd0, apb1_paddr[6:2]};
        endcase
    end

    // UART RX: pin is asynchronous to clk (board GPIO has no input FF in the
    // official style); 2-FF synchronise before handing it to the SoC.
    reg [1:0] uart_rxd_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) uart_rxd_sync <= 2'b11;
        else        uart_rxd_sync <= {uart_rxd_sync[0], uart_rxd_async};
    end
    wire uart_rxd = uart_rxd_sync[1];

    SapphireSoc u_soc (
        .io_systemClk            (clk),
        .io_peripheralClk        (clk),
        .io_memoryClk            (clk),
        .io_asyncReset           (soc_async_reset),
        .io_systemReset          (io_systemReset),
        .io_memoryReset          (io_memoryReset),
        .io_peripheralReset      (io_peripheralReset),

        .system_uart_0_io_txd    (uart_txd),
        .system_uart_0_io_rxd    (uart_rxd),

        .jtagCtrl_tck            (jtag_inst1_TCK),
        .jtagCtrl_tdi            (jtag_inst1_TDI),
        .jtagCtrl_tdo            (jtag_inst1_TDO),
        .jtagCtrl_enable         (jtag_inst1_SEL),
        .jtagCtrl_capture        (jtag_inst1_CAPTURE),
        .jtagCtrl_shift          (jtag_inst1_SHIFT),
        .jtagCtrl_update         (jtag_inst1_UPDATE),
        .jtagCtrl_reset          (jtag_inst1_RESET),

        // half-duplex memory port
        .io_ddrA_arw_valid       (soc_arw_valid),
        .io_ddrA_arw_ready       (soc_arw_ready),
        .io_ddrA_arw_payload_addr  (soc_arw_addr),
        .io_ddrA_arw_payload_id    (soc_arw_id),
        .io_ddrA_arw_payload_region(soc_arw_region),
        .io_ddrA_arw_payload_len   (soc_arw_len),
        .io_ddrA_arw_payload_size  (soc_arw_size),
        .io_ddrA_arw_payload_burst (soc_arw_burst),
        .io_ddrA_arw_payload_lock  (soc_arw_lock),
        .io_ddrA_arw_payload_cache (soc_arw_cache),
        .io_ddrA_arw_payload_qos   (soc_arw_qos),
        .io_ddrA_arw_payload_prot  (soc_arw_prot),
        .io_ddrA_arw_payload_write (soc_arw_write),
        .io_ddrA_w_payload_id    (soc_w_id),
        .io_ddrA_w_payload_data  (soc_w_data),
        .io_ddrA_w_payload_strb  (soc_w_strb),
        .io_ddrA_w_payload_last  (soc_w_last),
        .io_ddrA_w_valid         (soc_w_valid),
        .io_ddrA_w_ready         (soc_w_ready),
        .io_ddrA_b_payload_id    (soc_b_id),
        .io_ddrA_b_payload_resp  (soc_b_resp),
        .io_ddrA_b_valid         (soc_b_valid),
        .io_ddrA_b_ready         (soc_b_ready),
        .io_ddrA_r_payload_data  (soc_r_data),
        .io_ddrA_r_payload_id    (soc_r_id),
        .io_ddrA_r_payload_resp  (soc_r_resp),
        .io_ddrA_r_payload_last  (soc_r_last),
        .io_ddrA_r_valid         (soc_r_valid),
        .io_ddrA_r_ready         (soc_r_ready),

        // APB slave 0/1: no device attached yet (vendor DMA IP later)
        .io_apbSlave_0_PADDR     (apb0_paddr),
        .io_apbSlave_0_PSEL      (apb0_psel),
        .io_apbSlave_0_PENABLE   (apb0_penable),
        .io_apbSlave_0_PWRITE    (apb0_pwrite),
        .io_apbSlave_0_PWDATA    (apb0_pwdata),
        .io_apbSlave_0_PRDATA    (apb0_prdata),
        .io_apbSlave_0_PREADY    (1'b1),
        .io_apbSlave_0_PSLVERROR (1'b0),
        .io_apbSlave_1_PADDR     (apb1_paddr),
        .io_apbSlave_1_PSEL      (apb1_psel),
        .io_apbSlave_1_PENABLE   (apb1_penable),
        .io_apbSlave_1_PWRITE    (apb1_pwrite),
        .io_apbSlave_1_PWDATA    (apb1_pwdata),
        .io_apbSlave_1_PRDATA    (apb1_prdata),
        .io_apbSlave_1_PREADY    (1'b1),
        .io_apbSlave_1_PSLVERROR (1'b0),

        .userInterruptA          (accel_cmd_int),
        .userInterruptB          (1'b0),

        // SPI0 / I2C0: read inputs idle, transmit side unused
        .system_spi_0_io_sclk_write        (),
        .system_spi_0_io_ss                (),
        .system_spi_0_io_data_0_write      (),
        .system_spi_0_io_data_0_writeEnable(),
        .system_spi_0_io_data_0_read       (1'b0),
        .system_spi_0_io_data_1_write      (),
        .system_spi_0_io_data_1_writeEnable(),
        .system_spi_0_io_data_1_read       (1'b0),
        .system_spi_0_io_data_2_write      (),
        .system_spi_0_io_data_2_writeEnable(),
        .system_spi_0_io_data_2_read       (1'b0),
        .system_spi_0_io_data_3_write      (),
        .system_spi_0_io_data_3_writeEnable(),
        .system_spi_0_io_data_3_read       (1'b0),
        .system_i2c_0_io_scl_write         (),
        .system_i2c_0_io_scl_read          (1'b1),
        .system_i2c_0_io_sda_write         (),
        .system_i2c_0_io_sda_read          (1'b1),

        .cpu0_customInstruction_cmd_valid       (ci_cmd_valid),
        .cpu0_customInstruction_cmd_ready       (ci_cmd_ready),
        .cpu0_customInstruction_function_id     (ci_function_id),
        .cpu0_customInstruction_inputs_0        (ci_inputs_0),
        .cpu0_customInstruction_inputs_1        (ci_inputs_1),
        .cpu0_customInstruction_rsp_valid       (ci_rsp_valid),
        .cpu0_customInstruction_rsp_ready       (ci_rsp_ready),
        .cpu0_customInstruction_outputs_0       (ci_outputs_0)
    );

    // verilator lint_off UNUSED
    wire _unused_ok = &{1'b0, soc_arw_cache, soc_arw_prot, soc_arw_qos,
                        soc_arw_region, soc_w_id, soc_b_id, soc_r_id,
                        soc_r_resp, soc_b_resp, apb0_paddr, apb1_paddr,
                        apb0_psel, apb0_penable, apb0_pwrite, apb0_pwdata,
                        apb1_psel, apb1_penable, apb1_pwrite, apb1_pwdata,
                        io_memoryReset, io_peripheralReset, 1'b0};
    // verilator lint_on UNUSED

    //-----------------------------------------------------------------
    // half-duplex arw -> full AXI4 (same conversion as official
    // tinyml_soc.v s0 mapping)
    //-----------------------------------------------------------------
    assign cpu_awid    = soc_arw_write ? soc_arw_id    : 8'h0;
    assign cpu_awaddr  = soc_arw_write ? soc_arw_addr  : 32'h0;
    assign cpu_awlen   = soc_arw_write ? soc_arw_len   : 8'h0;
    assign cpu_awsize  = soc_arw_write ? soc_arw_size  : 3'h0;
    assign cpu_awburst = soc_arw_write ? soc_arw_burst : 2'h0;
    assign cpu_awlock  = soc_arw_write ? soc_arw_lock  : 1'b0;
    assign cpu_awvalid = soc_arw_write ? soc_arw_valid : 1'b0;

    assign cpu_arid    = ~soc_arw_write ? soc_arw_id    : 8'h0;
    assign cpu_araddr  = ~soc_arw_write ? soc_arw_addr  : 32'h0;
    assign cpu_arlen   = ~soc_arw_write ? soc_arw_len   : 8'h0;
    assign cpu_arsize  = ~soc_arw_write ? soc_arw_size  : 3'h0;
    assign cpu_arburst = ~soc_arw_write ? soc_arw_burst : 2'h0;
    assign cpu_arlock  = ~soc_arw_write ? soc_arw_lock  : 1'b0;
    assign cpu_arvalid = ~soc_arw_write ? soc_arw_valid : 1'b0;

    assign soc_arw_ready = soc_arw_write ? cpu_awready : cpu_arready;

    assign cpu_wdata = soc_w_data;
    assign cpu_wstrb = soc_w_strb;
    assign cpu_wlast = soc_w_last;
    assign cpu_wvalid = soc_w_valid;
    assign soc_w_ready = cpu_wready;

    assign soc_b_valid = cpu_bvalid;
    assign soc_b_id    = cpu_bid;
    assign soc_b_resp  = cpu_bresp;
    assign cpu_bready  = soc_b_ready;

    assign soc_r_valid = cpu_rvalid;
    assign soc_r_data  = cpu_rdata;
    assign soc_r_id    = cpu_rid;
    assign soc_r_resp  = cpu_rresp;
    assign soc_r_last  = cpu_rlast;
    assign cpu_rready  = soc_r_ready;

    //-----------------------------------------------------------------
    // TinyML accelerator: custom instruction + AXI master
    // (function IDs with bit9=0 are the vendor accelerator space; the
    //  bit9=1 user space is reserved for the Iris resize accelerator)
    //-----------------------------------------------------------------
    tinyml_accelerator_channels #(
        .AXI_DW_M (128)
    ) u_accel_channels (
        .clk             (clk),
        .reset           (io_systemReset),
        .cmd_valid       (ci_cmd_valid),
        .cmd_function_id (ci_function_id),
        .cmd_inputs_0    (ci_inputs_0),
        .cmd_inputs_1    (ci_inputs_1),
        .cmd_ready       (ci_cmd_ready),
        .cmd_int         (ci_cmd_int),
        .rsp_valid       (ci_rsp_valid),
        .rsp_outputs_0   (ci_outputs_0),
        .rsp_ready       (ci_rsp_ready),
        .m_axi_clk       (clk),
        .m_axi_rstn      (~io_systemReset),
        .m_axi_awvalid   (acc_awvalid),
        .m_axi_awaddr    (acc_awaddr),
        .m_axi_awlen     (acc_awlen),
        .m_axi_awsize    (acc_awsize),
        .m_axi_awburst   (acc_awburst),
        .m_axi_awprot    (),
        .m_axi_awlock    (acc_awlock),
        .m_axi_awcache   (),
        .m_axi_awready   (acc_awready),
        .m_axi_wdata     (acc_wdata),
        .m_axi_wstrb     (acc_wstrb),
        .m_axi_wlast     (acc_wlast),
        .m_axi_wvalid    (acc_wvalid),
        .m_axi_wready    (acc_wready),
        .m_axi_bresp     (acc_bresp),
        .m_axi_bvalid    (acc_bvalid),
        .m_axi_bready    (acc_bready),
        .m_axi_arvalid   (acc_arvalid),
        .m_axi_araddr    (acc_araddr),
        .m_axi_arlen     (acc_arlen),
        .m_axi_arsize    (acc_arsize),
        .m_axi_arburst   (acc_arburst),
        .m_axi_arprot    (),
        .m_axi_arlock    (acc_arlock),
        .m_axi_arcache   (),
        .m_axi_arready   (acc_arready),
        .m_axi_rvalid    (acc_rvalid),
        .m_axi_rdata     (acc_rdata),
        .m_axi_rlast     (acc_rlast),
        .m_axi_rresp     (acc_rresp),
        .m_axi_rready    (acc_rready)
    );

    // tinyml_accelerator_channels leaves m_axi_awid/m_axi_arid undriven in
    // single-channel mode (the vendor top never consumed them).  The arbiter
    // routes responses by grant, not by ID, so fixed unique IDs are enough;
    // they only ride along for the controller's echo.
    assign acc_awid = 8'h20;
    assign acc_arid = 8'h20;

    // "Layer finished" pulse from the accelerator becomes userInterruptA
    // (the SoC port above samples this net directly).
    assign accel_cmd_int = ci_cmd_int;

endmodule
