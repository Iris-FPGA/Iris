// 1920x1080 RGB at two pixels/clock -> INT8 NHWC 640x480x4.
// Center crop 1440x1080 to preserve the model's 4:3 aspect ratio, then
// asymmetric nearest-neighbor sampling: src = floor(dst * 9 / 4).
// Input RGB is after display color correction and before any OSD.
// This tap cannot backpressure video; its consumer must abort a frame on
// overflow and only publish a complete, committed frame to the CPU.
module iris_style_preprocess (
    input wire clk, input wire rst_n, input wire enable,
    input wire i_vs, input wire i_de, input wire [47:0] i_rgb,
    output reg o_valid, output reg [31:0] o_rgba,
    output reg o_sof, output reg o_eol, output reg o_eof,
    output reg [9:0] o_x, output reg [8:0] o_y
);
reg vs_d, de_d, frame_active;
reg [11:0] src_x, src_y, next_x, next_y;
reg [1:0] phase_x, phase_y;
reg [9:0] dst_x;
reg [8:0] dst_y;
wire frame_start = i_vs && !vs_d;
wire row_selected = src_y == next_y && dst_y < 480;
wire first_selected = src_x == next_x;
wire second_selected = src_x + 12'd1 == next_x;
wire [23:0] selected_rgb = first_selected ? i_rgb[47:24] : i_rgb[23:0];
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d <= 0; de_d <= 0; frame_active <= 0; src_x <= 0; src_y <= 0;
        next_x <= 240; next_y <= 0; phase_x <= 0; phase_y <= 0;
        dst_x <= 0; dst_y <= 0;
        o_valid <= 0; o_rgba <= 0; o_sof <= 0; o_eol <= 0; o_eof <= 0;
        o_x <= 0; o_y <= 0;
    end else begin
        vs_d <= i_vs; de_d <= i_de;
        o_valid <= 0; o_sof <= 0; o_eol <= 0; o_eof <= 0;
        if (frame_start || !enable) begin
            frame_active <= frame_start && enable;
            src_x <= 0; src_y <= 0; next_x <= 240; next_y <= 0;
            dst_x <= 0; dst_y <= 0; phase_x <= 0; phase_y <= 0;
        end else if (i_de && frame_active) begin
            src_x <= src_x + 12'd2;
            if (row_selected && dst_x < 640 && (first_selected || second_selected)) begin
                o_valid <= 1;
                // Lowest address byte is R; dummy channel's uint8 value is 0.
                o_rgba <= {8'h80, selected_rgb[7:0] ^ 8'h80,
                                  selected_rgb[15:8] ^ 8'h80,
                                  selected_rgb[23:16] ^ 8'h80};
                o_x <= dst_x; o_y <= dst_y;
                o_sof <= dst_x == 0 && dst_y == 0;
                o_eol <= dst_x == 639;
                o_eof <= dst_x == 639 && dst_y == 479;
                dst_x <= dst_x + 10'd1;
                next_x <= next_x + (phase_x == 3 ? 12'd3 : 12'd2);
                phase_x <= phase_x + 2'd1;
            end
        end else begin
            src_x <= 0; next_x <= 240; dst_x <= 0; phase_x <= 0;
            if (de_d) begin
                src_y <= src_y + 12'd1;
                if (row_selected) begin
                    dst_y <= dst_y + 9'd1;
                    next_y <= next_y + (phase_y == 3 ? 12'd3 : 12'd2);
                    phase_y <= phase_y + 2'd1;
                end
            end
        end
    end
end
endmodule
