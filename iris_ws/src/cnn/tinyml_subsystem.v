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
module tinyml_subsystem #(parameter ENABLE_STYLE_DEMO=0,ENABLE_STREAM_CNN=0,STREAM_DILATION=2) (
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

    // Style demo control plane: APB0 at 0xf8100000.
    output wire [15:0] style_paddr,
    output wire style_psel, style_penable, style_pwrite,
    output wire [31:0] style_pwdata,
    input wire [31:0] style_prdata,

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
    wire [31:0] accel_obs [0:8];

    // unused APB / SPI / I2C peripherals: respond idle so firmware probes
    // (e.g. a stale DMA driver) cannot hang the APB bus.
    wire [15:0] apb0_paddr, apb1_paddr;
    wire        apb0_psel, apb0_penable, apb0_pwrite, apb1_psel, apb1_penable, apb1_pwrite;
    wire [31:0] apb0_pwdata, apb1_pwdata;
    wire [31:0] apb0_prdata = ENABLE_STYLE_DEMO ? style_prdata : 32'd0;
    assign style_paddr=apb0_paddr;
    assign style_psel=apb0_psel;
    assign style_penable=apb0_penable;
    assign style_pwrite=apb0_pwrite;
    assign style_pwdata=apb0_pwdata;
    // APB1 = shared-DDR arbiter observation bank (see module ports).
    // PADDR is the full APB address; slave base is 0xf8110000.
    reg  [31:0] apb1_prdata;
    always @* begin
        case (apb1_paddr[6:2])
            5'd0:  apb1_prdata = {24'd0, dbg_arb_state};
            5'd1:  apb1_prdata = dbg_arb_ar_addr;
            5'd2:  apb1_prdata = {24'd0, dbg_arb_ar_len};
            5'd3:  apb1_prdata = {27'd0, dbg_arb_ar_size, dbg_arb_ar_burst};
            5'd4:  apb1_prdata = dbg_arb_aw_addr;
            5'd5:  apb1_prdata = {24'd0, dbg_arb_aw_len};
            5'd6:  apb1_prdata = {16'd0, dbg_arb_rd_cnt};
            5'd7:  apb1_prdata = {16'd0, dbg_arb_wr_cnt};
            5'd8:  apb1_prdata = {16'd0, dbg_arb_wr_err_cnt, dbg_arb_rd_err_cnt};
            5'd9:  apb1_prdata = {30'd0, dbg_arb_rresp};
            5'd10: apb1_prdata = {30'd0, dbg_arb_bresp};
            5'd11: apb1_prdata = dbg_arb_cpu_ar_addr;
            5'd12: apb1_prdata = dbg_arb_fb_ar_addr;
            5'd13: apb1_prdata = dbg_arb_cpu_aw_addr;
            5'd14: apb1_prdata = dbg_arb_fb_aw_addr;
            5'd15: apb1_prdata = {dbg_arb_fb_rd_cnt, dbg_arb_cpu_rd_cnt};
            5'd16: apb1_prdata = {dbg_arb_fb_rd_cnt, dbg_arb_cpu_rd_cnt};
            5'd17: apb1_prdata = {16'd0, dbg_arb_m_ar_cnt};
            5'd18: apb1_prdata = {16'd0, dbg_arb_m_aw_cnt};
            5'd19: apb1_prdata = accel_obs[0];
            5'd20: apb1_prdata = accel_obs[1];
            5'd21: apb1_prdata = accel_obs[2];
            5'd22: apb1_prdata = accel_obs[3];
            5'd23: apb1_prdata = accel_obs[4];
            5'd24: apb1_prdata = accel_obs[5];
            5'd25: apb1_prdata = accel_obs[6];
            5'd26: apb1_prdata = accel_obs[7];
            5'd27: apb1_prdata = accel_obs[8];
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
    // Sapphire emits narrow single-beat CPU transactions. The DDR controller
    // is fed native 128-bit line transactions: preserve WSTRB for byte stores
    // and return the complete line for Sapphire's upstream lane selector.
    wire native_line = soc_arw_len == 0 && soc_arw_size < 3'd4;
    wire [31:0] memory_addr = native_line ? {soc_arw_addr[31:4],4'b0} : soc_arw_addr;
    wire [2:0] memory_size = native_line ? 3'd4 : soc_arw_size;
    assign cpu_awaddr  = soc_arw_write ? memory_addr   : 32'h0;
    assign cpu_awlen   = soc_arw_write ? soc_arw_len   : 8'h0;
    assign cpu_awsize  = soc_arw_write ? memory_size   : 3'h0;
    assign cpu_awburst = soc_arw_write ? soc_arw_burst : 2'h0;
    assign cpu_awlock  = soc_arw_write ? soc_arw_lock  : 1'b0;
    assign cpu_awvalid = soc_arw_write ? soc_arw_valid : 1'b0;

    assign cpu_arid    = ~soc_arw_write ? soc_arw_id    : 8'h0;
    assign cpu_araddr  = ~soc_arw_write ? memory_addr  : 32'h0;
    assign cpu_arlen   = ~soc_arw_write ? soc_arw_len   : 8'h0;
    assign cpu_arsize  = ~soc_arw_write ? memory_size  : 3'h0;
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
    // Ownership switches only at a transaction boundary. CPU CI execution is
    // serialized; the DMA counters also cover vendor operations with a delayed
    // memory response after their command reply.
    wire resize_busy, resize_cmd_ready, resize_rsp_valid;
    wire cnn_busy,cnn_cmd_ready,cnn_rsp_valid,cnn_irq;
    wire [31:0] cnn_outputs_0,cn_araddr,cn_awaddr;
    wire [7:0] cn_arlen,cn_awlen;
    wire [127:0] cn_wdata;
    wire cn_arvalid,cn_rready,cn_awvalid,cn_wvalid,cn_wlast,cn_bready;
    wire cnn_space=ci_function_id[9:4]==6'h24;
    wire user_busy=resize_busy || cnn_busy;
    wire [31:0] resize_outputs_0;
    wire v_cmd_ready, v_rsp_valid;
    wire [31:0] v_outputs_0;
    wire v_awvalid, v_awready, v_awlock, v_wvalid, v_wready, v_wlast;
    wire v_bvalid, v_bready, v_arvalid, v_arready, v_arlock, v_rvalid, v_rready;
    // The shared DDR arbiter broadcasts RLAST/RRESP even for other owners.
    // Hide those unrelated/stale sidebands from the vendor cache and DMA.
    wire v_rlast = v_rvalid && acc_rlast;
    wire [1:0] v_rresp = v_rvalid ? acc_rresp : 2'b00;
    wire [1:0] v_bresp = v_bvalid ? acc_bresp : 2'b00;
    wire [31:0] v_awaddr, v_araddr;
    wire [7:0] v_awlen, v_arlen;
    wire [2:0] v_awsize, v_arsize;
    wire [1:0] v_awburst, v_arburst;
    wire [127:0] v_wdata;
    wire [15:0] v_wstrb;
    reg [7:0] vendor_reads, vendor_writes;
    always @(posedge clk or posedge io_systemReset) begin
        if (io_systemReset) begin vendor_reads<=0; vendor_writes<=0; end
        else begin
            case ({v_arvalid && v_arready, v_rvalid && v_rready && acc_rlast})
                2'b10: vendor_reads <= vendor_reads + 1'b1;
                2'b01: vendor_reads <= vendor_reads - 1'b1;
                default: begin end
            endcase
            case ({v_awvalid && v_awready, v_bvalid && v_bready})
                2'b10: vendor_writes <= vendor_writes + 1'b1;
                2'b01: vendor_writes <= vendor_writes - 1'b1;
                default: begin end
            endcase
        end
    end
    wire vendor_idle = vendor_reads==0 && vendor_writes==0 &&
                       !v_arvalid && !v_awvalid && !v_wvalid && !v_rsp_valid;
    assign ci_cmd_ready = ENABLE_STREAM_CNN && cnn_space ? cnn_cmd_ready :
                          ci_function_id[9] ? resize_cmd_ready : (v_cmd_ready && !user_busy);
    assign ci_rsp_valid = cnn_rsp_valid || resize_rsp_valid || v_rsp_valid;
    assign ci_outputs_0 = cnn_rsp_valid ? cnn_outputs_0 : resize_rsp_valid ? resize_outputs_0 : v_outputs_0;
    wire [31:0] rz_araddr, rz_awaddr;
    wire [127:0] rz_wdata;
    wire rz_arvalid, rz_rready, rz_awvalid, rz_wvalid, rz_bready;
    iris_resize2x u_resize (
        .clk(clk), .rst_n(~io_systemReset), .vendor_idle(vendor_idle && !cnn_busy),
        .cmd_valid(ci_cmd_valid && ci_function_id[9] && !(ENABLE_STREAM_CNN && cnn_space)), .cmd_function_id(ci_function_id),
        .cmd_inputs_0(ci_inputs_0), .cmd_inputs_1(ci_inputs_1), .cmd_ready(resize_cmd_ready),
        .rsp_valid(resize_rsp_valid), .rsp_outputs_0(resize_outputs_0), .rsp_ready(ci_rsp_ready),
        .busy(resize_busy), .araddr(rz_araddr), .arvalid(rz_arvalid),
        .arready(acc_arready && resize_busy), .rdata(acc_rdata),
        .rvalid(acc_rvalid && resize_busy), .rready(rz_rready), .rlast(acc_rlast), .rresp(acc_rresp),
        .awaddr(rz_awaddr), .awvalid(rz_awvalid), .awready(acc_awready && resize_busy),
        .wdata(rz_wdata), .wvalid(rz_wvalid), .wready(acc_wready && resize_busy),
        .bvalid(acc_bvalid && resize_busy), .bready(rz_bready), .bresp(acc_bresp)
    );
    assign acc_awvalid = cnn_busy ? cn_awvalid : resize_busy ? rz_awvalid : v_awvalid;
    assign acc_awaddr = cnn_busy ? cn_awaddr : resize_busy ? rz_awaddr : v_awaddr;
    assign acc_awlen = cnn_busy ? cn_awlen : resize_busy ? 8'd0 : v_awlen;
    assign acc_awsize = user_busy ? 3'd4 : v_awsize;
    assign acc_awburst = user_busy ? 2'b01 : v_awburst;
    assign acc_awlock = user_busy ? 1'b0 : v_awlock;
    assign acc_wdata = cnn_busy ? cn_wdata : resize_busy ? rz_wdata : v_wdata;
    assign acc_wstrb = user_busy ? 16'hffff : v_wstrb;
    assign acc_wlast = cnn_busy ? cn_wlast : resize_busy ? 1'b1 : v_wlast;
    assign acc_wvalid = cnn_busy ? cn_wvalid : resize_busy ? rz_wvalid : v_wvalid;
    assign acc_bready = cnn_busy ? cn_bready : resize_busy ? rz_bready : v_bready;
    assign acc_arvalid = cnn_busy ? cn_arvalid : resize_busy ? rz_arvalid : v_arvalid;
    assign acc_araddr = cnn_busy ? cn_araddr : resize_busy ? rz_araddr : v_araddr;
    assign acc_arlen = cnn_busy ? cn_arlen : resize_busy ? 8'd0 : v_arlen;
    assign acc_arsize = user_busy ? 3'd4 : v_arsize;
    assign acc_arburst = user_busy ? 2'b01 : v_arburst;
    assign acc_arlock = user_busy ? 1'b0 : v_arlock;
    assign acc_rready = cnn_busy ? cn_rready : resize_busy ? rz_rready : v_rready;
    assign v_awready = acc_awready && !user_busy;
    assign v_wready = acc_wready && !user_busy;
    assign v_bvalid = acc_bvalid && !user_busy;
    assign v_arready = acc_arready && !user_busy;
    assign v_rvalid = acc_rvalid && !user_busy;

    generate if(ENABLE_STREAM_CNN)begin:g_cnn
        iris_stream_cnn #(.DILATION(STREAM_DILATION))u_cnn(
            .clk(clk),.rst_n(~io_systemReset),.vendor_idle(vendor_idle && !resize_busy),
            .cmd_valid(ci_cmd_valid && cnn_space),.cmd_function_id(ci_function_id),
            .cmd_inputs_0(ci_inputs_0),.cmd_inputs_1(ci_inputs_1),.cmd_ready(cnn_cmd_ready),
            .rsp_valid(cnn_rsp_valid),.rsp_outputs_0(cnn_outputs_0),.rsp_ready(ci_rsp_ready),.busy(cnn_busy),.irq(cnn_irq),
            .araddr(cn_araddr),.arlen(cn_arlen),.arvalid(cn_arvalid),.arready(acc_arready && cnn_busy),
            .rdata(acc_rdata),.rvalid(acc_rvalid && cnn_busy),.rready(cn_rready),.rlast(acc_rlast),.rresp(acc_rresp),
            .awaddr(cn_awaddr),.awlen(cn_awlen),.awvalid(cn_awvalid),.awready(acc_awready && cnn_busy),
            .wdata(cn_wdata),.wvalid(cn_wvalid),.wready(acc_wready && cnn_busy),.wlast(cn_wlast),
            .bvalid(acc_bvalid && cnn_busy),.bready(cn_bready),.bresp(acc_bresp));
    end else begin:g_no_cnn
        assign cnn_busy=0;assign cnn_cmd_ready=1;assign cnn_rsp_valid=0;assign cnn_irq=0;
        assign cnn_outputs_0=32'hffffffff;assign cn_araddr=0;assign cn_arlen=0;assign cn_arvalid=0;assign cn_rready=0;
        assign cn_awaddr=0;assign cn_awlen=0;assign cn_awvalid=0;assign cn_wdata=0;assign cn_wvalid=0;assign cn_wlast=0;assign cn_bready=0;
    end endgenerate

    generate if(!ENABLE_STREAM_CNN)begin:g_vendor
    tinyml_accelerator_channels #(
        .AXI_DW_M (128)
    ) u_accel_channels (
        .clk             (clk),
        .reset           (io_systemReset),
        .cmd_valid       (ci_cmd_valid && !ci_function_id[9] && !user_busy),
        .cmd_function_id (ci_function_id),
        .cmd_inputs_0    (ci_inputs_0),
        .cmd_inputs_1    (ci_inputs_1),
        .cmd_ready       (v_cmd_ready),
        .cmd_int         (ci_cmd_int),
        .rsp_valid       (v_rsp_valid),
        .rsp_outputs_0   (v_outputs_0),
        .rsp_ready       (ci_rsp_ready && !resize_rsp_valid),
        .m_axi_clk       (clk),
        .m_axi_rstn      (~io_systemReset),
        .m_axi_awvalid   (v_awvalid),
        .m_axi_awaddr    (v_awaddr),
        .m_axi_awlen     (v_awlen),
        .m_axi_awsize    (v_awsize),
        .m_axi_awburst   (v_awburst),
        .m_axi_awprot    (),
        .m_axi_awlock    (v_awlock),
        .m_axi_awcache   (),
        .m_axi_awready   (v_awready),
        .m_axi_wdata     (v_wdata),
        .m_axi_wstrb     (v_wstrb),
        .m_axi_wlast     (v_wlast),
        .m_axi_wvalid    (v_wvalid),
        .m_axi_wready    (v_wready),
        .m_axi_bresp     (v_bresp),
        .m_axi_bvalid    (v_bvalid),
        .m_axi_bready    (v_bready),
        .m_axi_arvalid   (v_arvalid),
        .m_axi_araddr    (v_araddr),
        .m_axi_arlen     (v_arlen),
        .m_axi_arsize    (v_arsize),
        .m_axi_arburst   (v_arburst),
        .m_axi_arprot    (),
        .m_axi_arlock    (v_arlock),
        .m_axi_arcache   (),
        .m_axi_arready   (v_arready),
        .m_axi_rvalid    (v_rvalid),
        .m_axi_rdata     (acc_rdata),
        .m_axi_rlast     (v_rlast),
        .m_axi_rresp     (v_rresp),
        .m_axi_rready    (v_rready)
    );
    end else begin:g_no_vendor
        reg unsupported_rsp;
        always @(posedge clk or posedge io_systemReset)begin
            if(io_systemReset)unsupported_rsp<=0;
            else begin
                if(unsupported_rsp && ci_rsp_ready)unsupported_rsp<=0;
                if(ci_cmd_valid && ci_cmd_ready && !ci_function_id[9])unsupported_rsp<=1;
            end
        end
        assign v_cmd_ready=!unsupported_rsp || ci_rsp_ready;
        assign v_rsp_valid=unsupported_rsp;assign v_outputs_0=32'hffffffff;assign ci_cmd_int=cnn_irq;
        assign v_awvalid=0;assign v_awaddr=0;assign v_awlen=0;assign v_awsize=0;assign v_awburst=0;assign v_awlock=0;
        assign v_wdata=0;assign v_wstrb=0;assign v_wlast=0;assign v_wvalid=0;assign v_bready=1;
        assign v_arvalid=0;assign v_araddr=0;assign v_arlen=0;assign v_arsize=0;assign v_arburst=0;assign v_arlock=0;assign v_rready=1;
    end endgenerate

    // tinyml_accelerator_channels leaves m_axi_awid/m_axi_arid undriven in
    // single-channel mode (the vendor top never consumed them).  The arbiter
    // routes responses by grant, not by ID, so fixed unique IDs are enough;
    // they only ride along for the controller's echo.
    assign acc_awid = 8'h20;
    assign acc_arid = 8'h20;

    // "Layer finished" pulse from the accelerator becomes userInterruptA
    // (the SoC port above samples this net directly).
    assign accel_cmd_int = ci_cmd_int;

    // Passive observation only: never acknowledges an interrupt or changes DMA.
    iris_accel_observer u_accel_observer (
        .clk(clk), .rst_n(~io_systemReset),
        .cmd_fire(ci_cmd_valid && ci_cmd_ready && !ci_function_id[9]),
        .function_id(ci_function_id), .inputs_0(ci_inputs_0), .inputs_1(ci_inputs_1),
        .irq(ci_cmd_int),
        .araddr(v_araddr), .arvalid(v_arvalid), .arready(v_arready),
        .rvalid(v_rvalid), .rready(v_rready), .rlast(v_rlast),
        .awaddr(v_awaddr), .awvalid(v_awvalid), .awready(v_awready),
        .wvalid(v_wvalid), .wready(v_wready), .wlast(v_wlast),
        .bvalid(v_bvalid), .bready(v_bready),
        .obs0(accel_obs[0]), .obs1(accel_obs[1]), .obs2(accel_obs[2]),
        .obs3(accel_obs[3]), .obs4(accel_obs[4]), .obs5(accel_obs[5]),
        .obs6(accel_obs[6]), .obs7(accel_obs[7]), .obs8(accel_obs[8])
    );

endmodule

// Counters wrap at 65536. CI IDs are decoded from the official driver opcodes:
// Conv start/ack share 0x10 (inputs_0=1/2); Add start/ack = 0x29/0x2f.
module iris_accel_observer (
    input wire clk, rst_n, cmd_fire, irq,
    input wire [9:0] function_id,
    input wire [31:0] inputs_0, inputs_1, araddr, awaddr,
    input wire arvalid, arready, rvalid, rready, rlast,
    input wire awvalid, awready, wvalid, wready, wlast, bvalid, bready,
    output wire [31:0] obs0, obs1, obs2, obs3, obs4, obs5, obs6, obs7, obs8
);
    reg irq_q;
    reg [9:0] last_function;
    reg [15:0] irq_count, start_count, ack_count;
    reg [15:0] ar_count, aw_count, r_count, b_count;
    reg [31:0] last_ar, last_aw, last_input0, last_input1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_q<=0; last_function<=0;
            irq_count<=0; start_count<=0; ack_count<=0;
            ar_count<=0; aw_count<=0; r_count<=0; b_count<=0;
            last_ar<=0; last_aw<=0; last_input0<=0; last_input1<=0;
        end else begin
            irq_q<=irq;
            if (irq && !irq_q) irq_count<=irq_count+1'b1;
            if (cmd_fire) begin
                last_function<=function_id; last_input0<=inputs_0; last_input1<=inputs_1;
                if ((function_id==10'h010 && inputs_0==1) || function_id==10'h029) start_count<=start_count+1'b1;
                if ((function_id==10'h010 && inputs_0==2) || function_id==10'h02f) ack_count<=ack_count+1'b1;
            end
            if (arvalid && arready) begin ar_count<=ar_count+1'b1; last_ar<=araddr; end
            if (awvalid && awready) begin aw_count<=aw_count+1'b1; last_aw<=awaddr; end
            if (rvalid && rready && rlast) r_count<=r_count+1'b1;
            if (bvalid && bready) b_count<=b_count+1'b1;
        end
    end
    assign obs0={irq_count,5'd0,irq,last_function};
    assign obs1={ar_count-r_count,aw_count-b_count};
    assign obs2=last_ar;
    assign obs3=last_aw;
    assign obs4={r_count,b_count};
    assign obs5={start_count,ack_count};
    assign obs6=last_input0;
    assign obs7=last_input1;
    assign obs8={20'd0,arvalid,arready,rvalid,rready,rlast,awvalid,awready,wvalid,wready,wlast,bvalid,bready};
endmodule
