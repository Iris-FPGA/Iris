// AXI4 AW/AR -> Efinix DDR3 shared address port.
// Preserve the selected address under backpressure. SERIAL_TRANSACTIONS=1
// additionally waits for the accepted B/RLAST handshake before issuing any
// next controller address. New requests alternate directions under contention
// so neither video reads nor writes can starve. Set the parameter to 0 only
// for isolated AXI concurrency verification; board concurrency remains under
// investigation. Response data still passes through the parent arbiter.
module axi_atype_bridge #(
    parameter IDW = 4,
    parameter AW  = 32,
    // Conservative board-validation mode: do not overlap controller reads
    // and writes. The two upstream arbiter grants may still be pending.
    parameter SERIAL_TRANSACTIONS = 0
)(
    input  wire            clk,
    input  wire            rst_n,

    // master write address (standard AXI4)
    input  wire [IDW-1:0]  s_awid,
    input  wire [AW-1:0]   s_awaddr,
    input  wire [7:0]      s_awlen,
    input  wire [2:0]      s_awsize,
    input  wire [1:0]      s_awburst,
    input  wire [0:0]      s_awlock,
    input  wire            s_awvalid,
    output wire            s_awready,

    // master read address (standard AXI4)
    input  wire [IDW-1:0]  s_arid,
    input  wire [AW-1:0]   s_araddr,
    input  wire [7:0]      s_arlen,
    input  wire [2:0]      s_arsize,
    input  wire [1:0]      s_arburst,
    input  wire [0:0]      s_arlock,
    input  wire            s_arvalid,
    output wire            s_arready,

    // shared address channel to the DDR3 controller
    output wire [7:0]      m_aid,
    output wire [AW-1:0]   m_aaddr,
    output wire [7:0]      m_alen,
    output wire [2:0]      m_asize,
    output wire [1:0]      m_aburst,
    output wire [1:0]      m_alock,
    output wire            m_atype,     // 1 = write, 0 = read
    output wire            m_avalid,
    input  wire            m_aready,

    // Controller response handshakes (W/B/R wired through in top.v)
    input  wire            bvalid,
    input  wire            bready,
    input  wire            rvalid,
    input  wire            rlast,
    input  wire            rready
);

    // Read has priority when selecting a NEW address. Once VALID is
    // presented under backpressure, AXI requires the selected address and
    // direction to remain stable until READY. A late AR must not replace
    // an already-presented AW (nor may a late AW replace an AR).
    reg selection_locked;
    reg locked_write;
    reg [1:0] active_direction; // 0=idle, 1=read, 2=write
    reg prefer_write;
    wire eligible = !SERIAL_TRANSACTIONS || active_direction == 0;
    wire choose_aw = s_awvalid && (!s_arvalid || (SERIAL_TRANSACTIONS && prefer_write));
    wire sel_aw = selection_locked ? locked_write : choose_aw;
    wire sel_ar = selection_locked ? ~locked_write : (s_arvalid && !choose_aw);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            selection_locked <= 1'b0;
            locked_write <= 1'b0;
            active_direction <= 0;
            prefer_write <= 0;
        end else begin
            if (m_avalid && !m_aready) begin
                selection_locked <= 1'b1;
                locked_write <= sel_aw;
            end else if (m_avalid && m_aready) begin
                selection_locked <= 1'b0;
            end
            if (m_avalid && m_aready) begin
                active_direction <= sel_aw ? 2 : 1;
                prefer_write <= !sel_aw;
            end else if ((active_direction == 1 && rvalid && rlast && rready) ||
                         (active_direction == 2 && bvalid && bready)) begin
                active_direction <= 0;
            end
        end
    end

    assign s_awready = sel_aw & eligible & m_aready;
    assign s_arready = sel_ar & eligible & m_aready;

    assign m_avalid = eligible & (sel_aw | sel_ar);
    assign m_atype  = sel_aw;

    assign m_aid    = sel_aw ? {{(8-IDW){1'b0}}, s_awid}  : {{(8-IDW){1'b0}}, s_arid};
    assign m_aaddr  = sel_aw ? s_awaddr                   : s_araddr;
    assign m_alen   = sel_aw ? s_awlen                    : s_arlen;
    assign m_asize  = sel_aw ? s_awsize                   : s_arsize;
    assign m_aburst = sel_aw ? s_awburst                  : s_arburst;
    assign m_alock  = sel_aw ? {1'b0, s_awlock}           : {1'b0, s_arlock};

endmodule
