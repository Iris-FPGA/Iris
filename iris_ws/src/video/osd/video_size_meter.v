// Count active pixels/lines, publish one stable payload per frame.
// CSI data-valid can have gaps: HS, rather than DE, terminates its lines.
module video_size_meter #(
    parameter PIXELS_PER_CLOCK = 4,
    parameter USE_HSYNC = 1
) (
    input clk, rst_n, i_hs, i_vs, i_de,
    output reg [11:0] o_width, o_height,
    output reg o_toggle
);
reg hs_d, vs_d, de_d;
reg [11:0] line_pixels, max_width, lines;
wire line_end = USE_HSYNC ? (hs_d && !i_hs) : (de_d && !i_de);
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hs_d<=0; vs_d<=0; de_d<=0;
        line_pixels<=0; max_width<=0; lines<=0;
        o_width<=0; o_height<=0; o_toggle<=0;
    end else begin
        hs_d<=i_hs; vs_d<=i_vs; de_d<=i_de;
        if (i_vs && !vs_d) begin
            o_width <= max_width;
            o_height <= lines;
            o_toggle <= ~o_toggle;
            line_pixels<=0; max_width<=0; lines<=0;
        end else if (line_end) begin
            if (line_pixels != 0) begin
                if (line_pixels > max_width) max_width <= line_pixels;
                lines <= lines + 1'b1;
            end
            line_pixels <= i_de ? PIXELS_PER_CLOCK : 0;
        end else if (i_de) line_pixels <= line_pixels + PIXELS_PER_CLOCK;
    end
end
endmodule
