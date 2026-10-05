//=====================================================================
// axi_ddr_arbiter: 3-master AXI4 merger for the shared Iris DDR3 path.
//
//   S0: video frame buffer  (frame_buffer, 28-bit addr widened here)
//   S1: Sapphire CPU        (tinyml_subsystem io_ddrA conversion)
//   S2: TinyML accelerator  (tinyml_subsystem m_axi)
//   M : axi_atype_bridge    (existing AW/AR -> efx_ddr3_axi atype bridge)
//
// Design contract (docs/TinyML_移植进度与待办.md #3):
//   * Exactly ONE write transaction and ONE read transaction are in flight
//     downstream at any time.  The write (read) grant is held from address
//     acceptance until its B (RLAST) response returns, so responses are
//     attributed by grant instead of by AXI ID - IDs may legally collide
//     across masters and only ride along for the controller's echo.
//   * Read and write directions are granted independently and run
//     concurrently; the downstream bridge already time-multiplexes their
//     addresses and the DDR3 controller supports overlapping R/W bursts
//     (see axi_atype_bridge.v header).
//   * Round-robin between masters within each direction, so the display
//     read path waits at most two other bursts per direction.
//   * Address range check: any slave address with addr[31:28] != 0 is not
//     mapped (Iris DDR3 = 256 MiB at 0x00000000, video [0, 0x5F4000),
//     compute window >= 0x00800000).  Such transactions never reach the
//     controller: the arbiter sinks them and answers SLVERR locally so a
//     firmware bug reports an error instead of aliasing into video memory.
//   * Write data is only accepted after that burst's address handshake
//     (AXI permits a slave to wait for AWVALID before WREADY); this is what
//     makes the range check possible before any beat reaches DDR.
//
// Known limitation (accepted for bring-up, revisit in #7): one outstanding
// burst per direction caps small-transfer efficiency for the CPU.  Video
// bursts are 128 beats and dominate bandwidth, which round-robin protects.
//=====================================================================
module axi_ddr_arbiter #(
    parameter DW  = 128,
    parameter IDW = 8,
    parameter MAW = 28            // downstream address width (efx_ddr3_axi)
) (
    input  wire            clk,
    input  wire            rst_n,

    //---------------- S0: video frame buffer ----------------
    input  wire [IDW-1:0]  s0_awid,
    input  wire [31:0]     s0_awaddr,
    input  wire [7:0]      s0_awlen,
    input  wire [2:0]      s0_awsize,
    input  wire [1:0]      s0_awburst,
    input  wire            s0_awlock,
    input  wire            s0_awvalid,
    output wire            s0_awready,
    input  wire [DW-1:0]   s0_wdata,
    input  wire [DW/8-1:0] s0_wstrb,
    input  wire            s0_wlast,
    input  wire            s0_wvalid,
    output wire            s0_wready,
    output wire [IDW-1:0]  s0_bid,
    output wire [1:0]      s0_bresp,
    output wire            s0_bvalid,
    input  wire            s0_bready,
    input  wire [IDW-1:0]  s0_arid,
    input  wire [31:0]     s0_araddr,
    input  wire [7:0]      s0_arlen,
    input  wire [2:0]      s0_arsize,
    input  wire [1:0]      s0_arburst,
    input  wire            s0_arlock,
    input  wire            s0_arvalid,
    output wire            s0_arready,
    output wire [DW-1:0]   s0_rdata,
    output wire [IDW-1:0]  s0_rid,
    output wire [1:0]      s0_rresp,
    output wire            s0_rlast,
    output wire            s0_rvalid,
    input  wire            s0_rready,

    //---------------- S1: Sapphire CPU ----------------
    input  wire [IDW-1:0]  s1_awid,
    input  wire [31:0]     s1_awaddr,
    input  wire [7:0]      s1_awlen,
    input  wire [2:0]      s1_awsize,
    input  wire [1:0]      s1_awburst,
    input  wire            s1_awlock,
    input  wire            s1_awvalid,
    output wire            s1_awready,
    input  wire [DW-1:0]   s1_wdata,
    input  wire [DW/8-1:0] s1_wstrb,
    input  wire            s1_wlast,
    input  wire            s1_wvalid,
    output wire            s1_wready,
    output wire [IDW-1:0]  s1_bid,
    output wire [1:0]      s1_bresp,
    output wire            s1_bvalid,
    input  wire            s1_bready,
    input  wire [IDW-1:0]  s1_arid,
    input  wire [31:0]     s1_araddr,
    input  wire [7:0]      s1_arlen,
    input  wire [2:0]      s1_arsize,
    input  wire [1:0]      s1_arburst,
    input  wire            s1_arlock,
    input  wire            s1_arvalid,
    output wire            s1_arready,
    output wire [DW-1:0]   s1_rdata,
    output wire [IDW-1:0]  s1_rid,
    output wire [1:0]      s1_rresp,
    output wire            s1_rlast,
    output wire            s1_rvalid,
    input  wire            s1_rready,

    //---------------- S2: TinyML accelerator ----------------
    input  wire [IDW-1:0]  s2_awid,
    input  wire [31:0]     s2_awaddr,
    input  wire [7:0]      s2_awlen,
    input  wire [2:0]      s2_awsize,
    input  wire [1:0]      s2_awburst,
    input  wire            s2_awlock,
    input  wire            s2_awvalid,
    output wire            s2_awready,
    input  wire [DW-1:0]   s2_wdata,
    input  wire [DW/8-1:0] s2_wstrb,
    input  wire            s2_wlast,
    input  wire            s2_wvalid,
    output wire            s2_wready,
    output wire [IDW-1:0]  s2_bid,
    output wire [1:0]      s2_bresp,
    output wire            s2_bvalid,
    input  wire            s2_bready,
    input  wire [IDW-1:0]  s2_arid,
    input  wire [31:0]     s2_araddr,
    input  wire [7:0]      s2_arlen,
    input  wire [2:0]      s2_arsize,
    input  wire [1:0]      s2_arburst,
    input  wire            s2_arlock,
    input  wire            s2_arvalid,
    output wire            s2_arready,
    output wire [DW-1:0]   s2_rdata,
    output wire [IDW-1:0]  s2_rid,
    output wire [1:0]      s2_rresp,
    output wire            s2_rlast,
    output wire            s2_rvalid,
    input  wire            s2_rready,

    //---------------- M: axi_atype_bridge ----------------
    output wire [IDW-1:0]  m_awid,
    output wire [MAW-1:0]  m_awaddr,
    output wire [7:0]      m_awlen,
    output wire [2:0]      m_awsize,
    output wire [1:0]      m_awburst,
    output wire            m_awlock,
    output wire            m_awvalid,
    input  wire            m_awready,
    output wire [DW-1:0]   m_wdata,
    output wire [DW/8-1:0] m_wstrb,
    output wire            m_wlast,
    output wire            m_wvalid,
    input  wire            m_wready,
    input  wire [IDW-1:0]  m_bid,
    input  wire [1:0]      m_bresp,
    input  wire            m_bvalid,
    output wire            m_bready,
    output wire [IDW-1:0]  m_arid,
    output wire [MAW-1:0]  m_araddr,
    output wire [7:0]      m_arlen,
    output wire [2:0]      m_arsize,
    output wire [1:0]      m_arburst,
    output wire            m_arlock,
    output wire            m_arvalid,
    input  wire            m_arready,
    input  wire [DW-1:0]   m_rdata,
    input  wire [IDW-1:0]  m_rid,
    input  wire [1:0]      m_rresp,
    input  wire            m_rlast,
    input  wire            m_rvalid,
    output wire            m_rready,

    // Write ID the DDR3 controller must echo on W beats (captured at AW).
    // W beats are only forwarded after the AW handshake, so this is stable
    // for the whole burst.
    output reg  [IDW-1:0]  m_wid,

    // ---------------- bring-up observation bank ----------------
    // Read by the CPU (or the debug module's system-bus access) through the
    // SoC's APB slave 1 while bringing the shared-DDR path up on hardware.
    output reg  [31:0]     dbg_last_ar_addr,
    output reg  [7:0]      dbg_last_ar_len,
    output reg  [2:0]      dbg_last_ar_size,
    output reg  [1:0]      dbg_last_ar_burst,
    output reg  [31:0]     dbg_last_aw_addr,
    output reg  [7:0]      dbg_last_aw_len,
    output reg  [1:0]      dbg_last_bresp,
    output reg  [1:0]      dbg_last_rresp,
    output reg  [15:0]     dbg_rd_cnt,       // completed reads (RLAST)
    output reg  [15:0]     dbg_wr_cnt,       // completed writes (B)
    output reg  [7:0]      dbg_rd_err_cnt,   // RRESP != OKAY beats
    output reg  [7:0]      dbg_wr_err_cnt,   // BRESP != OKAY
    output reg  [31:0]     dbg_cpu_ar_addr,  // last AR accepted for master 1 (CPU)
    output reg  [31:0]     dbg_fb_ar_addr,   // last AR accepted for master 0 (video)
    output reg  [31:0]     dbg_cpu_aw_addr,  // last AW accepted for master 1
    output reg  [31:0]     dbg_fb_aw_addr,   // last AW accepted for master 0
    output reg  [15:0]     dbg_m_ar_cnt,     // downstream AR handshakes (all masters)
    output reg  [15:0]     dbg_m_aw_cnt,     // downstream AW handshakes (all masters)
    output reg  [15:0]     dbg_cpu_rd_cnt,   // completed reads granted to CPU
    output reg  [15:0]     dbg_fb_rd_cnt,    // completed reads granted to video
    output wire [7:0]      dbg_state         // {rd_err,rd_owner[1:0],rd_ar_done,rd_busy,
                                              //  wr_err,wr_owner[1:0],wr_busy}
);

    localparam [1:0] RSP_OKAY   = 2'b00;
    localparam [1:0] RSP_SLVERR = 2'b10;

    //=================================================================
    // Output pipeline slices (AW / AR / W / R).
    //
    // On hardware the shared path showed intermittent corruption of
    // addresses and data under video+CPU concurrency while STA margin at
    // 100 MHz was only ~2 ps - the comb chain fb_awaddr -> owner-mux ->
    // atype-bridge -> efx input FF (two mux levels plus long routing)
    // was effectively unmarginally long on real silicon.  Each channel
    // now passes through a one-entry elastic register: the muxes drive
    // flip-flops, and the bridge/efx side is driven from flip-flops.
    // Cost is one cycle of latency per channel.
    //=================================================================
    wire i_awready;   // slice accepts a new AW
    wire i_arready;   // slice accepts a new AR
    wire i_wready;    // slice accepts a new W beat
    wire i_rvalid;    // slice presents an R beat
    wire i_rlast;
    wire [DW-1:0]   i_rdata;
    wire [IDW-1:0]  i_rid;
    wire [1:0]      i_rresp;

    //=================================================================
    // Shared address-channel pacing.
    // The Efinix DDR3 controller's single (atype) address port was
    // previously only ever fed the frame buffer's sparse address stream
    // (one read address per line, see axi_atype_bridge.v).  The shared
    // path now delivers back-to-back CPU/cache-fill addresses.  Enforce
    // >=2 idle cycles between accepted addresses by delaying new grants;
    // this is AXI-legal (valid is only presented after a grant).
    //=================================================================
    reg [1:0] addr_gap;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          addr_gap <= 2'd0;
        else if ((m_awvalid && m_awready) ||
                 (m_arvalid && m_arready))   addr_gap <= 2'd2;
        else if (addr_gap != 2'd0)           addr_gap <= addr_gap - 2'd1;
    end
    wire grant_gate = (addr_gap == 2'd0);

    // AW / W output slice registers
    reg             awq_v;
    reg             aw_sent;   // current burst's AW handshaken downstream
    reg  [IDW-1:0]  awq_id;
    reg  [MAW-1:0]  awq_addr;
    reg  [7:0]      awq_len;
    reg  [2:0]      awq_size;
    reg  [1:0]      awq_burst;
    reg             awq_lock;
    reg             wq_v;
    reg  [DW-1:0]   wq_data;
    reg  [DW/8-1:0] wq_strb;
    reg             wq_last;

    //=================================================================
    // Write path
    //=================================================================
    reg  [1:0]  wr_owner;
    reg  [1:0]  wr_ptr;
    reg         wr_busy;
    reg         wr_aw_done;
    reg         wr_w_done;
    reg         wr_err;

    wire [2:0]  wr_req = { (s2_awvalid | s2_wvalid),
                           (s1_awvalid | s1_wvalid),
                           (s0_awvalid | s0_wvalid) };

    // round-robin pick starting at wr_ptr
    reg  [1:0]  wr_pick;
    reg         wr_pick_v;
    integer     woff;
    integer     widx;
    always @* begin
        wr_pick_v = 1'b0;
        wr_pick   = 2'd0;
        for (woff = 0; woff < 3; woff = woff + 1) begin
            widx = wr_ptr + woff;
            if (widx > 2) widx = widx - 3;
            if (!wr_pick_v && wr_req[widx]) begin
                wr_pick_v = 1'b1;
                wr_pick   = widx[1:0];
            end
        end
    end

    // owner-muxed write address
    reg  [31:0] w_addr;
    reg  [IDW-1:0] w_id;
    reg  [7:0]  w_len;
    reg  [2:0]  w_size;
    reg  [1:0]  w_burst;
    reg         w_lock;
    reg         w_awvalid;
    always @* begin
        case (wr_owner)
            2'd0:    begin w_addr = s0_awaddr; w_id = s0_awid; w_len = s0_awlen;
                           w_size = s0_awsize; w_burst = s0_awburst;
                           w_lock = s0_awlock; w_awvalid = s0_awvalid; end
            2'd1:    begin w_addr = s1_awaddr; w_id = s1_awid; w_len = s1_awlen;
                           w_size = s1_awsize; w_burst = s1_awburst;
                           w_lock = s1_awlock; w_awvalid = s1_awvalid; end
            default: begin w_addr = s2_awaddr; w_id = s2_awid; w_len = s2_awlen;
                           w_size = s2_awsize; w_burst = s2_awburst;
                           w_lock = s2_awlock; w_awvalid = s2_awvalid; end
        endcase
    end
    wire w_addr_err = (w_addr[31:28] != 4'h0);

    // owner-muxed write data
    reg  [DW-1:0]   w_data;
    reg  [DW/8-1:0] w_strb;
    reg             w_wlast;
    reg             w_wvalid;
    always @* begin
        case (wr_owner)
            2'd0:    begin w_data = s0_wdata; w_strb = s0_wstrb;
                           w_wlast = s0_wlast; w_wvalid = s0_wvalid; end
            2'd1:    begin w_data = s1_wdata; w_strb = s1_wstrb;
                           w_wlast = s1_wlast; w_wvalid = s1_wvalid; end
            default: begin w_data = s2_wdata; w_strb = s2_wstrb;
                           w_wlast = s2_wlast; w_wvalid = s2_wvalid; end
        endcase
    end

    wire w_aw_hs = wr_busy & ~wr_aw_done & w_awvalid &
                   (w_addr_err | i_awready);
    wire w_aw_fwd = wr_busy & ~wr_aw_done & ~w_addr_err & w_awvalid;

    // AW-before-W invariant at the DOWNSTREAM side: the address pipeline
    // slice can hold the AW for a cycle or two while the data slice would
    // otherwise race ahead.  Write data may only be presented downstream
    // after this burst's AW has actually handshaken with the atype bridge
    // (w_addr_err bursts never reach the bridge and use the local sink).
    // The pre-slice arbiter guaranteed this ordering; keep it.
    wire w_aw_delivered = wr_busy & ~wr_err & awq_v & m_awready;
    wire w_data_ok      = wr_busy & wr_aw_done & ~wr_err & aw_sent;

    wire w_w_fwd = w_data_ok & w_wvalid;
    wire w_w_sink = wr_busy & wr_aw_done & wr_err;         // discard beats
    wire w_w_hs_last = (w_w_fwd & i_wready & w_wlast) |
                       (w_w_sink & w_wvalid & w_wlast);

    // owner B routing (declared before the done equations that consume them)
    reg  w_bready_i;
    reg  s_bvalid_mux;
    reg  [1:0] bresp_mux;

    wire wr_err_done  = wr_busy & wr_err & wr_aw_done & wr_w_done;
    wire wr_norm_done = wr_busy & ~wr_err & m_bvalid & w_bready_i;

    always @* begin
        s_bvalid_mux = 1'b0;
        bresp_mux    = m_bresp;
        if (wr_busy) begin
            if (wr_err) begin
                s_bvalid_mux = wr_aw_done & wr_w_done;
                bresp_mux    = RSP_SLVERR;
            end else begin
                s_bvalid_mux = m_bvalid;
            end
        end
    end

    always @* begin
        case (wr_owner)
            2'd0:    w_bready_i = s0_bready;
            2'd1:    w_bready_i = s1_bready;
            default: w_bready_i = s2_bready;
        endcase
    end

    // The local SLVERR response must echo the burst's own ID: masters may
    // compare it against the AWID they issued.
    wire [IDW-1:0] wr_bid_mux = wr_err ? m_wid : m_bid;

    // per-slave B outputs
    assign s0_bvalid = (wr_owner == 2'd0) & s_bvalid_mux;
    assign s1_bvalid = (wr_owner == 2'd1) & s_bvalid_mux;
    assign s2_bvalid = (wr_owner == 2'd2) & s_bvalid_mux;
    assign s0_bresp  = bresp_mux;
    assign s1_bresp  = bresp_mux;
    assign s2_bresp  = bresp_mux;
    assign s0_bid    = wr_bid_mux;
    assign s1_bid    = wr_bid_mux;
    assign s2_bid    = wr_bid_mux;

    wire wr_done = wr_norm_done | (wr_err_done & w_bready_i);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_busy   <= 1'b0;
            wr_owner  <= 2'd0;
            wr_ptr    <= 2'd0;
            wr_aw_done<= 1'b0;
            wr_w_done <= 1'b0;
            wr_err    <= 1'b0;
            aw_sent   <= 1'b0;
            m_wid     <= {IDW{1'b0}};
        end else if (!wr_busy) begin
            if (wr_pick_v && grant_gate) begin
                wr_busy    <= 1'b1;
                wr_owner   <= wr_pick;
                wr_aw_done <= 1'b0;
                wr_w_done  <= 1'b0;
                wr_err     <= 1'b0;
                aw_sent    <= 1'b0;
            end
        end else begin
            if (w_aw_hs) begin
                wr_aw_done <= 1'b1;
                wr_err     <= w_addr_err;
                m_wid      <= w_id;
            end
            if (w_aw_delivered)
                aw_sent <= 1'b1;
            if (w_w_hs_last)
                wr_w_done <= 1'b1;
            if (wr_done) begin
                wr_busy    <= 1'b0;
                wr_ptr     <= (wr_owner == 2'd2) ? 2'd0 : wr_owner + 2'd1;
                wr_aw_done <= 1'b0;
                wr_w_done  <= 1'b0;
                wr_err     <= 1'b0;
                aw_sent    <= 1'b0;
            end
        end
    end

    // write-side slave outputs
    assign s0_awready = (wr_owner == 2'd0) & wr_busy & ~wr_aw_done &
                        (w_addr_err | i_awready);
    assign s1_awready = (wr_owner == 2'd1) & wr_busy & ~wr_aw_done &
                        (w_addr_err | i_awready);
    assign s2_awready = (wr_owner == 2'd2) & wr_busy & ~wr_aw_done &
                        (w_addr_err | i_awready);

    // Write data ready: stall beats until this burst's AW has been accepted
    // (needed for the range check), sink them on the local error path, and
    // otherwise follow the downstream ready.  Ready must not depend on valid.
    wire w_wready_o = wr_busy & wr_aw_done &
                      (wr_err ? 1'b1 : (aw_sent & i_wready));
    assign s0_wready = (wr_owner == 2'd0) & w_wready_o;
    assign s1_wready = (wr_owner == 2'd1) & w_wready_o;
    assign s2_wready = (wr_owner == 2'd2) & w_wready_o;

    // write-side master outputs (pipeline slice)
    assign i_awready = ~awq_v | m_awready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awq_v <= 1'b0;
        end else if (w_aw_fwd && i_awready) begin
            awq_v     <= 1'b1;
            awq_id    <= w_id;
            awq_addr  <= w_addr[MAW-1:0];
            awq_len   <= w_len;
            awq_size  <= w_size;
            awq_burst <= w_burst;
            awq_lock  <= w_lock;
        end else if (m_awready) begin
            awq_v <= 1'b0;
        end
    end
    assign m_awvalid = awq_v;
    assign m_awid    = awq_id;
    assign m_awaddr  = awq_addr;
    assign m_awlen   = awq_len;
    assign m_awsize  = awq_size;
    assign m_awburst = awq_burst;
    assign m_awlock  = awq_lock;

    assign i_wready = ~wq_v | m_wready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wq_v <= 1'b0;
        end else if (w_w_fwd && i_wready) begin
            wq_v    <= 1'b1;
            wq_data <= w_data;
            wq_strb <= w_strb;
            wq_last <= w_wlast;
        end else if (m_wready) begin
            wq_v <= 1'b0;
        end
    end
    assign m_wvalid = wq_v;
    assign m_wdata  = wq_data;
    assign m_wstrb  = wq_strb;
    assign m_wlast  = wq_last;
    assign m_bready = wr_busy & ~wr_err & w_bready_i;

    // AR output slice / R input slice registers
    reg             arq_v;
    reg  [IDW-1:0]  arq_id;
    reg  [MAW-1:0]  arq_addr;
    reg  [7:0]      arq_len;
    reg  [2:0]      arq_size;
    reg  [1:0]      arq_burst;
    reg             arq_lock;
    reg             rq_v;
    reg  [DW-1:0]   rq_data;
    reg  [IDW-1:0]  rq_id;
    reg  [1:0]      rq_resp;
    reg             rq_last;

    //=================================================================
    // Read path
    //=================================================================
    reg  [1:0]  rd_owner;
    reg  [1:0]  rd_ptr;
    reg         rd_busy;
    reg         rd_ar_done;
    reg         rd_err;
    reg  [7:0]  rd_len_q;
    reg  [7:0]  rd_beats;
    reg  [IDW-1:0] rd_arid_q;   // captured at AR handshake (err RID echo)

    wire [2:0]  rd_req = { s2_arvalid, s1_arvalid, s0_arvalid };

    reg  [1:0]  rd_pick;
    reg         rd_pick_v;
    integer     roff;
    integer     ridx;
    always @* begin
        rd_pick_v = 1'b0;
        rd_pick   = 2'd0;
        for (roff = 0; roff < 3; roff = roff + 1) begin
            ridx = rd_ptr + roff;
            if (ridx > 2) ridx = ridx - 3;
            if (!rd_pick_v && rd_req[ridx]) begin
                rd_pick_v = 1'b1;
                rd_pick   = ridx[1:0];
            end
        end
    end

    reg  [31:0] r_addr;
    reg  [IDW-1:0] r_id;
    reg  [7:0]  r_len;
    reg  [2:0]  r_size;
    reg  [1:0]  r_burst;
    reg         r_lock;
    reg         r_arvalid;
    always @* begin
        case (rd_owner)
            2'd0:    begin r_addr = s0_araddr; r_id = s0_arid; r_len = s0_arlen;
                           r_size = s0_arsize; r_burst = s0_arburst;
                           r_lock = s0_arlock; r_arvalid = s0_arvalid; end
            2'd1:    begin r_addr = s1_araddr; r_id = s1_arid; r_len = s1_arlen;
                           r_size = s1_arsize; r_burst = s1_arburst;
                           r_lock = s1_arlock; r_arvalid = s1_arvalid; end
            default: begin r_addr = s2_araddr; r_id = s2_arid; r_len = s2_arlen;
                           r_size = s2_arsize; r_burst = s2_arburst;
                           r_lock = s2_arlock; r_arvalid = s2_arvalid; end
        endcase
    end
    wire r_addr_err = (r_addr[31:28] != 4'h0);

    wire r_ar_hs = rd_busy & ~rd_ar_done & r_arvalid &
                   (r_addr_err | i_arready);
    wire r_ar_fwd = rd_busy & ~rd_ar_done & ~r_addr_err & r_arvalid;

    // error-path beat generator: one beat per accepted rready
    wire r_err_beat = rd_busy & rd_ar_done & rd_err;
    wire r_err_last = r_err_beat & (rd_beats == 8'd0);

    // normal path: downstream R routed to owner (only once our AR has been
    // accepted downstream, so a stale rvalid cannot leak before that)
    reg r_rvalid_mux;
    always @* begin
        r_rvalid_mux = 1'b0;
        if (rd_busy && rd_ar_done && !rd_err) r_rvalid_mux = i_rvalid;
        if (r_err_beat)                       r_rvalid_mux = 1'b1;
    end

    reg r_rready_i;
    always @* begin
        case (rd_owner)
            2'd0:    r_rready_i = s0_rready;
            2'd1:    r_rready_i = s1_rready;
            default: r_rready_i = s2_rready;
        endcase
    end

    assign s0_rvalid = (rd_owner == 2'd0) & r_rvalid_mux;
    assign s1_rvalid = (rd_owner == 2'd1) & r_rvalid_mux;
    assign s2_rvalid = (rd_owner == 2'd2) & r_rvalid_mux;

    assign s0_rdata  = rd_err ? {DW{1'b0}} : i_rdata;
    assign s1_rdata  = rd_err ? {DW{1'b0}} : i_rdata;
    assign s2_rdata  = rd_err ? {DW{1'b0}} : i_rdata;
    assign s0_rid    = rd_err ? rd_arid_q : i_rid;
    assign s1_rid    = rd_err ? rd_arid_q : i_rid;
    assign s2_rid    = rd_err ? rd_arid_q : i_rid;
    assign s0_rresp  = rd_err ? RSP_SLVERR : i_rresp;
    assign s1_rresp  = rd_err ? RSP_SLVERR : i_rresp;
    assign s2_rresp  = rd_err ? RSP_SLVERR : i_rresp;
    assign s0_rlast  = rd_err ? r_err_last : i_rlast;
    assign s1_rlast  = rd_err ? r_err_last : i_rlast;
    assign s2_rlast  = rd_err ? r_err_last : i_rlast;

    wire rd_done_norm = rd_busy & rd_ar_done & ~rd_err &
                        i_rvalid & i_rlast & r_rready_i;
    wire rd_done_err  = r_err_last & r_rready_i;
    wire rd_done      = rd_done_norm | rd_done_err;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_busy    <= 1'b0;
            rd_owner   <= 2'd0;
            rd_ptr     <= 2'd0;
            rd_ar_done <= 1'b0;
            rd_err     <= 1'b0;
            rd_len_q   <= 8'd0;
            rd_beats   <= 8'd0;
            rd_arid_q  <= {IDW{1'b0}};
        end else if (!rd_busy) begin
            if (rd_pick_v && grant_gate) begin
                rd_busy    <= 1'b1;
                rd_owner   <= rd_pick;
                rd_ar_done <= 1'b0;
                rd_err     <= 1'b0;
            end
        end else begin
            if (r_ar_hs) begin
                rd_ar_done <= 1'b1;
                rd_err     <= r_addr_err;
                rd_len_q   <= r_len;
                rd_beats   <= r_len;         // beats after the first
                rd_arid_q  <= r_id;
            end
            if (r_err_beat && r_rready_i && rd_beats != 8'd0)
                rd_beats <= rd_beats - 8'd1;
            if (rd_done) begin
                rd_busy    <= 1'b0;
                rd_ptr     <= (rd_owner == 2'd2) ? 2'd0 : rd_owner + 2'd1;
                rd_ar_done <= 1'b0;
                rd_err     <= 1'b0;
            end
        end
    end

    // read-side slave outputs
    assign s0_arready = (rd_owner == 2'd0) & rd_busy & ~rd_ar_done &
                        (r_addr_err | i_arready);
    assign s1_arready = (rd_owner == 2'd1) & rd_busy & ~rd_ar_done &
                        (r_addr_err | i_arready);
    assign s2_arready = (rd_owner == 2'd2) & rd_busy & ~rd_ar_done &
                        (r_addr_err | i_arready);

    // read-side master outputs (AR input slice / R output slice)
    assign i_arready = ~arq_v | m_arready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arq_v <= 1'b0;
        end else if (r_ar_fwd && i_arready) begin
            arq_v     <= 1'b1;
            arq_id    <= r_id;
            arq_addr  <= r_addr[MAW-1:0];
            arq_len   <= r_len;
            arq_size  <= r_size;
            arq_burst <= r_burst;
            arq_lock  <= r_lock;
        end else if (m_arready) begin
            arq_v <= 1'b0;
        end
    end
    assign m_arvalid = arq_v;
    assign m_arid    = arq_id;
    assign m_araddr  = arq_addr;
    assign m_arlen   = arq_len;
    assign m_arsize  = arq_size;
    assign m_arburst = arq_burst;
    assign m_arlock  = arq_lock;

    // R beat coming back from the controller is registered before the
    // owner mux, and only released to the owner when the owner is ready.
    wire r_consume = rd_busy & ~rd_err & r_rready_i;
    assign m_rready = ~rq_v | r_consume;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq_v <= 1'b0;
        end else if (m_rvalid && m_rready) begin
            rq_v    <= 1'b1;
            rq_data <= m_rdata;
            rq_id   <= m_rid;
            rq_resp <= m_rresp;
            rq_last <= m_rlast;
        end else if (r_consume) begin
            rq_v <= 1'b0;
        end
    end
    assign i_rvalid = rq_v;
    assign i_rdata  = rq_data;
    assign i_rid    = rq_id;
    assign i_rresp  = rq_resp;
    assign i_rlast  = rq_last;

    // verilator lint_off UNUSED
    wire _unused_rd = &{1'b0, rd_len_q, RSP_OKAY, 1'b0};
    // verilator lint_on UNUSED


    //=================================================================
    // Bring-up observation (single clock, no functional influence)
    //=================================================================
    assign dbg_state = {rd_err, rd_owner, rd_ar_done, rd_busy,
                        wr_err, wr_owner, wr_busy};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_last_ar_addr  <= 32'd0;
            dbg_last_ar_len   <= 8'd0;
            dbg_last_ar_size  <= 3'd0;
            dbg_last_ar_burst <= 2'd0;
            dbg_last_aw_addr  <= 32'd0;
            dbg_last_aw_len   <= 8'd0;
            dbg_last_bresp    <= 2'd0;
            dbg_last_rresp    <= 2'd0;
            dbg_rd_cnt        <= 16'd0;
            dbg_wr_cnt        <= 16'd0;
            dbg_rd_err_cnt    <= 8'd0;
            dbg_wr_err_cnt    <= 8'd0;
            dbg_cpu_ar_addr   <= 32'd0;
            dbg_fb_ar_addr    <= 32'd0;
            dbg_cpu_aw_addr   <= 32'd0;
            dbg_fb_aw_addr    <= 32'd0;
            dbg_cpu_rd_cnt    <= 16'd0;
            dbg_fb_rd_cnt     <= 16'd0;
            dbg_m_ar_cnt      <= 16'd0;
            dbg_m_aw_cnt      <= 16'd0;
        end else begin
            if (m_arvalid && m_arready) begin
                dbg_m_ar_cnt      <= dbg_m_ar_cnt + 16'd1;
                dbg_last_ar_addr  <= {4'h0, m_araddr};
                dbg_last_ar_len   <= m_arlen;
                dbg_last_ar_size  <= m_arsize;
                dbg_last_ar_burst <= m_arburst;
                if (rd_owner == 2'd1) dbg_cpu_ar_addr <= {4'h0, m_araddr};
                if (rd_owner == 2'd0) dbg_fb_ar_addr  <= {4'h0, m_araddr};
            end
            if (m_awvalid && m_awready) begin
                dbg_m_aw_cnt     <= dbg_m_aw_cnt + 16'd1;
                dbg_last_aw_addr <= {4'h0, m_awaddr};
                dbg_last_aw_len  <= m_awlen;
                if (wr_owner == 2'd1) dbg_cpu_aw_addr <= {4'h0, m_awaddr};
                if (wr_owner == 2'd0) dbg_fb_aw_addr  <= {4'h0, m_awaddr};
            end
            if (m_bvalid && m_bready) begin
                dbg_wr_cnt     <= dbg_wr_cnt + 16'd1;
                dbg_last_bresp <= m_bresp;
                if (m_bresp != 2'b00 && dbg_wr_err_cnt != 8'hff)
                    dbg_wr_err_cnt <= dbg_wr_err_cnt + 8'd1;
            end
            if (m_rvalid && m_rready) begin
                dbg_last_rresp <= m_rresp;
                if (m_rresp != 2'b00 && dbg_rd_err_cnt != 8'hff)
                    dbg_rd_err_cnt <= dbg_rd_err_cnt + 8'd1;
            end
            if (m_rvalid && m_rready && m_rlast) begin
                dbg_rd_cnt <= dbg_rd_cnt + 16'd1;
                if (rd_owner == 2'd1) dbg_cpu_rd_cnt <= dbg_cpu_rd_cnt + 16'd1;
                if (rd_owner == 2'd0) dbg_fb_rd_cnt  <= dbg_fb_rd_cnt + 16'd1;
            end
        end
    end

endmodule
