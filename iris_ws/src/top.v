//=====================================================================
// L0 merged top: official CSI->frame buffer->debayer->HDMI path.
//   MIPI RAW10 -> sensor_clipper -> frame_buffer (Bayer mosaic in DDR3) ->
//   debayer (display domain) -> RGB888 -> TMDS/HDMI 1080p.
//=====================================================================

module top
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
    (* syn_peri_port = 0 *) output          o_cam_rst
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

wire [7:0]   fb_rid8;
wire [127:0] fb_rdata;
wire         fb_rlast;
wire         fb_rvalid;
wire         fb_rready;
wire [1:0]   fb_rresp;
wire [5:0]   fb_rid;
wire [7:0]   fb_bid8;
wire [5:0]   fb_bid;
wire         fb_bvalid;
wire         fb_bready;
wire [1:0]   fb_bresp;

wire [15:0]  fb_vout;
wire         fb_hs, fb_vs, fb_de;
wire         fb_wr_sw;
// KEY3 / UART '4' or '1' requests a mode; commit only at a display VS.
wire rx_valid;wire [7:0] rx_data;
wire mode_key;
reg requested_4k;
key_pulse #(.REP_MS(0)) u_mode_key (
 .clk(gpio_clk_27m),.rst_n(video_rst_n),.key_in(key_i[3]),.pulse(mode_key)
);
always @(posedge gpio_clk_27m or negedge video_rst_n)begin
 if(!video_rst_n)requested_4k<=0;
 else if(rx_valid&&rx_data==8'h34)requested_4k<=1;
 else if(rx_valid&&rx_data==8'h31)requested_4k<=0;
 else if(mode_key)requested_4k<=~requested_4k;
end
wire hdmi_mode_half,hdmi_mode;
video_mode_commit u_mode_commit(
 .read_clk(hdmi_tx_half_clk),.pixel_clk(hdmi_tx_slow_clk),.rst_n(video_rst_n),
 .request_4k(requested_4k),.read_vs(fb_vs),.read_4k(hdmi_mode_half),.pixel_4k(hdmi_mode)
);

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

    .H_FRONT_PORCH  (hdmi_mode_half ? 13'd1144 : 13'd44),
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

assign fb_rid = fb_rid8[5:0];
assign fb_bid = fb_bid8[5:0];

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

wire dbg_vs_o_1080,dbg_hs_o_1080,dbg_de_o_1080,dbg_val_o_1080;
wire dbg_vs_o_4k,dbg_hs_o_4k,dbg_de_o_4k,dbg_val_o_4k;
wire [47:0] dbg_rgb_1080,dbg_rgb_4k;
assign dbg_vs_o=hdmi_mode_half?dbg_vs_o_4k:dbg_vs_o_1080;
assign dbg_hs_o=hdmi_mode_half?dbg_hs_o_4k:dbg_hs_o_1080;
assign dbg_de_o=hdmi_mode_half?dbg_de_o_4k:dbg_de_o_1080;
assign dbg_val_o=hdmi_mode_half?dbg_val_o_4k:dbg_val_o_1080;
assign dbg_rgb=hdmi_mode_half?dbg_rgb_4k:dbg_rgb_1080;
debayer_top_2to1 u_debayer_1080 (
    .in_pclk     (hdmi_tx_half_clk),
    .in_rstn     (video_rst_n && !hdmi_mode_half),
    .raw_vs_i    (fb_vs),
    .raw_hs_i    (fb_hs),
    .raw_de_i    (fb_de),
    .raw_valid_i (fb_de),
    .raw_datax4_i(fb_vout),
    // Linear demosaic; per-channel display gains follow the stats tap.
    .i_r_gain    (3'd4),
    .i_g_gain    (3'd4),
    .i_b_gain    (3'd4),
    .rgb_vs_o    (dbg_vs_o_1080),
    .rgb_hs_o    (dbg_hs_o_1080),
    .rgb_de_o    (dbg_de_o_1080),
    .rgb_valid_o (dbg_val_o_1080),
    .rgb_datax2_o(dbg_rgb_1080)
);
debayer_top_2to1 #(.H_TOTAL(2200)) u_debayer_4k (
    .in_pclk     (hdmi_tx_half_clk),
    .in_rstn     (video_rst_n && hdmi_mode_half),
    .raw_vs_i    (fb_vs),
    .raw_hs_i    (fb_hs),
    .raw_de_i    (fb_de),
    .raw_valid_i (fb_de),
    .raw_datax4_i(fb_vout),
    // Linear demosaic; per-channel display gains follow the stats tap.
    .i_r_gain    (3'd4),
    .i_g_gain    (3'd4),
    .i_b_gain    (3'd4),
    .rgb_vs_o    (dbg_vs_o_4k),
    .rgb_hs_o    (dbg_hs_o_4k),
    .rgb_de_o    (dbg_de_o_4k),
    .rgb_valid_o (dbg_val_o_4k),
    .rgb_datax2_o(dbg_rgb_4k)
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
wire [50:0] af_din = {display_hs, display_vs, display_de, display_rgb};
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
wire hdmi_out_hs,hdmi_out_vs,hdmi_out_de;
wire [11:0] hdmi_word_width;
assign hdmi_width=hdmi_mode ? {hdmi_word_width[10:0],1'b0} : hdmi_word_width;
wire [7:0] hdmi_fps;
wire hdmi_upd;
video_size_meter #(.PIXELS_PER_CLOCK(4), .USE_HSYNC(1)) u_camera_size (
    .clk(mipi_pixel_clk), .rst_n(video_rst_n),
    .i_hs(fb_ihs), .i_vs(fb_ivs), .i_de(fb_ide),
    .o_width(cam_width), .o_height(cam_height), .o_toggle(cam_size_toggle)
);
video_size_meter #(.PIXELS_PER_CLOCK(1), .USE_HSYNC(0)) u_hdmi_size (
    .clk(hdmi_tx_slow_clk), .rst_n(video_rst_n),
    .i_hs(hdmi_out_hs), .i_vs(hdmi_out_vs), .i_de(hdmi_out_de),
    .o_width(hdmi_word_width), .o_height(hdmi_height), .o_toggle(hdmi_size_toggle)
);
reg [2:0] hdmi_vs_sync;
always @(posedge core_clk or negedge video_rst_n) begin
    if (!video_rst_n) hdmi_vs_sync<=0;
    else hdmi_vs_sync<={hdmi_vs_sync[1:0],hdmi_out_vs};
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

wire [9:0] tmds_data0, rgb_tmds0;
wire [9:0] tmds_data1, rgb_tmds1;
wire [9:0] tmds_data2, rgb_tmds2;
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
    .tmds_data0 (rgb_tmds0),
    .tmds_data1 (rgb_tmds1),
    .tmds_data2 (rgb_tmds2),
    .tmds_clk   (tmds_clk)
);

wire upscale_hs,upscale_vs,upscale_de,upscale_started;
wire [23:0] upscale_channels;
wire [11:0] upscale_x,upscale_y;
wire [9:0] yuv_tmds0,yuv_tmds1,yuv_tmds2;
upscale_420 u_upscale (
 .clk(hdmi_tx_slow_clk),.rst_n(video_rst_n),.enable(hdmi_mode),
 .i_hs(hs_r),.i_vs(vs_r),.i_de(de_r),.i_rgb(px_osd_ae),
 .o_hs(upscale_hs),.o_vs(upscale_vs),.o_de(upscale_de),.o_channels(upscale_channels),
 .o_x(upscale_x),.o_y(upscale_y),.o_started(upscale_started)
);
hdmi_420_tx u_hdmi_420 (
 .clk(hdmi_tx_slow_clk),.rst_n(video_rst_n&&hdmi_mode),
 .i_hs(upscale_hs),.i_vs(upscale_vs),.i_de(upscale_de),
 .i_channels(upscale_channels),.i_x(upscale_x),.i_y(upscale_y),
 .ch0(yuv_tmds0),.ch1(yuv_tmds1),.ch2(yuv_tmds2)
);
assign hdmi_out_hs=hdmi_mode?upscale_hs:hs_r;
assign hdmi_out_vs=hdmi_mode?upscale_vs:vs_r;
assign hdmi_out_de=hdmi_mode?upscale_de:de_r;
assign tmds_data0=hdmi_mode?yuv_tmds0:rgb_tmds0;
assign tmds_data1=hdmi_mode?yuv_tmds1:rgb_tmds1;
assign tmds_data2=hdmi_mode?yuv_tmds2:rgb_tmds2;

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
//=====================================================================
wire        RdEmpty;
wire        tx_valid;
wire        tx_req;
wire [7:0]  tx_data;
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
colour_capture u_colour_capture (
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
    .txd        (txd),
    .tx_valid   (tx_valid),
    .tx_data    (tx_data),
    .tx_req     (tx_req),
    .rx_valid   (rx_valid),
    .rx_data    (rx_data)
);

// Resolution is published with a frame toggle; sample its stable payload only
// after the toggle has crossed into the UART clock domain.
reg [2:0] output_size_sync,output_mode_sync;
reg [11:0] output_width_uart,output_height_uart;
always @(posedge gpio_clk_27m or negedge video_rst_n)begin
 if(!video_rst_n)begin output_size_sync<=0;output_mode_sync<=0;output_width_uart<=0;output_height_uart<=0;end
 else begin
  output_size_sync<={output_size_sync[1:0],hdmi_size_toggle};
  output_mode_sync<={output_mode_sync[1:0],hdmi_mode};
  if(output_size_sync[2]!=output_size_sync[1])begin
   output_width_uart<=hdmi_width;output_height_uart<=hdmi_height;
  end
 end
end
ae_uart_log #(.VIDEO_STATUS(1)) u_ae_log (
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
    .i_4k(output_mode_sync[2]),.i_output_width(output_width_uart),.i_output_height(output_height_uart),
    .tx_req    (tx_req),
    .tx_valid  (log_dv),
    .tx_data   (log_data),
    .tx_gate   (log_gate),
    .fifo_act  (fifo_act)
);

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
// AXI4 -> shared-address bridge (frame buffer -> DDR3 soft controller)
//=====================================================================
axi_atype_bridge #(
    .IDW (4),
    .AW  (28)
) u_axi_atype_bridge (
    .clk         (core_clk),
    .rst_n       (core_pll_locked & ddr_pll_locked),

    .s_awid      (fb_awid[3:0]),
    .s_awaddr    (fb_awaddr),
    .s_awlen     (fb_awlen),
    .s_awsize    (fb_awsize),
    .s_awburst   (fb_awburst),
    .s_awlock    (fb_awlock),
    .s_awvalid   (fb_awvalid),
    .s_awready   (fb_awready),

    .s_arid      (fb_arid[3:0]),
    .s_araddr    (fb_araddr),
    .s_arlen     (fb_arlen),
    .s_arsize    (fb_arsize),
    .s_arburst   (fb_arburst),
    .s_arlock    (fb_arlock),
    .s_arvalid   (fb_arvalid),
    .s_arready   (fb_arready),

    .m_aid       (ddr_ax_aid),
    .m_aaddr     (ddr_ax_aaddr),
    .m_alen      (ddr_ax_alen),
    .m_asize     (ddr_ax_asize),
    .m_aburst    (ddr_ax_aburst),
    .m_alock     (ddr_ax_alock),
    .m_atype     (ddr_ax_atype),
    .m_avalid    (ddr_ax_avalid),
    .m_aready    (ddr_ax_aready),

    .bvalid      (fb_bvalid),
    .bready      (fb_bready),
    .rvalid      (fb_rvalid),
    .rlast       (fb_rlast),
    .rready      (fb_rready)
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

    .axi_wid          ({2'b0, fb_awid}),
    .axi_wdata        (fb_wdata),
    .axi_wstrb        (fb_wstrb),
    .axi_wlast        (fb_wlast),
    .axi_wvalid       (fb_wvalid),
    .axi_wready       (fb_wready),

    .axi_rid          (fb_rid8),
    .axi_rdata        (fb_rdata),
    .axi_rlast        (fb_rlast),
    .axi_rvalid       (fb_rvalid),
    .axi_rready       (fb_rready),
    .axi_rresp        (fb_rresp),

    .axi_bid          (fb_bid8),
    .axi_bresp        (fb_bresp),
    .axi_bvalid       (fb_bvalid),
    .axi_bready       (fb_bready),

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
assign led[3] = hdmi_mode; // lit = 4K30 4:2:0 mode

endmodule
