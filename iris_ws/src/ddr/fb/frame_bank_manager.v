// Three non-overlapping RAW8 frame banks. Publish completed frames and lock
// the bank selected at the beginning of a display read until the next read.
module frame_bank_manager #(
    parameter ADDR_WIDTH = 28,
    parameter FRAME_BYTES = 1920 * 1080,
    parameter START_ADDR = 0
) (
    input clk, rst_n, wr_done, rd_start,
    output wire [ADDR_WIDTH-1:0] wr_addr, rd_addr,
    output reg [1:0] writer, reader, latest,
    output reg ready
);
localparam BANK_STRIDE = ((FRAME_BYTES + 4095) / 4096 + 1) * 4096;
reg [2:0] rd_sync;
wire rd_begin = rd_sync[0] && !rd_sync[1];
wire [1:0] selected = ready ? latest : reader;
wire [1:0] locked = (rd_begin && ready) ? latest : reader;
wire [1:0] candidate = (writer == 2) ? 0 : writer + 1'b1;
wire [1:0] next_writer = (candidate == locked) ?
    ((candidate == 2) ? 0 : candidate + 1'b1) : candidate;
assign wr_addr = START_ADDR + writer * BANK_STRIDE;
assign rd_addr = START_ADDR + selected * BANK_STRIDE;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        writer<=0;reader<=1;latest<=0;ready<=0;rd_sync<=0;
    end else begin
        rd_sync<={rd_sync[1:0],rd_start};
        if (rd_begin && ready) reader<=latest;
        if (wr_done) begin
            latest<=writer;
            ready<=1;
            writer<=next_writer;
        end
    end
end
endmodule
