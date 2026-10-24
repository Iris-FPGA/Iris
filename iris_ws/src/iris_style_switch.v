// Two complete Flash images retain their own CNN and video geometry.
// A held key across reconfiguration must be released before another switch.
module iris_style_switch #(
    parameter CLK_HZ = 27_000_000,
    parameter DEB_MS = 20,
    parameter CURRENT_IMAGE = 0
)(
    input wire clk, rst_n, key_n, config_error, request_toggle,
    output wire [1:0] cbsel,
    output reg ena, config_request,
    output wire [31:0] status
);
localparam DEBOUNCE = CLK_HZ / 1000 * DEB_MS;
localparam COUNT_BITS = $clog2(DEBOUNCE + 1);
reg [1:0] key_sync;
reg [2:0] request_sync;
reg [COUNT_BITS-1:0] count;
reg armed;
reg [3:0] settle;
assign cbsel = CURRENT_IMAGE == 0 ? 2'd1 : 2'd0;
assign status = {16'h4952, 8'd0, 1'b0, CURRENT_IMAGE != 0,
                 config_error, config_request, ena, armed, key_sync};
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key_sync <= 2'b00;
        request_sync <= 0;
        count <= 0;
        armed <= 0;
        settle <= 0;
        ena <= 0;
        config_request <= 0;
    end else begin
        key_sync <= {key_sync[0], key_n};
        request_sync <= {request_sync[1:0], request_toggle};
        if (!ena && !config_error) begin
            if ((!armed && key_sync[1]) || (armed && !key_sync[1])) begin
                if (count == DEBOUNCE - 1) begin
                    count <= 0;
                    if (armed) ena <= 1;
                    else armed <= 1;
                end else count <= count + 1'b1;
            end else count <= 0;
            if (request_sync[2] != request_sync[1]) ena <= 1;
        end
        // CBSEL is a constant in each image. Give the hard configuration
        // block eight capture clocks with ENA high before asserting CONFIG.
        if (ena && !config_request && !config_error) begin
            if (settle == 7) config_request <= 1;
            else settle <= settle + 1'b1;
        end
    end
end
endmodule
