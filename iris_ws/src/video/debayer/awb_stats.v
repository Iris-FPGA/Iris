//=====================================================================
// awb_stats: per-frame R/G/B accumulation on display-domain RGB.
//   - 2 px/clk while i_de (matches debayer rgb_datax2_o packing)
//   - On VS rising edge: latch sums, pulse o_upd, clear accumulators
//   - Gray-world ratios use sumG/sumR (pixel count cancels)
//=====================================================================

module awb_stats (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire        i_vs,
    input  wire [47:0] i_rgb, // {R1,G1,B1, R0,G0,B0} each 8-bit
    input  wire [7:0] i_black_r, i_black_g, i_black_b,
    output reg  [31:0] o_sum_r,
    output reg  [31:0] o_sum_g,
    output reg  [31:0] o_sum_b,
    output reg         o_upd,
    output reg [31:0] o_wb_r, o_wb_g, o_wb_b,
    output reg [23:0] o_wb_pixels, o_pixels
);

wire [7:0] r0 = i_rgb[23:16];
wire [7:0] g0 = i_rgb[15:8];
wire [7:0] b0 = i_rgb[7:0];
wire [7:0] r1 = i_rgb[47:40];
wire [7:0] g1 = i_rgb[39:32];
wire [7:0] b1 = i_rgb[31:24];

// two 8-bit adds into 32-bit acc: max frame sum < 2^30
wire [31:0] add_r = {24'd0, r0} + {24'd0, r1};
wire [31:0] add_g = {24'd0, g0} + {24'd0, g1};
wire [31:0] add_b = {24'd0, b0} + {24'd0, b1};

reg        vs_d;
reg [31:0] acc_r, acc_g, acc_b;
reg [31:0] wb_r, wb_g, wb_b;
reg [23:0] wb_pixels, pixels;
function [7:0] subtract_black;
    input [7:0] v,b;
    begin subtract_black=(v>b)?v-b:0;end
endfunction
wire [7:0] cr0=subtract_black(r0,i_black_r), cg0=subtract_black(g0,i_black_g), cb0=subtract_black(b0,i_black_b);
wire [7:0] cr1=subtract_black(r1,i_black_r), cg1=subtract_black(g1,i_black_g), cb1=subtract_black(b1,i_black_b);
function neutral;
    input [7:0] r,g,b;
    reg [7:0] lo,hi;
    reg [9:0] triple;
    begin
        lo=(r<g)?r:g;lo=(lo<b)?lo:b;
        hi=(r>g)?r:g;hi=(hi>b)?hi:b;
        triple={2'b0,lo}+({2'b0,lo}<<1);
        neutral=(lo>=12 && hi<=235 && triple>=hi);
    end
endfunction
wire n0=neutral(cr0,cg0,cb0), n1=neutral(cr1,cg1,cb1);

wire vs_rise = i_vs & ~vs_d;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d    <= 1'b0;
        acc_r   <= 32'd0;
        acc_g   <= 32'd0;
        acc_b   <= 32'd0;
        o_sum_r <= 32'd0;
        o_sum_g <= 32'd0;
        o_sum_b <= 32'd0;
        o_upd   <= 1'b0;
        wb_r<=0;wb_g<=0;wb_b<=0;wb_pixels<=0;pixels<=0;
        o_wb_r<=0;o_wb_g<=0;o_wb_b<=0;o_wb_pixels<=0;o_pixels<=0;
    end else begin
        vs_d  <= i_vs;
        o_upd <= 1'b0;

        if (vs_rise) begin
            o_sum_r <= acc_r;
            o_sum_g <= acc_g;
            o_sum_b <= acc_b;
            o_upd   <= 1'b1;
            acc_r   <= 32'd0;
            acc_g   <= 32'd0;
            acc_b   <= 32'd0;
            o_wb_r<=wb_r;o_wb_g<=wb_g;o_wb_b<=wb_b;
            o_wb_pixels<=wb_pixels;o_pixels<=pixels;
            wb_r<=0;wb_g<=0;wb_b<=0;wb_pixels<=0;pixels<=0;
        end else if (i_de) begin
            acc_r <= acc_r + add_r;
            acc_g <= acc_g + add_g;
            acc_b <= acc_b + add_b;
            wb_r<=wb_r+(n0?{24'd0,cr0}:32'd0)+(n1?{24'd0,cr1}:32'd0);
            wb_g<=wb_g+(n0?{24'd0,cg0}:32'd0)+(n1?{24'd0,cg1}:32'd0);
            wb_b<=wb_b+(n0?{24'd0,cb0}:32'd0)+(n1?{24'd0,cb1}:32'd0);
            wb_pixels<=wb_pixels+{23'd0,n0}+{23'd0,n1};
            pixels<=pixels+24'd2;
        end
    end
end

endmodule
