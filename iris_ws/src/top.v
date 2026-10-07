//=====================================================================
// L0 merged top: official CSI->frame buffer->debayer->HDMI path.
//   MIPI RAW10 -> sensor_clipper -> frame_buffer (Bayer mosaic in DDR3) ->
//   debayer (display domain) -> RGB888 -> TMDS/HDMI 1080p.
//=====================================================================

module top #(
    // Original camera diagnostic configuration defaults to its periodic log.
    // The style project selects 0 through Efinity top-params and uses the CPU
    // console; retain the legacy implementation for diagnostic builds.
    parameter ENABLE_STYLE_DEMO = 0,
    parameter ENABLE_LEGACY_UART_LOG = 1
)
(
    ////////////////////////    CLOCK     ////////////////////////
    input                       gpio_clk_27m,     // 27MHz board clock (UART + LED)

    ////////////////////////    DDR3 clocks    ////////////////////////
    input                       core_clk,          // 100MHz system / AXI clock
    input                       core_pll_locked,
    input                       ddr_pll_locked,
    input                       ddr_tdqss_clk,     // 400MHz
    input                       ddr_tac_clk,       // 400MHz (dyn phase)
    input                       ddr_twd_clk,       // 400MHz
    input                       ddr_core_clk,      // 200MHz controller core

    ////////////////////////    DDR3 memory    ////////////////////////
    output                      ddr_reset,
    output                      ddr_cs,
    output                      ddr_ras,
    output                      ddr_cas,
    output                      ddr_we,
    output                      ddr_cke,
    output [15:0]               ddr_addr,
    output [2:0]                ddr_ba,
    output                      ddr_odt,
    output [1:0]                o_ddr_dm_hi,
    output [1:0]                o_ddr_dm_lo,
    input  [1:0]                i_ddr_dqs_hi,
    input  [1:0]                i_ddr_dqs_lo,
    input  [1:0]                i_ddr_dqs_n_hi,
    input  [1:0]                i_ddr_dqs_n_lo,
    output [1:0]                o_ddr_dqs_hi,
    output [1:0]                o_ddr_dqs_lo,
    output [1:0]                o_ddr_dqs_oe,
    output [1:0]                o_ddr_dqs_n_oe,
    input  [15:0]               i_ddr_dq_hi,
    input  [15:0]               i_ddr_dq_lo,
    output [15:0]               o_ddr_dq_hi,
    output [15:0]               o_ddr_dq_lo,
    output [15:0]               o_ddr_dq_oe,

    ////////////////////////    DDR3 PLL calibration   ////////////////////////
    (* syn_peri_port = 0 *) output [2:0] pll_shift,
    (* syn_peri_port = 0 *) output [4:0] pll_shift_sel,
    (* syn_peri_port = 0 *) output         pll_shift_ena,

    ////////////////////////    UART      ////////////////////////
    input                       rxd,
    output                      txd,

    ////////////////////////    LED       ////////////////////////
    output [3:0]                led,

    ////////////////////////    KEYS      ////////////////////////
    input  [3:0]                key_i,     // active-low, pull-up (KEY0..KEY3)

    ////////////////////////    HDMI TX   ////////////////////////
    input                       hdmi_tx_locked,
    input                       hdmi_tx_slow_clk,
    input                       hdmi_tx_half_clk,
    output [9:0]                tmds_data0_o,
    output [9:0]                tmds_data1_o,
    output [9:0]                tmds_data2_o,
    output [9:0]                tmds_clk_o,
    output                      tmds_data0_TX_OE,
    output                      tmds_data1_TX_OE,
    output                      tmds_data2_TX_OE,
    output                      tmds_clk_TX_OE,
    output                      tmds_data0_TX_RST,
    output                      tmds_data1_TX_RST,
    output                      tmds_data2_TX_RST,
    output                      tmds_clk_TX_RST,

    ////////////////////////    MIPI RX (J4 sensor)   ////////////////////////
    (* syn_peri_port = 0 *) input           mipi_clk,
    (* syn_peri_port = 0 *) input           mipi_pixel_clk,
    (* syn_peri_port = 0 *) input           mipi_pll_locked,

    (* syn_peri_port = 0 *) input           i_cam_ck_LP_P_IN,
    (* syn_peri_port = 0 *) input           i_cam_ck_LP_N_IN,
    (* syn_peri_port = 0 *) input           i_cam_ck_CLKOUT,
    (* syn_peri_port = 0 *) output          o_cam_ck_HS_ENA,
    (* syn_peri_port = 0 *) output          o_cam_ck_HS_TERM,

    (* syn_peri_port = 0 *) input  [7:0]    cam_d0_HS_IN,
    (* syn_peri_port = 0 *) input           cam_d0_LP_P_IN,
    (* syn_peri_port = 0 *) input           cam_d0_LP_N_IN,
    (* syn_peri_port = 0 *) input           cam_d0_FIFO_EMPTY,
    (* syn_peri_port = 0 *) output          cam_d0_FIFO_RD,
    (* syn_peri_port = 0 *) output          cam_d0_HS_ENA,
    (* syn_peri_port = 0 *) output          cam_d0_HS_TERM,
    (* syn_peri_port = 0 *) output          cam_d0_RST,

    (* syn_peri_port = 0 *) input  [7:0]    cam_d1_HS_IN,
    (* syn_peri_port = 0 *) input           cam_d1_LP_P_IN,
    (* syn_peri_port = 0 *) input           cam_d1_LP_N_IN,
    (* syn_peri_port = 0 *) input           cam_d1_FIFO_EMPTY,
    (* syn_peri_port = 0 *) output          cam_d1_FIFO_RD,
    (* syn_peri_port = 0 *) output          cam_d1_HS_ENA,
    (* syn_peri_port = 0 *) output          cam_d1_HS_TERM,
    (* syn_peri_port = 0 *) output          cam_d1_RST,

    (* syn_peri_port = 0 *) input  [7:0]    cam_d2_HS_IN,
    (* syn_peri_port = 0 *) input           cam_d2_LP_P_IN,
    (* syn_peri_port = 0 *) input           cam_d2_LP_N_IN,
    (* syn_peri_port = 0 *) input           cam_d2_FIFO_EMPTY,
    (* syn_peri_port = 0 *) output          cam_d2_FIFO_RD,
    (* syn_peri_port = 0 *) output          cam_d2_HS_ENA,
    (* syn_peri_port = 0 *) output          cam_d2_HS_TERM,
    (* syn_peri_port = 0 *) output          cam_d2_RST,

    (* syn_peri_port = 0 *) input  [7:0]    cam_d3_HS_IN,
    (* syn_peri_port = 0 *) input           cam_d3_LP_P_IN,
    (* syn_peri_port = 0 *) input           cam_d3_LP_N_IN,
    (* syn_peri_port = 0 *) input           cam_d3_FIFO_EMPTY,
    (* syn_peri_port = 0 *) output          cam_d3_FIFO_RD,
    (* syn_peri_port = 0 *) output          cam_d3_HS_ENA,
    (* syn_peri_port = 0 *) output          cam_d3_HS_TERM,
    (* syn_peri_port = 0 *) output          cam_d3_RST,

    ////////////////////////    Camera I2C / reset (J4)   ////////////////////////
    (* syn_peri_port = 0 *) input           io_cam_scl_IN,
    (* syn_peri_port = 0 *) output          io_cam_scl_OUT,
    (* syn_peri_port = 0 *) output          io_cam_scl_OE,
    (* syn_peri_port = 0 *) input           io_cam_sda_IN,
    (* syn_peri_port = 0 *) output          io_cam_sda_OUT,
    (* syn_peri_port = 0 *) output          io_cam_sda_OE,
    (* syn_peri_port = 0 *) output          o_cam_rst,

    ////////////////////////    JTAG_USER1 (Sapphire debug)  ////////////////////////
    input                       jtag_inst1_TCK,
    input                       jtag_inst1_TDI,
    output                      jtag_inst1_TDO,
    input                       jtag_inst1_SEL,
    input                       jtag_inst1_CAPTURE,
    input                       jtag_inst1_SHIFT,
    input                       jtag_inst1_UPDATE,
    input                       jtag_inst1_RESET
);

//=====================================================================
// MIPI CSI-2 RX (J4) + sensor frame clip
//=====================================================================
wire        mipi_data_valid;
wire [63:0] mipi_pixel_data;
wire [3:0]  mipi_pixel_per_clk;
wire [5:0]  mipi_datatype;
wire [15:0] mipi_word_count;
wire        mipi_hsync;
wire        mipi_vsync;
wire        mipi_irq;

wire        ddr_cal_done;
wire        ddr_cal_pass;
wire [7:0]  ddr_cal_fail_log;

wire        video_rst_n = mipi_pll_locked & core_pll_locked & ddr_pll_locked & hdmi_tx_locked;

mipi_rx u_mipi_rx
(
    .clk                    (mipi_clk),
    .clk_pixel              (mipi_pixel_clk),
    .reset_n                (mipi_pll_locked),

    .i_cam_ck_LP_P_IN       (i_cam_ck_LP_P_IN),
    .i_cam_ck_LP_N_IN       (i_cam_ck_LP_N_IN),
    .i_cam_ck_CLKOUT        (i_cam_ck_CLKOUT),
    .o_cam_ck_HS_ENA        (o_cam_ck_HS_ENA),
    .o_cam_ck_HS_TERM       (o_cam_ck_HS_TERM),

    .cam_d0_HS_IN           (cam_d0_HS_IN),
    .cam_d0_LP_P_IN         (cam_d0_LP_P_IN),
    .cam_d0_LP_N_IN         (cam_d0_LP_N_IN),
    .cam_d0_FIFO_EMPTY      (cam_d0_FIFO_EMPTY),
    .cam_d0_FIFO_RD         (cam_d0_FIFO_RD),
    .cam_d0_HS_ENA          (cam_d0_HS_ENA),
    .cam_d0_HS_TERM         (cam_d0_HS_TERM),
    .cam_d0_RST             (cam_d0_RST),

    .cam_d1_HS_IN           (cam_d1_HS_IN),
    .cam_d1_LP_P_IN         (cam_d1_LP_P_IN),
    .cam_d1_LP_N_IN         (cam_d1_LP_N_IN),
    .cam_d1_FIFO_EMPTY      (cam_d1_FIFO_EMPTY),
    .cam_d1_FIFO_RD         (cam_d1_FIFO_RD),
    .cam_d1_HS_ENA          (cam_d1_HS_ENA),
    .cam_d1_HS_TERM         (cam_d1_HS_TERM),
    .cam_d1_RST             (cam_d1_RST),

    .cam_d2_HS_IN           (cam_d2_HS_IN),
    .cam_d2_LP_P_IN         (cam_d2_LP_P_IN),
    .cam_d2_LP_N_IN         (cam_d2_LP_N_IN),
    .cam_d2_FIFO_EMPTY      (cam_d2_FIFO_EMPTY),
    .cam_d2_FIFO_RD         (cam_d2_FIFO_RD),
    .cam_d2_HS_ENA          (cam_d2_HS_ENA),
    .cam_d2_HS_TERM         (cam_d2_HS_TERM),
    .cam_d2_RST             (cam_d2_RST),

    .cam_d3_HS_IN           (cam_d3_HS_IN),
    .cam_d3_LP_P_IN         (cam_d3_LP_P_IN),
    .cam_d3_LP_N_IN         (cam_d3_LP_N_IN),
    .cam_d3_FIFO_EMPTY      (cam_d3_FIFO_EMPTY),
    .cam_d3_FIFO_RD         (cam_d3_FIFO_RD),
    .cam_d3_HS_ENA          (cam_d3_HS_ENA),
    .cam_d3_HS_TERM         (cam_d3_HS_TERM),
    .cam_d3_RST             (cam_d3_RST),

    .pixel_data_valid       (mipi_data_valid),
    .pixel_data             (mipi_pixel_data),
    .pixel_per_clk          (mipi_pixel_per_clk),
    .datatype               (mipi_datatype),
    .word_count             (mipi_word_count),
    .hsync                  (mipi_hsync),
    .vsync                  (mipi_vsync),
    .irq                    (mipi_irq)
);

wire clip_hs, clip_vs, clip_de;
wire [39:0] clip_dat;
sensor_clipper u_sensor_clipper (
    .clk    (mipi_pixel_clk),
    .i_hs   (mipi_hsync),
    .i_vs   (mipi_vsync),
    .i_de   (mipi_data_valid),
    .i_dat  (mipi_pixel_data[39:0]),
    .o_hs   (clip_hs),
    .o_vs   (clip_vs),
    .o_de   (clip_de),
    .o_dat  (clip_dat)
);

// 4 RAW10 pixels -> 4 x 8-bit Bayer mosaic (packed 32-bit)
// DDR emits the MSB first: preserve left-to-right P0,P1,P2,P3.
wire [31:0] fb_vin = {clip_dat[9:2], clip_dat[19:12],
                      clip_dat[29:22], clip_dat[39:32]};
wire        fb_ide = clip_de & clip_hs;
wire        fb_ihs = clip_hs;
wire        fb_ivs = clip_vs;

//=====================================================================
// DDR3 streaming frame buffer (Bayer mosaic), read side at 74.25MHz
//=====================================================================
// shared address channel: AXI bridge -> DDR3 soft controller
wire [7:0]  ddr_ax_aid;
wire [27:0] ddr_ax_aaddr;
wire [7:0]  ddr_ax_alen;
wire [2:0]  ddr_ax_asize;
wire [1:0]  ddr_ax_aburst;
wire [1:0]  ddr_ax_alock;
wire        ddr_ax_atype;
wire        ddr_ax_avalid;
wire        ddr_ax_aready;
wire [7:0]  ddr_ax_bid8;
wire [7:0]  ddr_ax_rid8;

wire [5:0]   fb_awid;
wire [27:0]  fb_awaddr;
wire [7:0]   fb_awlen;
wire [2:0]   fb_awsize;
wire [1:0]   fb_awburst;
wire [3:0]   fb_awcache;
wire [2:0]   fb_awprot;
wire         fb_awlock;
wire         fb_awvalid;
wire         fb_awready;

wire [5:0]   fb_arid;
wire [27:0]  fb_araddr;
wire [7:0]   fb_arlen;
wire [2:0]   fb_arsize;
wire [1:0]   fb_arburst;
wire         fb_arlock;
wire         fb_arvalid;
wire         fb_arready;

wire [127:0] fb_wdata;
wire [15:0]  fb_wstrb;
wire         fb_wlast;
wire         fb_wvalid;
wire         fb_wready;

wire [7:0]   arb_s0_rid;
wire [127:0] fb_rdata;
wire         fb_rlast;
wire         fb_rvalid;
wire         fb_rready;
wire [1:0]   fb_rresp;
wire [5:0]   fb_rid;
wire [7:0]   arb_s0_bid;
wire [5:0]   fb_bid;
wire         fb_bvalid;
wire         fb_bready;
wire [1:0]   fb_bresp;

wire [15:0]  fb_vout;
wire         fb_hs, fb_vs, fb_de;
wire         fb_wr_sw;

frame_buffer #(
    .I_VID_WIDTH    (32),
    .O_VID_WIDTH    (16),
    .AXI_DATA_WIDTH (128),
    .AXI_ADDR_WIDTH (28),
    .WR_FIFO_DEPTH  (1024),
    .RD_FIFO_DEPTH  (1024),
    .START_ADDR     (28'h0000000),
    .BURST_LEN      (8'd127),
    .FB_NUM         (3),
    .MAX_VID_WIDTH  (1920),
    .MAX_VID_HIGHT  (1080)
) u_frame_buffer (
    .axi_clk        (core_clk),
    .rst_n          (video_rst_n),

    .i_clk          (mipi_pixel_clk),
    .i_vs           (fb_ivs),
    .i_hs           (fb_ihs),
    .i_de           (fb_ide),
    .vin            (fb_vin),

    .o_clk          (hdmi_tx_half_clk),
    .o_hs           (fb_hs),
    .o_vs           (fb_vs),
    .o_de           (fb_de),
    .vout           (fb_vout),

    .H_FRONT_PORCH  (13'd44),
    .H_SYNC         (13'd22),
    .H_VALID        (13'd960),
    .H_BACK_PORCH   (13'd74),
    .V_FRONT_PORCH  (13'd4),
    .V_SYNC         (13'd5),
    .V_VALID        (13'd1080),
    .V_BACK_PORCH   (13'd36),

    .awid           (fb_awid),
    .awaddr         (fb_awaddr),
    .awlen          (fb_awlen),
    .awsize         (fb_awsize),
    .awburst        (fb_awburst),
    .awcache        (fb_awcache),
    .awprot         (fb_awprot),
    .awlock         (fb_awlock),
    .awvalid        (fb_awvalid),
    .awcobuf        (),
    .awapcmd        (),
    .awallstrb      (),
    .awqos          (),
    .awready        (fb_awready),

    .arid           (fb_arid),
    .araddr         (fb_araddr),
    .arlen          (fb_arlen),
    .arsize         (fb_arsize),
    .arburst        (fb_arburst),
    .arlock         (fb_arlock),
    .arvalid        (fb_arvalid),
    .arapcmd        (),
    .arqos          (),
    .arready        (fb_arready),

    .wdata          (fb_wdata),
    .wstrb          (fb_wstrb),
    .wlast          (fb_wlast),
    .wvalid         (fb_wvalid),
    .wready         (fb_wready),

    .rid            (fb_rid),
    .rdata          (fb_rdata),
    .rlast          (fb_rlast),
    .rvalid         (fb_rvalid),
    .rready         (fb_rready),
    .rresp          (fb_rresp),

    .bid            (fb_bid),
    .bvalid         (fb_bvalid),
    .bready         (fb_bready),

    .test_rd_fifo_rddata (),
    .test_wdata          (),
    .test_rdata          (),
    .test_BURST_LEN      (),
    .o_wr_sw             (fb_wr_sw)
);

assign fb_rid = arb_s0_rid[5:0];
assign fb_bid = arb_s0_bid[5:0];

//=====================================================================
// Display: debayer (74.25MHz, RGGB) then 2 -> 1 expansion to 148.5MHz
//=====================================================================
wire        dbg_vs_o, dbg_hs_o, dbg_de_o, dbg_val_o;
wire [47:0] dbg_rgb;
wire [9:0] awb_r_gain, awb_g_gain, awb_b_gain;
wire [7:0] black_r, black_g, black_b;
wire [31:0] wb_r, wb_g, wb_b;
wire [23:0] wb_pixels, colour_pixels;
wire wb_locked;
wire [31:0] awb_sum_r, awb_sum_g, awb_sum_b;
wire        awb_upd;

// Filtered one-shot white balance. Locked gains survive exposure/scene changes.
awb_stats u_awb_stats (
    .clk     (hdmi_tx_half_clk),
    .rst_n   (video_rst_n),
    .i_de    (dbg_de_o),
    .i_vs    (dbg_vs_o),
    .i_rgb   (dbg_rgb),
    .i_black_r(black_r), .i_black_g(black_g), .i_black_b(black_b),
    .o_wb_r(wb_r), .o_wb_g(wb_g), .o_wb_b(wb_b),
    .o_wb_pixels(wb_pixels), .o_pixels(colour_pixels),
    .o_sum_r (awb_sum_r),
    .o_sum_g (awb_sum_g),
    .o_sum_b (awb_sum_b),
    .o_upd   (awb_upd)
);

// Fixed colour coefficients are part of the FPGA image stored in Flash.
camera_colour_profile u_colour_profile (
 .r_gain(awb_r_gain),.g_gain(awb_g_gain),.b_gain(awb_b_gain),
 .black_r(black_r),.black_g(black_g),.black_b(black_b)
);
assign wb_locked=1'b1;

// stats -> AE (27 MHz): toggle handshake across clock domains.
// The sums only change at VS together with awb_upd, so they are
// quasi-static by the time the toggle is re-synchronised.
reg awb_upd_tgl;
always @(posedge hdmi_tx_half_clk or negedge video_rst_n) begin
    if (!video_rst_n)    awb_upd_tgl <= 1'b0;
    else if (awb_upd)    awb_upd_tgl <= ~awb_upd_tgl;
end

debayer_top_2to1 u_debayer (
    .in_pclk     (hdmi_tx_half_clk),
    .in_rstn     (video_rst_n),
    .raw_vs_i    (fb_vs),
    .raw_hs_i    (fb_hs),
    .raw_de_i    (fb_de),
    .raw_valid_i (fb_de),
    .raw_datax4_i(fb_vout),
    // Linear demosaic; per-channel display gains follow the stats tap.
    .i_r_gain    (3'd4),
    .i_g_gain    (3'd4),
    .i_b_gain    (3'd4),
    .rgb_vs_o    (dbg_vs_o),
    .rgb_hs_o    (dbg_hs_o),
    .rgb_de_o    (dbg_de_o),
    .rgb_valid_o (dbg_val_o),
    .rgb_datax2_o(dbg_rgb)
);

// phase-insensitive 2->1 expansion: async FIFO 74.25MHz -> 148.5MHz
wire display_hs, display_vs, display_de;
wire [47:0] display_rgb;
rgb_display_2px u_display_color (
    .clk(hdmi_tx_half_clk), .rst_n(video_rst_n),
    .i_hs(dbg_hs_o), .i_vs(dbg_vs_o), .i_de(dbg_de_o), .i_rgb(dbg_rgb),
    .i_r_gain(awb_r_gain), .i_g_gain(awb_g_gain), .i_b_gain(awb_b_gain),
    .i_black_r(black_r), .i_black_g(black_g), .i_black_b(black_b),
    .o_hs(display_hs), .o_vs(display_vs), .o_de(display_de), .o_rgb(display_rgb)
);
wire style_display_hs,style_display_vs,style_display_de;
wire [47:0] style_display_rgb;
wire [50:0] af_din = {style_display_hs, style_display_vs, style_display_de, style_display_rgb};
wire [50:0] af_dout;
wire        af_wfull, af_rempty;
reg         af_rinc;

afifo_simple #(.DW(51), .AW(3)) u_exp_fifo (
    .wclk   (hdmi_tx_half_clk),
    .wrst_n (video_rst_n),
    .winc   (1'b1),
    .din    (af_din),
    .wfull  (af_wfull),
    .rclk   (hdmi_tx_slow_clk),
    .rrst_n (video_rst_n),
    .rinc   (af_rinc),
    .dout   (af_dout),
    .rempty (af_rempty)
);

reg        rphase, rrun;
reg [50:0] cur;

always @(posedge hdmi_tx_slow_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        rphase  <= 1'b0;
        rrun    <= 1'b0;
        af_rinc <= 1'b0;
        cur     <= 51'd0;
    end else begin
        if (!rrun) begin
            af_rinc <= 1'b0;
            if (!af_rempty)
                rrun <= 1'b1;
        end else begin
            rphase  <= ~rphase;
            af_rinc <= ~rphase;
            if (rphase)
                cur <= af_dout;
        end
    end
end

wire [50:0] ew = rphase ? af_dout : cur;
wire [23:0] p_first  = ew[47:24];
wire [23:0] p_second = ew[23:0];
wire [23:0] exp_px   = rphase ? p_first : p_second;

reg [23:0] px_r;
reg        hs_r, vs_r, de_r;
always @(posedge hdmi_tx_slow_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        px_r <= 24'd0;
        hs_r <= 1'b0;
        vs_r <= 1'b0;
        de_r <= 1'b0;
    end else begin
        px_r <= exp_px;
        hs_r <= ew[50];
        vs_r <= ew[49];
        de_r <= ew[48];
    end
end

//=====================================================================
// Camera FPS: two 1 s gates on core_clk.
//   sens_fps : mipi_vsync edges = true sensor output rate  -> OSD left
//   wr_fps   : fb_wr_sw edges   = DDR frame-write rate     -> OSD right
//   The pair separates "sensor slow" from "write path dropping frames".
//=====================================================================
wire [7:0] sens_fps, wr_fps;
wire       sens_upd, wr_upd;

// mipi_vsync lives in mipi_pixel_clk; 2-FF sync into core_clk
reg [2:0] vs_sync;
always @(posedge core_clk or negedge video_rst_n) begin
    if (!video_rst_n) vs_sync <= 3'b000;
    else              vs_sync <= {vs_sync[1:0], mipi_vsync};
end

fps_counter #(
    .CLK_FREQ_HZ (100_000_000)
) u_fps_sensor (
    .clk         (core_clk),
    .rst_n       (video_rst_n),
    .frame_pulse (vs_sync[2]),
    .fps         (sens_fps),
    .upd_toggle  (sens_upd)
);

fps_counter #(
    .CLK_FREQ_HZ (100_000_000)
) u_fps_wr (
    .clk         (core_clk),
    .rst_n       (video_rst_n),
    .frame_pulse (fb_wr_sw),
    .fps         (wr_fps),
    .upd_toggle  (wr_upd)
);

//=====================================================================
// HDMI TX (our TMDS encoder)
//=====================================================================
localparam SWAP_RB   = 1'b0;    // 1: blue<-red, red<-blue
localparam SWAP_HSVS = 1'b0;    // 1: hsync<-vs, vsync<-hs

// AE debug bus (gpio_clk_27m domain, driven by u_ae_ctrl further down;
// declared early: consumed by the OSD overlay and the UART logger)
wire [1:0]  ae_state;
wire [11:0] ae_exp;
wire [3:0]  ae_gain;
wire [31:0] ae_sum;
wire [7:0]  ae_writes;
wire [7:0]  ae_touts;
// brightness readout for OSD/UART: mean luma ~ sum3/(4*NPX) = sum3>>23
// (NPX=1920*1080 -> 4*NPX = 8294400 ~ 2^23; sum3 < 2^31 so [30:23] fits)
wire [7:0]  ae_luma = ae_sum[30:23];
wire [7:0]  ae_target;         // exposure-compensation target (set by keys)
wire        key0_dn;          // KEY0 pressed: exposure comp down (darker)
wire        key1_up;          // KEY1 pressed: exposure comp up (brighter)

wire [23:0] px_osd;
wire [11:0] cam_width, cam_height, hdmi_width, hdmi_height;
wire cam_size_toggle, hdmi_size_toggle;
wire [7:0] hdmi_fps;
wire hdmi_upd;
video_size_meter #(.PIXELS_PER_CLOCK(4), .USE_HSYNC(1)) u_camera_size (
    .clk(mipi_pixel_clk), .rst_n(video_rst_n),
    .i_hs(fb_ihs), .i_vs(fb_ivs), .i_de(fb_ide),
    .o_width(cam_width), .o_height(cam_height), .o_toggle(cam_size_toggle)
);
video_size_meter #(.PIXELS_PER_CLOCK(1), .USE_HSYNC(0)) u_hdmi_size (
    .clk(hdmi_tx_slow_clk), .rst_n(video_rst_n),
    .i_hs(hs_r), .i_vs(vs_r), .i_de(de_r),
    .o_width(hdmi_width), .o_height(hdmi_height), .o_toggle(hdmi_size_toggle)
);
reg [2:0] hdmi_vs_sync;
always @(posedge core_clk or negedge video_rst_n) begin
    if (!video_rst_n) hdmi_vs_sync<=0;
    else hdmi_vs_sync<={hdmi_vs_sync[1:0],vs_r};
end
fps_counter #(.CLK_FREQ_HZ(100_000_000)) u_fps_hdmi (
    .clk(core_clk), .rst_n(video_rst_n), .frame_pulse(hdmi_vs_sync[2]),
    .fps(hdmi_fps), .upd_toggle(hdmi_upd)
);
osd_video_status u_video_status (
    .clk(hdmi_tx_slow_clk), .rst_n(video_rst_n),
    .i_hs(hs_r), .i_vs(vs_r), .i_de(de_r), .i_rgb(px_r),
    .i_cam_width(cam_width), .i_cam_height(cam_height), .i_cam_toggle(cam_size_toggle),
    .i_hdmi_width(hdmi_width), .i_hdmi_height(hdmi_height),
    .i_cam_fps(sens_fps), .i_wr_fps(wr_fps), .i_hdmi_fps(hdmi_fps),
    .i_wb_locked(wb_locked), .i_black_g(black_g),
    .i_cam_fps_upd(sens_upd), .i_wr_fps_upd(wr_upd), .i_hdmi_fps_upd(hdmi_upd),
    .o_rgb(px_osd)
);

// AE status line below the fps digits: E=xxx G=x S=x W=xx
wire [23:0] px_osd_ae;
osd_ae #(
    .X_START (16),
    .Y_START (48)
) u_osd_ae (
    .clk       (hdmi_tx_slow_clk),
    .rst_n     (video_rst_n),
    .i_hs      (hs_r),
    .i_vs      (vs_r),
    .i_de      (de_r),
    .i_rgb     (px_osd),
    .i_exp     (ae_exp),
    .i_gain    (ae_gain),
    .i_state   (ae_state),
    .i_writes  (ae_writes),
    .i_luma    (ae_luma),
    .i_target  (ae_target),
    .o_rgb     (px_osd_ae)
);

wire [9:0] tmds_data0;
wire [9:0] tmds_data1;
wire [9:0] tmds_data2;
wire [9:0] tmds_clk;

assign tmds_data0_TX_OE = 1'b1;
assign tmds_data1_TX_OE = 1'b1;
assign tmds_data2_TX_OE = 1'b1;
assign tmds_clk_TX_OE   = 1'b1;

assign tmds_data0_TX_RST = 1'b0;
assign tmds_data1_TX_RST = 1'b0;
assign tmds_data2_TX_RST = 1'b0;
assign tmds_clk_TX_RST   = 1'b0;

dvi_encoder dvi_encoder_m0
(
    .pixelclk   (hdmi_tx_slow_clk),
    .rstin      (~video_rst_n),
    .blue_din   (SWAP_RB   ? px_osd_ae[23:16] : px_osd_ae[7:0]),
    .green_din  (px_osd_ae[15:8]),
    .red_din    (SWAP_RB   ? px_osd_ae[7:0]   : px_osd_ae[23:16]),
    .hsync      (SWAP_HSVS ? vs_r : hs_r),
    .vsync      (SWAP_HSVS ? hs_r : vs_r),
    .de         (de_r),
    .tmds_data0 (tmds_data0),
    .tmds_data1 (tmds_data1),
    .tmds_data2 (tmds_data2),
    .tmds_clk   (tmds_clk)
);

assign tmds_clk_o   = ~tmds_clk;
assign tmds_data0_o = ~tmds_data0;
assign tmds_data1_o = ~tmds_data1;
assign tmds_data2_o = ~tmds_data2;

// Sensor byte-clock frequency, Gray CDC with consecutive 1 s snapshots.
reg [31:0] cam_period_count,cam_period_cycles;
reg cam_vs_previous;
always @(posedge core_clk or negedge video_rst_n)begin
 if(!video_rst_n)begin cam_period_count<=0;cam_period_cycles<=0;cam_vs_previous<=0;end
 else begin
  cam_vs_previous<=vs_sync[2];
  if(vs_sync[2] && !cam_vs_previous)begin cam_period_cycles<=cam_period_count+1'b1;cam_period_count<=0;end
  else cam_period_count<=cam_period_count+1'b1;
 end
end
wire [31:0] sensor_byte_hz;
clock_frequency_meter u_sensor_byte_meter (
 .i_clock(i_cam_ck_CLKOUT),.i_ref_clock(core_clk),.rst_n(video_rst_n),.o_hz(sensor_byte_hz)
);

//=====================================================================
// UART: RX echo + AE status log injection (ae_uart_log wins while a
// line is in progress; the echo FIFO is gated off then and buffered)
//
// The physical TX pin is shared: the Sapphire CPU console (100 MHz) is the
// default during TinyML bring-up; hold KEY3 (active low) to listen to the
// legacy Iris logger (27 MHz) instead.
// RX fans out to both UARTs always.
//=====================================================================
wire iris_uart_txd;
wire soc_uart_txd;
assign txd = key_i[3] ? soc_uart_txd : iris_uart_txd;
wire        RdEmpty;
wire        tx_valid;
wire        rx_valid;
wire        tx_req;
wire [7:0]  tx_data;
wire [7:0]  rx_data;
wire [7:0]  RdDNum;
wire        fifo_dv;
wire [7:0]  fifo_data;
wire        log_dv;
wire [7:0]  log_data;
wire        log_gate;
wire        fifo_pop;
wire        fifo_act;

// camera bring-up status (driven by u_sc431hai_init further down)
wire        sc431hai_done;
wire        sensor_id_ok;
wire [255:0] sensor_readback;

wire cal_dv,cal_gate,cal_ready,capture_key;
key_pulse #(.REP_MS(0)) u_capture_key (
 .clk(gpio_clk_27m),.rst_n(video_rst_n),.key_in(key_i[2]),.pulse(capture_key)
);
wire [7:0] cal_data;
colour_capture #(.STEP(ENABLE_STYLE_DEMO ? 40 : 20)) u_colour_capture (
 .video_clk(hdmi_tx_half_clk),.uart_clk(gpio_clk_27m),.rst_n(video_rst_n),
 .i_vs(dbg_vs_o),.i_de(dbg_de_o),.i_rgb(dbg_rgb),
 .i_capture(capture_key),.rx_valid(rx_valid),.rx_data(rx_data),.log_active(log_gate),.tx_req(tx_req),
 .tx_valid(cal_dv),.tx_data(cal_data),.tx_gate(cal_gate),.o_ready(cal_ready)
);
assign tx_valid  = cal_dv | log_dv | fifo_dv;
assign tx_data   = cal_dv ? cal_data : log_dv ? log_data : fifo_data;
assign fifo_pop  = tx_req & (~RdEmpty) & (~log_gate) & (~cal_gate);
assign fifo_act  = fifo_pop | fifo_dv;

DC_FIFO #(
    .FIFO_MODE  ("Normal"),
    .DATA_WIDTH (8),
    .FIFO_DEPTH (128)
) DC_FIFO_inst (
    .Reset      (1'b0),
    .WrClk      (gpio_clk_27m),
    .WrEn       (rx_valid && rx_data!="C"),
    .WrDNum     (),
    .WrFull     (),
    .WrData     (rx_data),
    .RdClk      (gpio_clk_27m),
    .RdEn       (fifo_pop),
    .RdDNum     (RdDNum),
    .RdEmpty    (RdEmpty),
    .DataVal    (fifo_dv),
    .RdData     (fifo_data)
);

uart_rx_tx #(
    .CLK_RATE       (27000000),
    .BPS_RATE       (115200),
    .STOP_BIT_W     (1),
    .CHECKSUM_MODE  (2'b00),
    .CHECKSUM_EN    (1'b0)
) uart_rx_tx_inst (
    .clk        (gpio_clk_27m),
    .rst_n      (mipi_pll_locked),
    .rxd        (rxd),
    .txd        (iris_uart_txd),
    .tx_valid   (tx_valid),
    .tx_data    (tx_data),
    .tx_req     (tx_req),
    .rx_valid   (rx_valid),
    .rx_data    (rx_data)
);

generate if (ENABLE_LEGACY_UART_LOG) begin : g_legacy_uart_log
ae_uart_log u_ae_log (
    .i_pause   (cal_gate),
    .clk       (gpio_clk_27m),
    .rst_n     (mipi_pll_locked),
    .i_init    (sc431hai_done & sensor_id_ok),
    .i_state   (ae_state),
    .i_exp     (ae_exp),
    .i_gain    (ae_gain),
    .i_sum     (ae_sum),
    .i_writes  (ae_writes),
    .i_touts   (ae_touts),
    .i_luma    (ae_luma),
    .i_target  (ae_target),
    .i_sensor_readback(sensor_readback),
    .i_cam_fps (sens_fps), .i_wr_fps(wr_fps), .i_hdmi_fps(hdmi_fps),
    .i_byte_hz (sensor_byte_hz), .i_cam_period(cam_period_cycles),
    .tx_req    (tx_req),
    .tx_valid  (log_dv),
    .tx_data   (log_data),
    .tx_gate   (log_gate),
    .fifo_act  (fifo_act)
);
end else begin : g_no_legacy_uart_log
    assign log_dv = 1'b0;
    assign log_data = 8'd0;
    assign log_gate = 1'b0;
end endgenerate

//=====================================================================
// SC431HAI I2C bring-up
//=====================================================================
wire cam_scl_padoen;
wire cam_sda_padoen;

// auto-exposure: drives sensor exposure/gain registers after bring-up
wire        ae_req, ae_wr_en, ae_done, ae_busy;
wire [15:0] ae_addr;
wire [7:0]  ae_data;

sc431hai_init u_sc431hai_init
(
    .clk            (gpio_clk_27m),
    .rst_n          (mipi_pll_locked),
    .cam_rst        (o_cam_rst),
    .scl_pad_i      (io_cam_scl_IN),
    .scl_pad_o      (io_cam_scl_OUT),
    .scl_padoen_o   (cam_scl_padoen),
    .sda_pad_i      (io_cam_sda_IN),
    .sda_pad_o      (io_cam_sda_OUT),
    .sda_padoen_o   (cam_sda_padoen),
    .init_done      (sc431hai_done),
    .sensor_id_ok   (sensor_id_ok),
    .sensor_readback(sensor_readback),
    .cpu_mode       (1'b0),
    .cpu_addr       (3'd0),
    .cpu_wdata      (8'd0),
    .cpu_we         (1'b0),
    .cpu_stb        (1'b0),
    .cpu_rdata      (),
    .cpu_ack        (),
    .i2c_busy       (ae_busy),
    .ae_req         (ae_req),
    .ae_wr_en       (ae_wr_en),
    .ae_addr        (ae_addr),
    .ae_data        (ae_data),
    .ae_done        (ae_done)
);

ae_ctrl #(.NPX(1920 * 1080)) u_ae_ctrl (
    .clk        (gpio_clk_27m),
    .rst_n      (mipi_pll_locked),
    .init_done  (sc431hai_done & sensor_id_ok),
    .stats_tgl  (awb_upd_tgl),
    .sum_r      (awb_sum_r),
    .sum_g      (awb_sum_g),
    .sum_b      (awb_sum_b),
    .ae_req     (ae_req),
    .ae_wr_en   (ae_wr_en),
    .ae_addr    (ae_addr),
    .ae_data    (ae_data),
    .ae_busy    (ae_busy),
    .ae_done    (ae_done),
    .i_tgt_up   (key1_up),
    .i_tgt_dn   (key0_dn),
    .dbg_state  (ae_state),
    .dbg_exp    (ae_exp),
    .dbg_gain   (ae_gain),
    .dbg_sum    (ae_sum),
    .dbg_writes (ae_writes),
    .dbg_touts  (ae_touts),
    .dbg_target (ae_target)
);

// KEY0 -> exposure comp down, KEY1 -> exposure comp up (P-mode EV style;
// 20 ms debounce, 250 ms repeat, target step +/-4)
key_pulse u_key0 (
    .clk   (gpio_clk_27m),
    .rst_n (mipi_pll_locked),
    .key_in(key_i[0]),
    .pulse (key0_dn)
);
key_pulse u_key1 (
    .clk   (gpio_clk_27m),
    .rst_n (mipi_pll_locked),
    .key_in(key_i[1]),
    .pulse (key1_up)
);

// KEY2 now freezes a calibration thumbnail; KEY3 has no calibration action.


assign io_cam_scl_OE = ~cam_scl_padoen;
assign io_cam_sda_OE = ~cam_sda_padoen;

//=====================================================================
// TinyML subsystem: Sapphire SoC + TinyML accelerator (core_clk domain)
//   rst_n is gated by DDR calibration so neither master can touch DDR
//   before the controller is ready (docs/TinyML_移植进度与待办.md #2).
//=====================================================================
wire tinyml_rst_n = core_pll_locked & ddr_pll_locked & ddr_cal_done;

// CPU AXI master (converted from the SoC half-duplex io_ddrA port)
wire [7:0]   cpu_awid;
wire [31:0]  cpu_awaddr;
wire [7:0]   cpu_awlen;
wire [2:0]   cpu_awsize;
wire [1:0]   cpu_awburst;
wire         cpu_awlock;
wire         cpu_awvalid;
wire         cpu_awready;
wire [127:0] cpu_wdata;
wire [15:0]  cpu_wstrb;
wire         cpu_wlast;
wire         cpu_wvalid;
wire         cpu_wready;
wire [7:0]   cpu_bid;
wire [1:0]   cpu_bresp;
wire         cpu_bvalid;
wire         cpu_bready;
wire [7:0]   cpu_arid;
wire [31:0]  cpu_araddr;
wire [7:0]   cpu_arlen;
wire [2:0]   cpu_arsize;
wire [1:0]   cpu_arburst;
wire         cpu_arlock;
wire         cpu_arvalid;
wire         cpu_arready;
wire [127:0] cpu_rdata;
wire [7:0]   cpu_rid;
wire [1:0]   cpu_rresp;
wire         cpu_rlast;
wire         cpu_rvalid;
wire         cpu_rready;

// TinyML accelerator AXI master
wire [7:0]   acc_awid;
wire [31:0]  acc_awaddr;
wire [7:0]   acc_awlen;
wire [2:0]   acc_awsize;
wire [1:0]   acc_awburst;
wire         acc_awlock;
wire         acc_awvalid;
wire         acc_awready;
wire [127:0] acc_wdata;
wire [15:0]  acc_wstrb;
wire         acc_wlast;
wire         acc_wvalid;
wire         acc_wready;
wire [7:0]   acc_bid;
wire [1:0]   acc_bresp;
wire         acc_bvalid;
wire         acc_bready;
wire [7:0]   acc_arid;
wire [31:0]  acc_araddr;
wire [7:0]   acc_arlen;
wire [2:0]   acc_arsize;
wire [1:0]   acc_arburst;
wire         acc_arlock;
wire         acc_arvalid;
wire         acc_arready;
wire [127:0] acc_rdata;
wire [7:0]   acc_rid;
wire [1:0]   acc_rresp;
wire         acc_rlast;
wire         acc_rvalid;
wire         acc_rready;

// merged master -> axi_atype_bridge
wire [7:0]   mem_awid;
wire [27:0]  mem_awaddr;
wire [7:0]   mem_awlen;
wire [2:0]   mem_awsize;
wire [1:0]   mem_awburst;
wire         mem_awlock;
wire         mem_awvalid;
wire         mem_awready;
wire [127:0] mem_wdata;
wire [15:0]  mem_wstrb;
wire         mem_wlast;
wire         mem_wvalid;
wire         mem_wready;
wire [7:0]   mem_bid;
wire [1:0]   mem_bresp;
wire         mem_bvalid;
wire         mem_bready;
wire [7:0]   mem_arid;
wire [27:0]  mem_araddr;
wire [7:0]   mem_arlen;
wire [2:0]   mem_arsize;
wire [1:0]   mem_arburst;
wire         mem_arlock;
wire         mem_arvalid;
wire         mem_arready;
wire [127:0] mem_rdata;
wire [7:0]   mem_rid;
wire [1:0]   mem_rresp;
wire         mem_rlast;
wire         mem_rvalid;
wire         mem_rready;
wire [7:0]   mem_wid;
wire [31:0]  dbg_arb_ar_addr;
wire [7:0]   dbg_arb_ar_len;
wire [2:0]   dbg_arb_ar_size;
wire [1:0]   dbg_arb_ar_burst;
wire [31:0]  dbg_arb_aw_addr;
wire [7:0]   dbg_arb_aw_len;
wire [1:0]   dbg_arb_bresp;
wire [1:0]   dbg_arb_rresp;
wire [15:0]  dbg_arb_rd_cnt;
wire [15:0]  dbg_arb_wr_cnt;
wire [7:0]   dbg_arb_rd_err_cnt;
wire [7:0]   dbg_arb_wr_err_cnt;
wire [7:0]   dbg_arb_state;
wire [31:0]  dbg_arb_cpu_ar_addr;
wire [31:0]  dbg_arb_fb_ar_addr;
wire [31:0]  dbg_arb_cpu_aw_addr;
wire [31:0]  dbg_arb_fb_aw_addr;
wire [15:0]  dbg_arb_cpu_rd_cnt;
wire [15:0]  dbg_arb_fb_rd_cnt;
wire [15:0]  dbg_arb_m_ar_cnt;
wire [15:0]  dbg_arb_m_aw_cnt;

// Style demo extends the CPU DDR channel; accelerator routing is unchanged.
wire [7:0] raw_cpu_awid;
wire [31:0] raw_cpu_awaddr;
wire [7:0] raw_cpu_awlen;
wire [2:0] raw_cpu_awsize;
wire [1:0] raw_cpu_awburst;
wire raw_cpu_awlock;
wire raw_cpu_awvalid;
wire [127:0] raw_cpu_wdata;
wire [15:0] raw_cpu_wstrb;
wire raw_cpu_wlast;
wire raw_cpu_wvalid;
wire raw_cpu_bready;
wire [7:0] raw_cpu_arid;
wire [31:0] raw_cpu_araddr;
wire [7:0] raw_cpu_arlen;
wire [2:0] raw_cpu_arsize;
wire [1:0] raw_cpu_arburst;
wire raw_cpu_arlock;
wire raw_cpu_arvalid;
wire raw_cpu_rready;
wire raw_cpu_awready;
wire raw_cpu_wready;
wire [7:0] raw_cpu_bid;
wire [1:0] raw_cpu_bresp;
wire raw_cpu_bvalid;
wire raw_cpu_arready;
wire [127:0] raw_cpu_rdata;
wire [7:0] raw_cpu_rid;
wire [1:0] raw_cpu_rresp;
wire raw_cpu_rlast;
wire raw_cpu_rvalid;
wire [31:0] style_awaddr;
wire [7:0] style_awlen;
wire style_awvalid;
wire [127:0] style_wdata;
wire style_wlast;
wire style_wvalid;
wire style_bready;
wire [31:0] style_araddr;
wire [7:0] style_arlen;
wire style_arvalid;
wire style_rready;
wire style_awready;
wire style_wready;
wire [1:0] style_bresp;
wire style_bvalid;
wire style_arready;
wire [127:0] style_rdata;
wire [1:0] style_rresp;
wire style_rlast;
wire style_rvalid;
wire [15:0] style_paddr;
wire style_psel,style_penable,style_pwrite;
wire [31:0] style_pwdata,style_prdata;

tinyml_subsystem #(.ENABLE_STYLE_DEMO(ENABLE_STYLE_DEMO)) u_tinyml_subsystem (
    .style_paddr(style_paddr),.style_psel(style_psel),.style_penable(style_penable),
    .style_pwrite(style_pwrite),.style_pwdata(style_pwdata),.style_prdata(style_prdata),
    .clk              (core_clk),
    .rst_n            (tinyml_rst_n),
    .uart_txd         (soc_uart_txd),
    .uart_rxd_async   (rxd),
    .jtag_inst1_TCK   (jtag_inst1_TCK),
    .jtag_inst1_TDI   (jtag_inst1_TDI),
    .jtag_inst1_TDO   (jtag_inst1_TDO),
    .jtag_inst1_SEL   (jtag_inst1_SEL),
    .jtag_inst1_CAPTURE(jtag_inst1_CAPTURE),
    .jtag_inst1_SHIFT (jtag_inst1_SHIFT),
    .jtag_inst1_UPDATE(jtag_inst1_UPDATE),
    .jtag_inst1_RESET (jtag_inst1_RESET),
    .cpu_awid         (raw_cpu_awid),
    .cpu_awaddr       (raw_cpu_awaddr),
    .cpu_awlen        (raw_cpu_awlen),
    .cpu_awsize       (raw_cpu_awsize),
    .cpu_awburst      (raw_cpu_awburst),
    .cpu_awlock       (raw_cpu_awlock),
    .cpu_awvalid      (raw_cpu_awvalid),
    .cpu_awready      (raw_cpu_awready),
    .cpu_wdata        (raw_cpu_wdata),
    .cpu_wstrb        (raw_cpu_wstrb),
    .cpu_wlast        (raw_cpu_wlast),
    .cpu_wvalid       (raw_cpu_wvalid),
    .cpu_wready       (raw_cpu_wready),
    .cpu_bid          (raw_cpu_bid),
    .cpu_bresp        (raw_cpu_bresp),
    .cpu_bvalid       (raw_cpu_bvalid),
    .cpu_bready       (raw_cpu_bready),
    .cpu_arid         (raw_cpu_arid),
    .cpu_araddr       (raw_cpu_araddr),
    .cpu_arlen        (raw_cpu_arlen),
    .cpu_arsize       (raw_cpu_arsize),
    .cpu_arburst      (raw_cpu_arburst),
    .cpu_arlock       (raw_cpu_arlock),
    .cpu_arvalid      (raw_cpu_arvalid),
    .cpu_arready      (raw_cpu_arready),
    .cpu_rdata        (raw_cpu_rdata),
    .cpu_rid          (raw_cpu_rid),
    .cpu_rresp        (raw_cpu_rresp),
    .cpu_rlast        (raw_cpu_rlast),
    .cpu_rvalid       (raw_cpu_rvalid),
    .cpu_rready       (raw_cpu_rready),
    .acc_awid         (acc_awid),
    .acc_awaddr       (acc_awaddr),
    .acc_awlen        (acc_awlen),
    .acc_awsize       (acc_awsize),
    .acc_awburst      (acc_awburst),
    .acc_awlock       (acc_awlock),
    .acc_awvalid      (acc_awvalid),
    .acc_awready      (acc_awready),
    .acc_wdata        (acc_wdata),
    .acc_wstrb        (acc_wstrb),
    .acc_wlast        (acc_wlast),
    .acc_wvalid       (acc_wvalid),
    .acc_wready       (acc_wready),
    .acc_bid          (acc_bid),
    .acc_bresp        (acc_bresp),
    .acc_bvalid       (acc_bvalid),
    .acc_bready       (acc_bready),
    .acc_arid         (acc_arid),
    .acc_araddr       (acc_araddr),
    .acc_arlen        (acc_arlen),
    .acc_arsize       (acc_arsize),
    .acc_arburst      (acc_arburst),
    .acc_arlock       (acc_arlock),
    .acc_arvalid      (acc_arvalid),
    .acc_arready      (acc_arready),
    .acc_rdata        (acc_rdata),
    .acc_rid          (acc_rid),
    .acc_rresp        (acc_rresp),
    .acc_rlast        (acc_rlast),
    .acc_rvalid       (acc_rvalid),
    .acc_rready       (acc_rready),
    .subsystem_rst    (),
    .accel_cmd_int    (),
    .dbg_arb_ar_addr  (dbg_arb_ar_addr),
    .dbg_arb_ar_len   (dbg_arb_ar_len),
    .dbg_arb_ar_size  (dbg_arb_ar_size),
    .dbg_arb_ar_burst (dbg_arb_ar_burst),
    .dbg_arb_aw_addr  (dbg_arb_aw_addr),
    .dbg_arb_aw_len   (dbg_arb_aw_len),
    .dbg_arb_bresp    (dbg_arb_bresp),
    .dbg_arb_rresp    (dbg_arb_rresp),
    .dbg_arb_rd_cnt   (dbg_arb_rd_cnt),
    .dbg_arb_wr_cnt   (dbg_arb_wr_cnt),
    .dbg_arb_rd_err_cnt(dbg_arb_rd_err_cnt),
    .dbg_arb_wr_err_cnt(dbg_arb_wr_err_cnt),
    .dbg_arb_state    (dbg_arb_state),
    .dbg_arb_cpu_ar_addr(dbg_arb_cpu_ar_addr),
    .dbg_arb_fb_ar_addr (dbg_arb_fb_ar_addr),
    .dbg_arb_cpu_aw_addr(dbg_arb_cpu_aw_addr),
    .dbg_arb_fb_aw_addr (dbg_arb_fb_aw_addr),
    .dbg_arb_cpu_rd_cnt (dbg_arb_cpu_rd_cnt),
    .dbg_arb_fb_rd_cnt  (dbg_arb_fb_rd_cnt),
    .dbg_arb_m_ar_cnt   (dbg_arb_m_ar_cnt),
    .dbg_arb_m_aw_cnt   (dbg_arb_m_aw_cnt)
);


reg [3:0] arb_rst_pipe;
generate if(ENABLE_STYLE_DEMO)begin : g_style_demo
iris_style_demo u_style_demo(
 .clk(core_clk),.video_clk(hdmi_tx_half_clk),.rst_n(arb_rst_pipe[3]),
 .paddr(style_paddr),.psel(style_psel),.penable(style_penable),.pwrite(style_pwrite),
 .pwdata(style_pwdata),.prdata(style_prdata),
 .i_hs(display_hs),.i_vs(display_vs),.i_de(display_de),.i_rgb(display_rgb),
 .o_hs(style_display_hs),.o_vs(style_display_vs),.o_de(style_display_de),.o_rgb(style_display_rgb),
 .awaddr(style_awaddr),
 .awlen(style_awlen),
 .awvalid(style_awvalid),
 .wdata(style_wdata),
 .wlast(style_wlast),
 .wvalid(style_wvalid),
 .bready(style_bready),
 .araddr(style_araddr),
 .arlen(style_arlen),
 .arvalid(style_arvalid),
 .rready(style_rready),
 .awready(style_awready),
 .wready(style_wready),
 .bresp(style_bresp),
 .bvalid(style_bvalid),
 .arready(style_arready),
 .rdata(style_rdata),
 .rresp(style_rresp),
 .rlast(style_rlast),
 .rvalid(style_rvalid)
);
axi_cpu_style_mux u_style_mux(
 .clk(core_clk),.rst_n(arb_rst_pipe[3]),
 .cpu_awid(raw_cpu_awid),
 .cpu_awaddr(raw_cpu_awaddr),
 .cpu_awlen(raw_cpu_awlen),
 .cpu_awsize(raw_cpu_awsize),
 .cpu_awburst(raw_cpu_awburst),
 .cpu_awlock(raw_cpu_awlock),
 .cpu_awvalid(raw_cpu_awvalid),
 .cpu_wdata(raw_cpu_wdata),
 .cpu_wstrb(raw_cpu_wstrb),
 .cpu_wlast(raw_cpu_wlast),
 .cpu_wvalid(raw_cpu_wvalid),
 .cpu_bready(raw_cpu_bready),
 .cpu_arid(raw_cpu_arid),
 .cpu_araddr(raw_cpu_araddr),
 .cpu_arlen(raw_cpu_arlen),
 .cpu_arsize(raw_cpu_arsize),
 .cpu_arburst(raw_cpu_arburst),
 .cpu_arlock(raw_cpu_arlock),
 .cpu_arvalid(raw_cpu_arvalid),
 .cpu_rready(raw_cpu_rready),
 .cpu_awready(raw_cpu_awready),
 .cpu_wready(raw_cpu_wready),
 .cpu_bid(raw_cpu_bid),
 .cpu_bresp(raw_cpu_bresp),
 .cpu_bvalid(raw_cpu_bvalid),
 .cpu_arready(raw_cpu_arready),
 .cpu_rdata(raw_cpu_rdata),
 .cpu_rid(raw_cpu_rid),
 .cpu_rresp(raw_cpu_rresp),
 .cpu_rlast(raw_cpu_rlast),
 .cpu_rvalid(raw_cpu_rvalid),
 .style_awaddr(style_awaddr),
 .style_awlen(style_awlen),
 .style_awvalid(style_awvalid),
 .style_wdata(style_wdata),
 .style_wlast(style_wlast),
 .style_wvalid(style_wvalid),
 .style_bready(style_bready),
 .style_araddr(style_araddr),
 .style_arlen(style_arlen),
 .style_arvalid(style_arvalid),
 .style_rready(style_rready),
 .style_awready(style_awready),
 .style_wready(style_wready),
 .style_bresp(style_bresp),
 .style_bvalid(style_bvalid),
 .style_arready(style_arready),
 .style_rdata(style_rdata),
 .style_rresp(style_rresp),
 .style_rlast(style_rlast),
 .style_rvalid(style_rvalid),
 .m_awid(cpu_awid),
 .m_awaddr(cpu_awaddr),
 .m_awlen(cpu_awlen),
 .m_awsize(cpu_awsize),
 .m_awburst(cpu_awburst),
 .m_awlock(cpu_awlock),
 .m_awvalid(cpu_awvalid),
 .m_wdata(cpu_wdata),
 .m_wstrb(cpu_wstrb),
 .m_wlast(cpu_wlast),
 .m_wvalid(cpu_wvalid),
 .m_bready(cpu_bready),
 .m_arid(cpu_arid),
 .m_araddr(cpu_araddr),
 .m_arlen(cpu_arlen),
 .m_arsize(cpu_arsize),
 .m_arburst(cpu_arburst),
 .m_arlock(cpu_arlock),
 .m_arvalid(cpu_arvalid),
 .m_rready(cpu_rready),
 .m_awready(cpu_awready),
 .m_wready(cpu_wready),
 .m_bid(cpu_bid),
 .m_bresp(cpu_bresp),
 .m_bvalid(cpu_bvalid),
 .m_arready(cpu_arready),
 .m_rdata(cpu_rdata),
 .m_rid(cpu_rid),
 .m_rresp(cpu_rresp),
 .m_rlast(cpu_rlast),
 .m_rvalid(cpu_rvalid)
);
end else begin : g_no_style_demo
assign cpu_awid=raw_cpu_awid;
assign cpu_awaddr=raw_cpu_awaddr;
assign cpu_awlen=raw_cpu_awlen;
assign cpu_awsize=raw_cpu_awsize;
assign cpu_awburst=raw_cpu_awburst;
assign cpu_awlock=raw_cpu_awlock;
assign cpu_awvalid=raw_cpu_awvalid;
assign cpu_wdata=raw_cpu_wdata;
assign cpu_wstrb=raw_cpu_wstrb;
assign cpu_wlast=raw_cpu_wlast;
assign cpu_wvalid=raw_cpu_wvalid;
assign cpu_bready=raw_cpu_bready;
assign cpu_arid=raw_cpu_arid;
assign cpu_araddr=raw_cpu_araddr;
assign cpu_arlen=raw_cpu_arlen;
assign cpu_arsize=raw_cpu_arsize;
assign cpu_arburst=raw_cpu_arburst;
assign cpu_arlock=raw_cpu_arlock;
assign cpu_arvalid=raw_cpu_arvalid;
assign cpu_rready=raw_cpu_rready;
assign raw_cpu_awready=cpu_awready;
assign raw_cpu_wready=cpu_wready;
assign raw_cpu_bid=cpu_bid;
assign raw_cpu_bresp=cpu_bresp;
assign raw_cpu_bvalid=cpu_bvalid;
assign raw_cpu_arready=cpu_arready;
assign raw_cpu_rdata=cpu_rdata;
assign raw_cpu_rid=cpu_rid;
assign raw_cpu_rresp=cpu_rresp;
assign raw_cpu_rlast=cpu_rlast;
assign raw_cpu_rvalid=cpu_rvalid;
assign style_prdata=0;
assign {style_display_hs,style_display_vs,style_display_de,style_display_rgb}={display_hs,display_vs,display_de,display_rgb};
end endgenerate
//=====================================================================
// Shared-DDR arbiter: video frame buffer + CPU + TinyML accelerator
//   -> single AXI4 master -> axi_atype_bridge -> efx_ddr3_axi
//=====================================================================
// Async assert / synchronous release for the shared-path reset: video_rst_n
// and tinyml_rst_n are ANDs of asynchronous lock signals; releasing the
// arbiter FSMs off a raw edge risks metastable wr/rd owner state.
wire arb_rst_n_raw = video_rst_n & tinyml_rst_n;
always @(posedge core_clk or negedge arb_rst_n_raw) begin
    if (!arb_rst_n_raw) arb_rst_pipe <= 4'd0;
    else                arb_rst_pipe <= {arb_rst_pipe[2:0], 1'b1};
end

axi_ddr_arbiter #(
    .DW  (128),
    .IDW (8),
    .MAW (28)
) u_axi_ddr_arbiter (
    .clk       (core_clk),
    .rst_n     (arb_rst_pipe[3]),
    // S0: video frame buffer
    .s0_awid   ({2'b0, fb_awid}),
    .s0_awaddr ({4'b0, fb_awaddr}),
    .s0_awlen  (fb_awlen),
    .s0_awsize (fb_awsize),
    .s0_awburst(fb_awburst),
    .s0_awlock (fb_awlock),
    .s0_awvalid(fb_awvalid),
    .s0_awready(fb_awready),
    .s0_wdata  (fb_wdata),
    .s0_wstrb  (fb_wstrb),
    .s0_wlast  (fb_wlast),
    .s0_wvalid (fb_wvalid),
    .s0_wready (fb_wready),
    .s0_bid    (arb_s0_bid),
    .s0_bresp  (fb_bresp),
    .s0_bvalid (fb_bvalid),
    .s0_bready (fb_bready),
    .s0_arid   ({2'b0, fb_arid}),
    .s0_araddr ({4'b0, fb_araddr}),
    .s0_arlen  (fb_arlen),
    .s0_arsize (fb_arsize),
    .s0_arburst(fb_arburst),
    .s0_arlock (fb_arlock),
    .s0_arvalid(fb_arvalid),
    .s0_arready(fb_arready),
    .s0_rdata  (fb_rdata),
    .s0_rid    (arb_s0_rid),
    .s0_rresp  (fb_rresp),
    .s0_rlast  (fb_rlast),
    .s0_rvalid (fb_rvalid),
    .s0_rready (fb_rready),
    // S1: Sapphire CPU
    .s1_awid   (cpu_awid),
    .s1_awaddr (cpu_awaddr),
    .s1_awlen  (cpu_awlen),
    .s1_awsize (cpu_awsize),
    .s1_awburst(cpu_awburst),
    .s1_awlock (cpu_awlock),
    .s1_awvalid(cpu_awvalid),
    .s1_awready(cpu_awready),
    .s1_wdata  (cpu_wdata),
    .s1_wstrb  (cpu_wstrb),
    .s1_wlast  (cpu_wlast),
    .s1_wvalid (cpu_wvalid),
    .s1_wready (cpu_wready),
    .s1_bid    (cpu_bid),
    .s1_bresp  (cpu_bresp),
    .s1_bvalid (cpu_bvalid),
    .s1_bready (cpu_bready),
    .s1_arid   (cpu_arid),
    .s1_araddr (cpu_araddr),
    .s1_arlen  (cpu_arlen),
    .s1_arsize (cpu_arsize),
    .s1_arburst(cpu_arburst),
    .s1_arlock (cpu_arlock),
    .s1_arvalid(cpu_arvalid),
    .s1_arready(cpu_arready),
    .s1_rdata  (cpu_rdata),
    .s1_rid    (cpu_rid),
    .s1_rresp  (cpu_rresp),
    .s1_rlast  (cpu_rlast),
    .s1_rvalid (cpu_rvalid),
    .s1_rready (cpu_rready),
    // S2: TinyML accelerator
    .s2_awid   (acc_awid),
    .s2_awaddr (acc_awaddr),
    .s2_awlen  (acc_awlen),
    .s2_awsize (acc_awsize),
    .s2_awburst(acc_awburst),
    .s2_awlock (acc_awlock),
    .s2_awvalid(acc_awvalid),
    .s2_awready(acc_awready),
    .s2_wdata  (acc_wdata),
    .s2_wstrb  (acc_wstrb),
    .s2_wlast  (acc_wlast),
    .s2_wvalid (acc_wvalid),
    .s2_wready (acc_wready),
    .s2_bid    (acc_bid),
    .s2_bresp  (acc_bresp),
    .s2_bvalid (acc_bvalid),
    .s2_bready (acc_bready),
    .s2_arid   (acc_arid),
    .s2_araddr (acc_araddr),
    .s2_arlen  (acc_arlen),
    .s2_arsize (acc_arsize),
    .s2_arburst(acc_arburst),
    .s2_arlock (acc_arlock),
    .s2_arvalid(acc_arvalid),
    .s2_arready(acc_arready),
    .s2_rdata  (acc_rdata),
    .s2_rid    (acc_rid),
    .s2_rresp  (acc_rresp),
    .s2_rlast  (acc_rlast),
    .s2_rvalid (acc_rvalid),
    .s2_rready (acc_rready),
    // merged master
    .m_awid    (mem_awid),
    .m_awaddr  (mem_awaddr),
    .m_awlen   (mem_awlen),
    .m_awsize  (mem_awsize),
    .m_awburst (mem_awburst),
    .m_awlock  (mem_awlock),
    .m_awvalid (mem_awvalid),
    .m_awready (mem_awready),
    .m_wdata   (mem_wdata),
    .m_wstrb   (mem_wstrb),
    .m_wlast   (mem_wlast),
    .m_wvalid  (mem_wvalid),
    .m_wready  (mem_wready),
    .m_bid     (mem_bid),
    .m_bresp   (mem_bresp),
    .m_bvalid  (mem_bvalid),
    .m_bready  (mem_bready),
    .m_arid    (mem_arid),
    .m_araddr  (mem_araddr),
    .m_arlen   (mem_arlen),
    .m_arsize  (mem_arsize),
    .m_arburst (mem_arburst),
    .m_arlock  (mem_arlock),
    .m_arvalid (mem_arvalid),
    .m_arready (mem_arready),
    .m_rdata   (mem_rdata),
    .m_rid     (mem_rid),
    .m_rresp   (mem_rresp),
    .m_rlast   (mem_rlast),
    .m_rvalid  (mem_rvalid),
    .m_rready  (mem_rready),
    .m_wid     (mem_wid),
    .dbg_last_ar_addr (dbg_arb_ar_addr),
    .dbg_last_ar_len  (dbg_arb_ar_len),
    .dbg_last_ar_size (dbg_arb_ar_size),
    .dbg_last_ar_burst(dbg_arb_ar_burst),
    .dbg_last_aw_addr (dbg_arb_aw_addr),
    .dbg_last_aw_len  (dbg_arb_aw_len),
    .dbg_last_bresp   (dbg_arb_bresp),
    .dbg_last_rresp   (dbg_arb_rresp),
    .dbg_rd_cnt       (dbg_arb_rd_cnt),
    .dbg_wr_cnt       (dbg_arb_wr_cnt),
    .dbg_rd_err_cnt   (dbg_arb_rd_err_cnt),
    .dbg_wr_err_cnt   (dbg_arb_wr_err_cnt),
    .dbg_state        (dbg_arb_state),
    .dbg_cpu_ar_addr  (dbg_arb_cpu_ar_addr),
    .dbg_fb_ar_addr   (dbg_arb_fb_ar_addr),
    .dbg_cpu_aw_addr  (dbg_arb_cpu_aw_addr),
    .dbg_fb_aw_addr   (dbg_arb_fb_aw_addr),
    .dbg_cpu_rd_cnt   (dbg_arb_cpu_rd_cnt),
    .dbg_fb_rd_cnt    (dbg_arb_fb_rd_cnt),
    .dbg_m_ar_cnt     (dbg_arb_m_ar_cnt),
    .dbg_m_aw_cnt     (dbg_arb_m_aw_cnt)
);

//=====================================================================
// AXI4 -> shared-address bridge (frame buffer -> DDR3 soft controller)
//=====================================================================
axi_atype_bridge #(
    .IDW (8),
    .AW  (28)
) u_axi_atype_bridge (
    .clk         (core_clk),
    .rst_n       (core_pll_locked & ddr_pll_locked),

    .s_awid      (mem_awid),
    .s_awaddr    (mem_awaddr),
    .s_awlen     (mem_awlen),
    .s_awsize    (mem_awsize),
    .s_awburst   (mem_awburst),
    .s_awlock    (mem_awlock),
    .s_awvalid   (mem_awvalid),
    .s_awready   (mem_awready),

    .s_arid      (mem_arid),
    .s_araddr    (mem_araddr),
    .s_arlen     (mem_arlen),
    .s_arsize    (mem_arsize),
    .s_arburst   (mem_arburst),
    .s_arlock    (mem_arlock),
    .s_arvalid   (mem_arvalid),
    .s_arready   (mem_arready),

    .m_aid       (ddr_ax_aid),
    .m_aaddr     (ddr_ax_aaddr),
    .m_alen      (ddr_ax_alen),
    .m_asize     (ddr_ax_asize),
    .m_aburst    (ddr_ax_aburst),
    .m_alock     (ddr_ax_alock),
    .m_atype     (ddr_ax_atype),
    .m_avalid    (ddr_ax_avalid),
    .m_aready    (ddr_ax_aready),

    .bvalid      (mem_bvalid),
    .bready      (mem_bready),
    .rvalid      (mem_rvalid),
    .rlast       (mem_rlast),
    .rready      (mem_rready)
);

//=====================================================================
// Efinix DDR3 soft controller (AXI variant, 16-bit DDR3, 128-bit AXI)
//=====================================================================
efx_ddr3_axi u_efx_ddr3_axi (
    .clk              (core_clk),
    .core_clk         (ddr_core_clk),
    .tdqss_clk        (ddr_tdqss_clk),
    .tac_clk          (ddr_tac_clk),
    .twd_clk          (ddr_twd_clk),
    .reset_n          (core_pll_locked & ddr_pll_locked),

    .reset            (ddr_reset),
    .cs               (ddr_cs),
    .ras              (ddr_ras),
    .cas              (ddr_cas),
    .we               (ddr_we),
    .cke              (ddr_cke),
    .addr             (ddr_addr),
    .ba               (ddr_ba),
    .odt              (ddr_odt),

    .o_dm_hi          (o_ddr_dm_hi),
    .o_dm_lo          (o_ddr_dm_lo),

    .i_dq_hi          (i_ddr_dq_hi),
    .i_dq_lo          (i_ddr_dq_lo),
    .o_dq_hi          (o_ddr_dq_hi),
    .o_dq_lo          (o_ddr_dq_lo),
    .o_dq_oe          (o_ddr_dq_oe),

    .i_dqs_hi         (i_ddr_dqs_hi),
    .i_dqs_lo         (i_ddr_dqs_lo),
    .i_dqs_n_hi       (i_ddr_dqs_n_hi),
    .i_dqs_n_lo       (i_ddr_dqs_n_lo),
    .o_dqs_hi         (o_ddr_dqs_hi),
    .o_dqs_lo         (o_ddr_dqs_lo),
    .o_dqs_n_hi       (),
    .o_dqs_n_lo       (),
    .o_dqs_oe         (o_ddr_dqs_oe),
    .o_dqs_n_oe       (o_ddr_dqs_n_oe),

    .axi_aid          (ddr_ax_aid),
    .axi_aaddr        ({4'b0, ddr_ax_aaddr}),
    .axi_alen         (ddr_ax_alen),
    .axi_asize        (ddr_ax_asize),
    .axi_aburst       (ddr_ax_aburst),
    .axi_alock        (ddr_ax_alock),
    .axi_avalid       (ddr_ax_avalid),
    .axi_aready       (ddr_ax_aready),
    .axi_atype        (ddr_ax_atype),

    .axi_wid          (mem_wid),
    .axi_wdata        (mem_wdata),
    .axi_wstrb        (mem_wstrb),
    .axi_wlast        (mem_wlast),
    .axi_wvalid       (mem_wvalid),
    .axi_wready       (mem_wready),

    .axi_rid          (mem_rid),
    .axi_rdata        (mem_rdata),
    .axi_rlast        (mem_rlast),
    .axi_rvalid       (mem_rvalid),
    .axi_rready       (mem_rready),
    .axi_rresp        (mem_rresp),

    .axi_bid          (mem_bid),
    .axi_bresp        (mem_bresp),
    .axi_bvalid       (mem_bvalid),
    .axi_bready       (mem_bready),

    .shift            (pll_shift),
    .shift_sel        (pll_shift_sel),
    .shift_ena        (pll_shift_ena),
    .cal_ena          (1'b1),
    .cal_done         (ddr_cal_done),
    .cal_pass         (ddr_cal_pass),
    .cal_shift_val    (),
    .cal_fail_log     (ddr_cal_fail_log)
);

//=====================================================================
// TEMPORARY probes: display-side activity
//   led0=dbg_de_o (debayer de), led1=fb_de (frame buf read de),
//   led2=hdmi_tx_locked, led3=dbg_hs_o (debayer hs)
//=====================================================================
reg [23:0] dbg_de_cnt, fb_de_cnt, dbg_hs_cnt;

always @(posedge core_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        dbg_de_cnt <= 24'd0;
        fb_de_cnt  <= 24'd0;
        dbg_hs_cnt <= 24'd0;
    end else begin
        if (dbg_de_o) dbg_de_cnt <= dbg_de_cnt + 1'b1;
        if (fb_de)    fb_de_cnt  <= fb_de_cnt  + 1'b1;
        if (dbg_hs_o) dbg_hs_cnt <= dbg_hs_cnt + 1'b1;
    end
end

// led[0] = sensor/wr fps mismatch (on => write path dropping frames)
// led[1] = wr_fps   >= 32        led[3] = sens_fps >= 32
// led[2] = frozen calibration thumbnail ready (KEY2)
assign led[0] = (sens_fps != wr_fps);
assign led[1] = wr_fps[5];
assign led[2] = cal_ready;
assign led[3] = sens_fps[5];

endmodule
