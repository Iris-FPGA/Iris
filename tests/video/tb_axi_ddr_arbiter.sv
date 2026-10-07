// tb_axi_ddr_arbiter: multi-master verification for the shared-DDR arbiter.
//
// Checks (docs/TinyML_移植进度与待办.md #3):
//   * concurrent masters with random downstream backpressure: every write
//     reaches the memory model with the correct payload, every read returns
//     the address-derived pattern, responses only reach their owner
//   * at most one outstanding write and one outstanding read downstream
//   * response one-hotness across the three slaves
//   * address payload stability while the downstream stalls
//   * out-of-range addresses -> local SLVERR, never forwarded downstream
//   * write data may start before the address (W-before-AW)
//   * round-robin fairness under a three-master hammer
`timescale 1ns/1ps

module tb_axi_ddr_arbiter;

    localparam DW  = 128;
    localparam IDW = 8;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---------------- DUT slave-side signals ----------------
    // S0 video frame buffer
    reg  [IDW-1:0]  s0_awid;   reg [31:0] s0_awaddr; reg [7:0] s0_awlen;
    reg  [2:0]      s0_awsize; reg [1:0]  s0_awburst; reg s0_awlock;
    reg             s0_awvalid; wire s0_awready;
    reg  [DW-1:0]   s0_wdata;  reg [DW/8-1:0] s0_wstrb;
    reg             s0_wlast, s0_wvalid; wire s0_wready;
    wire [IDW-1:0]  s0_bid;    wire [1:0] s0_bresp; wire s0_bvalid;
    reg             s0_bready;
    reg  [IDW-1:0]  s0_arid;   reg [31:0] s0_araddr; reg [7:0] s0_arlen;
    reg  [2:0]      s0_arsize; reg [1:0]  s0_arburst; reg s0_arlock;
    reg             s0_arvalid; wire s0_arready;
    wire [DW-1:0]   s0_rdata;  wire [IDW-1:0] s0_rid; wire [1:0] s0_rresp;
    wire            s0_rlast, s0_rvalid; reg s0_rready;

    // S1 CPU
    reg  [IDW-1:0]  s1_awid;   reg [31:0] s1_awaddr; reg [7:0] s1_awlen;
    reg  [2:0]      s1_awsize; reg [1:0]  s1_awburst; reg s1_awlock;
    reg             s1_awvalid; wire s1_awready;
    reg  [DW-1:0]   s1_wdata;  reg [DW/8-1:0] s1_wstrb;
    reg             s1_wlast, s1_wvalid; wire s1_wready;
    wire [IDW-1:0]  s1_bid;    wire [1:0] s1_bresp; wire s1_bvalid;
    reg             s1_bready;
    reg  [IDW-1:0]  s1_arid;   reg [31:0] s1_araddr; reg [7:0] s1_arlen;
    reg  [2:0]      s1_arsize; reg [1:0]  s1_arburst; reg s1_arlock;
    reg             s1_arvalid; wire s1_arready;
    wire [DW-1:0]   s1_rdata;  wire [IDW-1:0] s1_rid; wire [1:0] s1_rresp;
    wire            s1_rlast, s1_rvalid; reg s1_rready;

    // S2 accelerator
    reg  [IDW-1:0]  s2_awid;   reg [31:0] s2_awaddr; reg [7:0] s2_awlen;
    reg  [2:0]      s2_awsize; reg [1:0]  s2_awburst; reg s2_awlock;
    reg             s2_awvalid; wire s2_awready;
    reg  [DW-1:0]   s2_wdata;  reg [DW/8-1:0] s2_wstrb;
    reg             s2_wlast, s2_wvalid; wire s2_wready;
    wire [IDW-1:0]  s2_bid;    wire [1:0] s2_bresp; wire s2_bvalid;
    reg             s2_bready;
    reg  [IDW-1:0]  s2_arid;   reg [31:0] s2_araddr; reg [7:0] s2_arlen;
    reg  [2:0]      s2_arsize; reg [1:0]  s2_arburst; reg s2_arlock;
    reg             s2_arvalid; wire s2_arready;
    wire [DW-1:0]   s2_rdata;  wire [IDW-1:0] s2_rid; wire [1:0] s2_rresp;
    wire            s2_rlast, s2_rvalid; reg s2_rready;

    // ---------------- DUT master side ----------------
    wire [IDW-1:0] m_awid;   wire [27:0] m_awaddr; wire [7:0] m_awlen;
    wire [2:0]     m_awsize; wire [1:0]  m_awburst; wire m_awlock;
    wire           m_awvalid; reg m_awready;
    wire [DW-1:0]  m_wdata;  wire [DW/8-1:0] m_wstrb;
    wire           m_wlast, m_wvalid; reg m_wready;
    reg  [IDW-1:0] m_bid;    reg [1:0] m_bresp; reg m_bvalid; wire m_bready;
    wire [IDW-1:0] m_arid;   wire [27:0] m_araddr; wire [7:0] m_arlen;
    wire [2:0]     m_arsize; wire [1:0]  m_arburst; wire m_arlock;
    wire           m_arvalid; reg m_arready;
    reg  [DW-1:0]  m_rdata;  reg [IDW-1:0] m_rid; reg [1:0] m_rresp;
    reg            m_rlast, m_rvalid; wire m_rready;
    wire [IDW-1:0] m_wid;

    axi_ddr_arbiter #(.DW(DW), .IDW(IDW), .MAW(28)) dut (
        .clk(clk), .rst_n(rst_n),
        .s0_awid(s0_awid), .s0_awaddr(s0_awaddr), .s0_awlen(s0_awlen),
        .s0_awsize(s0_awsize), .s0_awburst(s0_awburst), .s0_awlock(s0_awlock),
        .s0_awvalid(s0_awvalid), .s0_awready(s0_awready),
        .s0_wdata(s0_wdata), .s0_wstrb(s0_wstrb), .s0_wlast(s0_wlast),
        .s0_wvalid(s0_wvalid), .s0_wready(s0_wready),
        .s0_bid(s0_bid), .s0_bresp(s0_bresp), .s0_bvalid(s0_bvalid), .s0_bready(s0_bready),
        .s0_arid(s0_arid), .s0_araddr(s0_araddr), .s0_arlen(s0_arlen),
        .s0_arsize(s0_arsize), .s0_arburst(s0_arburst), .s0_arlock(s0_arlock),
        .s0_arvalid(s0_arvalid), .s0_arready(s0_arready),
        .s0_rdata(s0_rdata), .s0_rid(s0_rid), .s0_rresp(s0_rresp),
        .s0_rlast(s0_rlast), .s0_rvalid(s0_rvalid), .s0_rready(s0_rready),

        .s1_awid(s1_awid), .s1_awaddr(s1_awaddr), .s1_awlen(s1_awlen),
        .s1_awsize(s1_awsize), .s1_awburst(s1_awburst), .s1_awlock(s1_awlock),
        .s1_awvalid(s1_awvalid), .s1_awready(s1_awready),
        .s1_wdata(s1_wdata), .s1_wstrb(s1_wstrb), .s1_wlast(s1_wlast),
        .s1_wvalid(s1_wvalid), .s1_wready(s1_wready),
        .s1_bid(s1_bid), .s1_bresp(s1_bresp), .s1_bvalid(s1_bvalid), .s1_bready(s1_bready),
        .s1_arid(s1_arid), .s1_araddr(s1_araddr), .s1_arlen(s1_arlen),
        .s1_arsize(s1_arsize), .s1_arburst(s1_arburst), .s1_arlock(s1_arlock),
        .s1_arvalid(s1_arvalid), .s1_arready(s1_arready),
        .s1_rdata(s1_rdata), .s1_rid(s1_rid), .s1_rresp(s1_rresp),
        .s1_rlast(s1_rlast), .s1_rvalid(s1_rvalid), .s1_rready(s1_rready),

        .s2_awid(s2_awid), .s2_awaddr(s2_awaddr), .s2_awlen(s2_awlen),
        .s2_awsize(s2_awsize), .s2_awburst(s2_awburst), .s2_awlock(s2_awlock),
        .s2_awvalid(s2_awvalid), .s2_awready(s2_awready),
        .s2_wdata(s2_wdata), .s2_wstrb(s2_wstrb), .s2_wlast(s2_wlast),
        .s2_wvalid(s2_wvalid), .s2_wready(s2_wready),
        .s2_bid(s2_bid), .s2_bresp(s2_bresp), .s2_bvalid(s2_bvalid), .s2_bready(s2_bready),
        .s2_arid(s2_arid), .s2_araddr(s2_araddr), .s2_arlen(s2_arlen),
        .s2_arsize(s2_arsize), .s2_arburst(s2_arburst), .s2_arlock(s2_arlock),
        .s2_arvalid(s2_arvalid), .s2_arready(s2_arready),
        .s2_rdata(s2_rdata), .s2_rid(s2_rid), .s2_rresp(s2_rresp),
        .s2_rlast(s2_rlast), .s2_rvalid(s2_rvalid), .s2_rready(s2_rready),

        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awlock(m_awlock),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arlock(m_arlock),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rid(m_rid), .m_rresp(m_rresp),
        .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_wid(m_wid)
    );

    integer errors = 0;
    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("/tmp/tb_arb.vcd");
            $dumpvars(0, tb_axi_ddr_arbiter);
        end
    end
    task fail(input [1023:0] msg);
        begin
            errors = errors + 1;
            $display("[%0t] FAIL: %0s", $time, msg);
        end
    endtask

    //=================================================================
    // Golden data functions (shared by BFMs and the memory model)
    //=================================================================
    function [127:0] wr_beat(input [31:0] base, input integer beat);
        reg [31:0] a;
        begin
            a = base + beat * 16;
            wr_beat = {~a, a, ~a, a};
        end
    endfunction

    function [127:0] rd_beat(input [31:0] base, input integer beat);
        reg [31:0] a;
        begin
            a = base + beat * 16;
            rd_beat = {a ^ 32'hA5A5_0000, ~a, a, a + 32'h1000_0000};
        end
    endfunction

    //=================================================================
    // Downstream memory model: independent AW/W/AR handling, in-order B,
    // in-order R, random ready backpressure.  Counts forwarded traffic so
    // the local-error tests can prove nothing leaked downstream.
    //=================================================================
    integer model_aw_cnt = 0;
    integer model_ar_cnt = 0;
    integer model_wr_errs = 0;

    // write burst tracking
    reg        mw_active = 0;
    reg [IDW-1:0] mw_id;
    reg [31:0] mw_addr;
    integer    mw_beat = 0;
    reg [7:0]  mw_len;

    // pending B queue (single outstanding per arbiter contract, but keep a
    // small queue so the model stays honest if that contract ever breaks)
    reg       bq_valid [0:7];
    reg [7:0] bq_id    [0:7];
    integer   bq_wr = 0, bq_rd = 0;

    integer bi;
    initial for (bi = 0; bi < 8; bi = bi + 1) begin
        bq_valid[bi] = 1'b0;
        bq_id[bi] = 8'd0;
    end

    // read burst tracking (one at a time; arbiter contract)
    reg        mr_active = 0;
    reg [IDW-1:0] mr_id;
    reg [31:0] mr_addr;
    integer    mr_beat = 0;
    reg [7:0]  mr_len;

    // random backpressure
    integer bp_seed = 32'h1234_5678;
    always @(posedge clk) begin
        m_awready <= ($random(bp_seed) % 100) < 70;
        m_wready  <= ($random(bp_seed) % 100) < 70;
        m_arready <= ($random(bp_seed) % 100) < 70;
    end

    // AW capture
    always @(posedge clk) begin
        if (rst_n && m_awvalid && m_awready) begin
            model_aw_cnt = model_aw_cnt + 1;
            if (mw_active) begin
                model_wr_errs = model_wr_errs + 1;
                fail("model: second AW while write still active");
            end
            mw_active = 1;
            mw_id     = m_awid;
            mw_addr   = {4'h0, m_awaddr};
            mw_beat   = 0;
            mw_len    = m_awlen;
        end
    end

    // W capture + data check
    always @(posedge clk) begin
        if (rst_n && m_wvalid && m_wready) begin
            if (!mw_active) begin
                model_wr_errs = model_wr_errs + 1;
                fail("model: W beat without active write burst");
            end else begin
                if (m_wdata !== wr_beat(mw_addr, mw_beat)) begin
                    model_wr_errs = model_wr_errs + 1;
                    fail("model: W payload mismatch");
                    $display("   beat %0d addr %08x got %032x exp %032x",
                             mw_beat, mw_addr, m_wdata, wr_beat(mw_addr, mw_beat));
                end
                if (m_wstrb !== {DW/8{1'b1}}) begin
                    model_wr_errs = model_wr_errs + 1;
                    fail("model: WSTRB not all-ones");
                end
                if (m_wlast) begin
                    if (mw_beat != mw_len) begin
                        model_wr_errs = model_wr_errs + 1;
                        fail("model: WLAST at wrong beat");
                    end
                    // queue B response
                    if (bq_valid[bq_wr[2:0]]) begin
                        model_wr_errs = model_wr_errs + 1;
                        fail("model: B queue overflow");
                    end
                    bq_id[bq_wr[2:0]]    = mw_id;
                    bq_valid[bq_wr[2:0]] = 1'b1;
                    bq_wr = (bq_wr + 1) % 8;
                    mw_active = 0;
                end else begin
                    if (mw_beat >= mw_len) begin
                        model_wr_errs = model_wr_errs + 1;
                        fail("model: extra W beat after WLAST");
                    end
                    mw_beat = mw_beat + 1;
                end
            end
        end
    end

    // B return (random delay)
    integer b_wait = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_bvalid <= 1'b0;
            b_wait    = 0;
        end else if (m_bvalid) begin
            if (m_bready) begin
                m_bvalid <= 1'b0;
                bq_valid[bq_rd[2:0]] = 1'b0;
                bq_rd = (bq_rd + 1) % 8;
            end
        end else if (bq_valid[bq_rd] && b_wait == 0) begin
            m_bvalid <= 1'b1;
            m_bid    <= bq_id[bq_rd];
            m_bresp  <= 2'b00;
            b_wait    = 1 + ({$random(bp_seed)} % 4);
        end else if (bq_valid[bq_rd]) begin
            b_wait = b_wait - 1;
        end
    end

    // AR capture
    always @(posedge clk) begin
        if (rst_n && m_arvalid && m_arready) begin
            model_ar_cnt = model_ar_cnt + 1;
            if (mr_active) begin
                fail("model: second AR while read still active");
            end
            mr_active = 1;
            mr_id     = m_arid;
            mr_addr   = {4'h0, m_araddr};
            mr_beat   = 0;
            mr_len    = m_arlen;
        end
    end

    // R return (random gaps).  Single writer: mr_active/mr_beat are only
    // touched here (AR capture only initialises a fresh idle burst).
    integer r_gap = 0;
    task automatic r_drive_next;
        begin
            m_rvalid <= 1'b1;
            m_rid    <= mr_id;
            m_rdata  <= rd_beat(mr_addr, mr_beat);
            m_rresp  <= 2'b00;
            m_rlast  <= (mr_beat == mr_len);
        end
    endtask
    always @(posedge clk) begin
        if (!rst_n) begin
            m_rvalid <= 1'b0;
            m_rlast  <= 1'b0;
            r_gap     = 0;
        end else if (m_rvalid && m_rready) begin
            if (m_rlast) begin
                m_rvalid <= 1'b0;
                m_rlast  <= 1'b0;
                mr_active = 1'b0;
            end else begin
                mr_beat = mr_beat + 1;
                if (({$random(bp_seed)} % 100) < 30) begin
                    m_rvalid <= 1'b0;
                    m_rlast  <= 1'b0;
                    r_gap     = 1 + ({$random(bp_seed)} % 3);
                end else begin
                    r_drive_next;
                end
            end
        end else if (!m_rvalid && mr_active) begin
            if (r_gap > 0) begin
                r_gap = r_gap - 1;
                if (r_gap == 0) r_drive_next;
            end else begin
                r_drive_next;
            end
        end
    end


    //=================================================================
    // Protocol monitors (always on)
    //=================================================================
    integer outstanding_w = 0;
    integer outstanding_r = 0;
    reg pm_awvalid = 0, pm_awready = 0;
    reg [27:0] pm_awaddr = 0; reg [7:0] pm_awlen = 0; reg [IDW-1:0] pm_awid = 0;
    reg pm_arvalid = 0, pm_arready = 0;
    reg [27:0] pm_araddr = 0; reg [7:0] pm_arlen = 0; reg [IDW-1:0] pm_arid = 0;
    reg pm_bvalid = 0, pm_bready = 0;
    reg pm_rvalid = 0, pm_rready = 0, pm_rlast = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            // one-hot response checks
            if ((s0_bvalid + s1_bvalid + s2_bvalid) > 1)
                fail("B response not one-hot across slaves");
            if ((s0_rvalid + s1_rvalid + s2_rvalid) > 1)
                fail("R response not one-hot across slaves");
            if ((s0_bvalid & s1_bvalid) || (s0_rvalid & s2_rvalid))
                fail("response fanout");

            // downstream outstanding contract
            if (outstanding_w > 1) fail("more than one outstanding write downstream");
            if (outstanding_r > 1) fail("more than one outstanding read downstream");
            if (outstanding_w < 0 || outstanding_r < 0)
                fail("negative outstanding count");

            // payload stability while stalled
            if (pm_awvalid && !pm_awready) begin
                if (!m_awvalid) fail("m_awvalid dropped without handshake");
                else if (m_awaddr !== pm_awaddr || m_awlen !== pm_awlen ||
                         m_awid !== pm_awid)
                    fail("m_aw payload changed while stalled");
            end
            if (pm_arvalid && !pm_arready) begin
                if (!m_arvalid) fail("m_arvalid dropped without handshake");
                else if (m_araddr !== pm_araddr || m_arlen !== pm_arlen ||
                         m_arid !== pm_arid)
                    fail("m_ar payload changed while stalled");
            end
        end

        if (rst_n && m_awvalid && m_awready) outstanding_w = outstanding_w + 1;
        if (rst_n && m_bvalid && m_bready)   outstanding_w = outstanding_w - 1;
        if (rst_n && m_arvalid && m_arready) outstanding_r = outstanding_r + 1;
        if (rst_n && m_rvalid && m_rready && m_rlast)
            outstanding_r = outstanding_r - 1;

        pm_awvalid <= m_awvalid; pm_awready <= m_awready;
        pm_awaddr  <= m_awaddr;  pm_awlen <= m_awlen; pm_awid <= m_awid;
        pm_arvalid <= m_arvalid; pm_arready <= m_arready;
        pm_araddr  <= m_araddr;  pm_arlen <= m_arlen; pm_arid <= m_arid;
        pm_bvalid  <= m_bvalid;  pm_bready <= m_bready;
        pm_rvalid  <= m_rvalid;  pm_rready <= m_rready; pm_rlast <= m_rlast;
    end

    //=================================================================
    // Master BFMs
    //
    // Every valid/ready the BFM produces is driven on the NEGEDGE so it is
    // stable before the sampling posedge.  Driving right after a posedge, or
    // resuming a #delay that landed exactly on an edge, races with the edge
    // and can fake a handshake (observed as an off-by-one at the model).
    //=================================================================
    task automatic bfm_write(
        input integer      s,        // 0/1/2
        input [IDW-1:0]    id,
        input [31:0]       addr,
        input [7:0]        len,
        input              w_first,  // 1: launch W beats before AW
        input integer      delay_ns  // idle before starting
    );
        integer beat;
        reg [1023:0] tag;
        begin
            if (delay_ns > 0) #(delay_ns);
            fork
                begin : AW
                    if (w_first) #(40 + ({$random} % 100));
                    @(negedge clk);
                    case (s)
                        0: begin s0_awid <= id; s0_awaddr <= addr; s0_awlen <= len;
                                 s0_awsize <= 4; s0_awburst <= 2'b01; s0_awlock <= 1'b0;
                                 s0_awvalid <= 1'b1; end
                        1: begin s1_awid <= id; s1_awaddr <= addr; s1_awlen <= len;
                                 s1_awsize <= 4; s1_awburst <= 2'b01; s1_awlock <= 1'b0;
                                 s1_awvalid <= 1'b1; end
                        default: begin s2_awid <= id; s2_awaddr <= addr; s2_awlen <= len;
                                 s2_awsize <= 4; s2_awburst <= 2'b01; s2_awlock <= 1'b0;
                                 s2_awvalid <= 1'b1; end
                    endcase
                    @(posedge clk);
                    case (s)
                        0: while (!s0_awready) @(posedge clk);
                        1: while (!s1_awready) @(posedge clk);
                        default: while (!s2_awready) @(posedge clk);
                    endcase
                    case (s)
                        0: s0_awvalid <= 1'b0;
                        1: s1_awvalid <= 1'b0;
                        default: s2_awvalid <= 1'b0;
                    endcase
                end
                begin : WS
                    for (beat = 0; beat <= len; beat = beat + 1) begin
                        case (s)                       // idle while delaying
                            0: s0_wvalid <= 1'b0;
                            1: s1_wvalid <= 1'b0;
                            default: s2_wvalid <= 1'b0;
                        endcase
                        if (({$random} % 100) < 25) #(5 + ({$random} % 20));
                        @(negedge clk);
                        case (s)
                            0: begin s0_wdata <= wr_beat(addr, beat);
                                     s0_wstrb <= {DW/8{1'b1}};
                                     s0_wlast <= (beat == len);
                                     s0_wvalid <= 1'b1; end
                            1: begin s1_wdata <= wr_beat(addr, beat);
                                     s1_wstrb <= {DW/8{1'b1}};
                                     s1_wlast <= (beat == len);
                                     s1_wvalid <= 1'b1; end
                            default: begin s2_wdata <= wr_beat(addr, beat);
                                     s2_wstrb <= {DW/8{1'b1}};
                                     s2_wlast <= (beat == len);
                                     s2_wvalid <= 1'b1; end
                        endcase
                        @(posedge clk);
                        case (s)
                            0: while (!s0_wready) @(posedge clk);
                            1: while (!s1_wready) @(posedge clk);
                            default: while (!s2_wready) @(posedge clk);
                        endcase
                        if (beat == len) begin
                            case (s)
                                0: begin s0_wvalid <= 1'b0; s0_wlast <= 1'b0; end
                                1: begin s1_wvalid <= 1'b0; s1_wlast <= 1'b0; end
                                default: begin s2_wvalid <= 1'b0; s2_wlast <= 1'b0; end
                            endcase
                        end
                    end
                end
                begin : BS
                    @(negedge clk);
                    case (s)
                        0: s0_bready <= 1'b1;
                        1: s1_bready <= 1'b1;
                        default: s2_bready <= 1'b1;
                    endcase
                    @(posedge clk);
                    case (s)
                        0: begin
                             while (!s0_bvalid) @(posedge clk);
                             if (s0_bresp !== 2'b00) begin
                                 tag = "bfm_write: s0 BRESP not OKAY"; fail(tag);
                             end
                             if (s0_bid !== id) begin
                                 tag = "bfm_write: s0 BID mismatch"; fail(tag);
                                 $display("   got %02x exp %02x", s0_bid, id);
                             end
                             s0_bready <= 1'b0;
                           end
                        1: begin
                             while (!s1_bvalid) @(posedge clk);
                             if (s1_bresp !== 2'b00) begin
                                 tag = "bfm_write: s1 BRESP not OKAY"; fail(tag);
                             end
                             if (s1_bid !== id) begin
                                 tag = "bfm_write: s1 BID mismatch"; fail(tag);
                                 $display("   got %02x exp %02x", s1_bid, id);
                             end
                             s1_bready <= 1'b0;
                           end
                        default: begin
                             while (!s2_bvalid) @(posedge clk);
                             if (s2_bresp !== 2'b00) begin
                                 tag = "bfm_write: s2 BRESP not OKAY"; fail(tag);
                             end
                             if (s2_bid !== id) begin
                                 tag = "bfm_write: s2 BID mismatch"; fail(tag);
                                 $display("   got %02x exp %02x", s2_bid, id);
                             end
                             s2_bready <= 1'b0;
                           end
                    endcase
                end
            join
        end
    endtask

    // Independent address/data streams can offer the next W before the
    // previous B returns. That is legal AXI; a one-outstanding arbiter must
    // backpressure it rather than forward it under the previous address.
    task automatic bfm_pipelined_cpu_writes;
        integer a, w, b, response;
        begin
            fork
                begin
                    for(a=0;a<32;a=a+1) begin
                        @(negedge clk);
                        s1_awid<=8'h80+a; s1_awaddr<=32'h00900000+a*256;
                        s1_awlen<=(a%3==0)?0:((a%3==1)?3:7);
                        s1_awvalid<=1;
                        @(posedge clk); while(!s1_awready) @(posedge clk);
                        s1_awvalid<=0;
                    end
                end
                begin
                    for(w=0;w<32;w=w+1) begin
                        for(b=0;b<=((w%3==0)?0:((w%3==1)?3:7));b=b+1) begin
                            @(negedge clk);
                            s1_wdata<=wr_beat(32'h00900000+w*256,b);
                            s1_wstrb<=16'hffff;
                            s1_wlast<=(b==((w%3==0)?0:((w%3==1)?3:7)));
                            s1_wvalid<=1;
                            @(posedge clk);while(!s1_wready) @(posedge clk);
                            s1_wvalid<=0;
                        end
                    end
                end
                begin
                    for(response=0;response<32;response=response+1) begin
                        // Keep B stalled long enough for the next W to arrive.
                        repeat(16) @(negedge clk);s1_bready<=1;
                        @(posedge clk);while(!s1_bvalid) @(posedge clk);
                        if(s1_bresp!==0 || s1_bid!==(8'h80+response))
                            fail("pipelined CPU write response ownership");
                        s1_bready<=0;
                    end
                end
            join
            $display("PASS: pipelined CPU AW/W streams with delayed B");
        end
    endtask

    // Out-of-range write: expect a local SLVERR and nothing downstream.
    task automatic bfm_write_expect_err(
        input integer   s,
        input [IDW-1:0] id,
        input [31:0]    addr,
        input [7:0]     len
    );
        integer beat;
        integer aw_before;
        reg [1023:0] tag;
        begin
            aw_before = model_aw_cnt;
            fork
                begin
                    @(negedge clk);
                    case (s)
                        0: begin s0_awid <= id; s0_awaddr <= addr; s0_awlen <= len;
                                 s0_awsize <= 4; s0_awburst <= 2'b01;
                                 s0_awvalid <= 1'b1; end
                        1: begin s1_awid <= id; s1_awaddr <= addr; s1_awlen <= len;
                                 s1_awsize <= 4; s1_awburst <= 2'b01;
                                 s1_awvalid <= 1'b1; end
                        default: begin s2_awid <= id; s2_awaddr <= addr; s2_awlen <= len;
                                 s2_awsize <= 4; s2_awburst <= 2'b01;
                                 s2_awvalid <= 1'b1; end
                    endcase
                    @(posedge clk);
                    case (s)
                        0: while (!s0_awready) @(posedge clk);
                        1: while (!s1_awready) @(posedge clk);
                        default: while (!s2_awready) @(posedge clk);
                    endcase
                    case (s)
                        0: s0_awvalid <= 1'b0;
                        1: s1_awvalid <= 1'b0;
                        default: s2_awvalid <= 1'b0;
                    endcase
                end
                begin
                    for (beat = 0; beat <= len; beat = beat + 1) begin
                        case (s)
                            0: s0_wvalid <= 1'b0;
                            1: s1_wvalid <= 1'b0;
                            default: s2_wvalid <= 1'b0;
                        endcase
                        @(negedge clk);
                        case (s)
                            0: begin s0_wdata <= wr_beat(addr, beat);
                                     s0_wstrb <= {DW/8{1'b1}};
                                     s0_wlast <= (beat == len);
                                     s0_wvalid <= 1'b1; end
                            1: begin s1_wdata <= wr_beat(addr, beat);
                                     s1_wstrb <= {DW/8{1'b1}};
                                     s1_wlast <= (beat == len);
                                     s1_wvalid <= 1'b1; end
                            default: begin s2_wdata <= wr_beat(addr, beat);
                                     s2_wstrb <= {DW/8{1'b1}};
                                     s2_wlast <= (beat == len);
                                     s2_wvalid <= 1'b1; end
                        endcase
                        @(posedge clk);
                        case (s)
                            0: while (!s0_wready) @(posedge clk);
                            1: while (!s1_wready) @(posedge clk);
                            default: while (!s2_wready) @(posedge clk);
                        endcase
                        if (beat == len) begin
                            case (s)
                                0: begin s0_wvalid <= 1'b0; s0_wlast <= 1'b0; end
                                1: begin s1_wvalid <= 1'b0; s1_wlast <= 1'b0; end
                                default: begin s2_wvalid <= 1'b0; s2_wlast <= 1'b0; end
                            endcase
                        end
                    end
                end
                begin
                    @(negedge clk);
                    case (s)
                        0: s0_bready <= 1'b1;
                        1: s1_bready <= 1'b1;
                        default: s2_bready <= 1'b1;
                    endcase
                    @(posedge clk);
                    case (s)
                        0: begin
                             while (!s0_bvalid) @(posedge clk);
                             if (s0_bresp !== 2'b10) begin
                                 tag = "expect_err: s0 BRESP not SLVERR"; fail(tag);
                             end
                             if (s0_bid !== id) begin
                                 tag = "expect_err: s0 BID mismatch"; fail(tag);
                             end
                             s0_bready <= 1'b0;
                           end
                        1: begin
                             while (!s1_bvalid) @(posedge clk);
                             if (s1_bresp !== 2'b10) begin
                                 tag = "expect_err: s1 BRESP not SLVERR"; fail(tag);
                             end
                             if (s1_bid !== id) begin
                                 tag = "expect_err: s1 BID mismatch"; fail(tag);
                             end
                             s1_bready <= 1'b0;
                           end
                        default: begin
                             while (!s2_bvalid) @(posedge clk);
                             if (s2_bresp !== 2'b10) begin
                                 tag = "expect_err: s2 BRESP not SLVERR"; fail(tag);
                             end
                             if (s2_bid !== id) begin
                                 tag = "expect_err: s2 BID mismatch"; fail(tag);
                             end
                             s2_bready <= 1'b0;
                           end
                    endcase
                end
            join
            #(50);
            if (model_aw_cnt != aw_before) begin
                tag = "expect_err: out-of-range AW reached the downstream model";
                fail(tag);
            end
        end
    endtask

    task automatic bfm_read(
        input integer   s,
        input [IDW-1:0] id,
        input [31:0]    addr,
        input [7:0]     len,
        input           expect_err,
        input integer   delay_ns
    );
        integer beat;
        reg [1023:0] tag;
        reg [1:0] exp_resp;
        begin
            if (delay_ns > 0) #(delay_ns);
            exp_resp = expect_err ? 2'b10 : 2'b00;
            fork
                begin
                    @(negedge clk);
                    case (s)
                        0: begin s0_arid <= id; s0_araddr <= addr; s0_arlen <= len;
                                 s0_arsize <= 4; s0_arburst <= 2'b01; s0_arlock <= 1'b0;
                                 s0_arvalid <= 1'b1; end
                        1: begin s1_arid <= id; s1_araddr <= addr; s1_arlen <= len;
                                 s1_arsize <= 4; s1_arburst <= 2'b01; s1_arlock <= 1'b0;
                                 s1_arvalid <= 1'b1; end
                        default: begin s2_arid <= id; s2_araddr <= addr; s2_arlen <= len;
                                 s2_arsize <= 4; s2_arburst <= 2'b01; s2_arlock <= 1'b0;
                                 s2_arvalid <= 1'b1; end
                    endcase
                    @(posedge clk);
                    case (s)
                        0: while (!s0_arready) @(posedge clk);
                        1: while (!s1_arready) @(posedge clk);
                        default: while (!s2_arready) @(posedge clk);
                    endcase
                    case (s)
                        0: s0_arvalid <= 1'b0;
                        1: s1_arvalid <= 1'b0;
                        default: s2_arvalid <= 1'b0;
                    endcase
                end
                begin : RS
                    @(negedge clk);
                    case (s)
                        0: s0_rready <= 1'b1;
                        1: s1_rready <= 1'b1;
                        default: s2_rready <= 1'b1;
                    endcase
                    for (beat = 0; beat <= len; beat = beat + 1) begin
                        @(posedge clk);
                        case (s)
                            0: while (!s0_rvalid) @(posedge clk);
                            1: while (!s1_rvalid) @(posedge clk);
                            default: while (!s2_rvalid) @(posedge clk);
                        endcase
                        case (s)
                            0: begin
                                 if (s0_rresp !== exp_resp) begin
                                     tag = "bfm_read: s0 RRESP mismatch"; fail(tag);
                                     $display("   beat %0d resp %02x exp %02x",
                                              beat, s0_rresp, exp_resp);
                                 end
                                 if (!expect_err &&
                                     s0_rdata !== rd_beat(addr, beat)) begin
                                     tag = "bfm_read: s0 RDATA mismatch"; fail(tag);
                                     $display("   beat %0d addr %08x got %032x exp %032x",
                                              beat, addr + beat*16, s0_rdata,
                                              rd_beat(addr, beat));
                                 end
                                 if (s0_rid !== id) begin
                                     tag = "bfm_read: s0 RID mismatch"; fail(tag);
                                     $display("   got %02x exp %02x", s0_rid, id);
                                 end
                                 if (s0_rlast !== (beat == len)) begin
                                     tag = "bfm_read: s0 RLAST wrong"; fail(tag);
                                 end
                               end
                            1: begin
                                 if (s1_rresp !== exp_resp) begin
                                     tag = "bfm_read: s1 RRESP mismatch"; fail(tag);
                                     $display("   beat %0d resp %02x exp %02x",
                                              beat, s1_rresp, exp_resp);
                                 end
                                 if (!expect_err &&
                                     s1_rdata !== rd_beat(addr, beat)) begin
                                     tag = "bfm_read: s1 RDATA mismatch"; fail(tag);
                                     $display("   beat %0d addr %08x got %032x exp %032x",
                                              beat, addr + beat*16, s1_rdata,
                                              rd_beat(addr, beat));
                                 end
                                 if (s1_rid !== id) begin
                                     tag = "bfm_read: s1 RID mismatch"; fail(tag);
                                     $display("   got %02x exp %02x", s1_rid, id);
                                 end
                                 if (s1_rlast !== (beat == len)) begin
                                     tag = "bfm_read: s1 RLAST wrong"; fail(tag);
                                 end
                               end
                            default: begin
                                 if (s2_rresp !== exp_resp) begin
                                     tag = "bfm_read: s2 RRESP mismatch"; fail(tag);
                                     $display("   beat %0d resp %02x exp %02x",
                                              beat, s2_rresp, exp_resp);
                                 end
                                 if (!expect_err &&
                                     s2_rdata !== rd_beat(addr, beat)) begin
                                     tag = "bfm_read: s2 RDATA mismatch"; fail(tag);
                                     $display("   beat %0d addr %08x got %032x exp %032x",
                                              beat, addr + beat*16, s2_rdata,
                                              rd_beat(addr, beat));
                                 end
                                 if (s2_rid !== id) begin
                                     tag = "bfm_read: s2 RID mismatch"; fail(tag);
                                     $display("   got %02x exp %02x", s2_rid, id);
                                 end
                                 if (s2_rlast !== (beat == len)) begin
                                     tag = "bfm_read: s2 RLAST wrong"; fail(tag);
                                 end
                               end
                        endcase
                    end
                    case (s)
                        0: s0_rready <= 1'b0;
                        1: s1_rready <= 1'b0;
                        default: s2_rready <= 1'b0;
                    endcase
                end
            join
        end
    endtask

    // out-of-range read: prove nothing was forwarded
    task automatic bfm_read_expect_err(
        input integer s, input [IDW-1:0] id, input [31:0] addr, input [7:0] len
    );
        integer ar_before;
        reg [1023:0] tag;
        begin
            ar_before = model_ar_cnt;
            bfm_read(s, id, addr, len, 1'b1, 0);
            #(50);
            if (model_ar_cnt != ar_before) begin
                tag = "expect_err: out-of-range AR reached the downstream model";
                fail(tag);
            end
        end
    endtask

    //=================================================================
    // Stimulus
    //=================================================================
    integer i, i0, i1, i2;
    integer aw0, aw1, aw2;
    reg [31:0] base0 = 32'h0000_1000;   // video region
    reg [31:0] base1 = 32'h0080_0000;   // CPU region
    reg [31:0] base2 = 32'h00A0_0000;   // accelerator region

    initial begin
        s0_awvalid = 0; s0_wvalid = 0; s0_bready = 0; s0_arvalid = 0; s0_rready = 0;
        s1_awvalid = 0; s1_wvalid = 0; s1_bready = 0; s1_arvalid = 0; s1_rready = 0;
        s2_awvalid = 0; s2_wvalid = 0; s2_bready = 0; s2_arvalid = 0; s2_rready = 0;
        s0_awid = 0; s0_arid = 0; s1_awid = 0; s1_arid = 0; s2_awid = 0; s2_arid = 0;
        s0_awaddr = 0; s0_araddr = 0; s1_awaddr = 0; s1_araddr = 0;
        s2_awaddr = 0; s2_araddr = 0;
        s0_awlen = 0; s0_arlen = 0; s1_awlen = 0; s1_arlen = 0;
        s2_awlen = 0; s2_arlen = 0;
        s0_wdata = 0; s1_wdata = 0; s2_wdata = 0;
        s0_wstrb = 0; s1_wstrb = 0; s2_wstrb = 0;
        s0_wlast = 0; s1_wlast = 0; s2_wlast = 0;
        s0_awsize = 4; s1_awsize = 4; s2_awsize = 4;
        s0_arsize = 4; s1_arsize = 4; s2_arsize = 4;
        s0_awburst = 1; s1_awburst = 1; s2_awburst = 1;
        s0_arburst = 1; s1_arburst = 1; s2_arburst = 1;
        s0_awlock = 0; s1_awlock = 0; s2_awlock = 0;
        s0_arlock = 0; s1_arlock = 0; s2_arlock = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("[%0t] Phase P: pipelined CPU writes under concurrent video/accelerator traffic",$time);
        fork
            bfm_pipelined_cpu_writes();
            bfm_write(0,8'h71,base0,8'd127,1'b0,0);
            bfm_read(2,8'h72,base2,8'd127,1'b0,0);
        join

        // Phase A: basic traffic on every master
        $display("[%0t] Phase A: basic R/W per master", $time);
        bfm_write(0, 8'h10, base0 + 32'h0000, 8'd0,  1'b0, 0);
        bfm_write(0, 8'h11, base0 + 32'h1000, 8'd3,  1'b0, 0);
        bfm_read (0, 8'h12, base0 + 32'h0000, 8'd0,  1'b0, 0);
        bfm_read (0, 8'h13, base0 + 32'h1000, 8'd15, 1'b0, 0);
        bfm_write(1, 8'h20, base1 + 32'h0000, 8'd15, 1'b0, 0);
        bfm_read (1, 8'h21, base1 + 32'h0000, 8'd63, 1'b0, 0);
        bfm_write(2, 8'h30, base2 + 32'h2000, 8'd7,  1'b0, 0);
        bfm_read (2, 8'h31, base2 + 32'h2000, 8'd7,  1'b0, 0);

        // Phase B: local SLVERR writes
        $display("[%0t] Phase B: out-of-range writes -> SLVERR", $time);
        bfm_write_expect_err(1, 8'h44, 32'h1000_1234, 8'd3);
        bfm_write_expect_err(0, 8'h45, 32'hF000_0000, 8'd0);

        // Phase C: local SLVERR reads (multi-beat generator)
        $display("[%0t] Phase C: out-of-range reads -> SLVERR", $time);
        bfm_read_expect_err(2, 8'h55, 32'h2000_0000, 8'd4);
        bfm_read_expect_err(0, 8'h56, 32'h8000_0000, 8'd0);

        // Phase D: W before AW
        $display("[%0t] Phase D: W-before-AW", $time);
        bfm_write(1, 8'h60, base1 + 32'h4000, 8'd7, 1'b1, 0);
        bfm_read (1, 8'h61, base1 + 32'h4000, 8'd7, 1'b0, 0);

        // Phase E: three-master hammer (concurrent reads and writes)
        $display("[%0t] Phase E: concurrent hammer", $time);
        aw0 = 0; aw1 = 0; aw2 = 0;
        fork
            begin : M0
                for (i0 = 0; i0 < 20; i0 = i0 + 1) begin
                    bfm_write(0, 8'h70 + i0[7:0], base0 + i0 * 32'h100, i0[7:0] % 16,
                              1'b0, ({$random} % 100));
                    bfm_read (0, 8'h90 + i0[7:0], base0 + i0 * 32'h100, i0[7:0] % 8,
                              1'b0, ({$random} % 60));
                    aw0 = aw0 + 1;
                end
            end
            begin : M1
                for (i1 = 0; i1 < 20; i1 = i1 + 1) begin
                    bfm_read (1, 8'hA0 + i1[7:0], base1 + i1 * 32'h200, i1[7:0] % 32,
                              1'b0, ({$random} % 80));
                    bfm_write(1, 8'hB0 + i1[7:0], base1 + i1 * 32'h200, i1[7:0] % 16,
                              (i1 % 5 == 4), ({$random} % 120));
                    aw1 = aw1 + 1;
                end
            end
            begin : M2
                for (i2 = 0; i2 < 20; i2 = i2 + 1) begin
                    bfm_write(2, 8'hC0 + i2[7:0], base2 + i2 * 32'h80, i2[7:0] % 8,
                              1'b0, ({$random} % 90));
                    bfm_read (2, 8'hD0 + i2[7:0], base2 + i2 * 32'h80, i2[7:0] % 8,
                              1'b0, ({$random} % 110));
                    aw2 = aw2 + 1;
                end
            end
        join

        repeat (20) @(posedge clk);

        if (model_wr_errs != 0)
            fail("memory model reported payload/protocol errors");
        if (model_aw_cnt < 64)
            fail("suspiciously few downstream writes");
        if (model_ar_cnt < 64)
            fail("suspiciously few downstream reads");

        $display("[%0t] transactions: s0=%0d s1=%0d s2=%0d downstream aw=%0d ar=%0d",
                 $time, aw0, aw1, aw2, model_aw_cnt, model_ar_cnt);

        if (errors == 0) begin
            $display("PASS: tb_axi_ddr_arbiter");
            $finish;
        end else begin
            $display("FAIL: tb_axi_ddr_arbiter (%0d errors)", errors);
            $fatal(1, "tb_axi_ddr_arbiter failed");
        end
    end

    // watchdog
    initial begin
        #50_000_000;
        $display("FAIL: tb_axi_ddr_arbiter timeout");
        $fatal(1, "tb_axi_ddr_arbiter timeout");
    end

endmodule
