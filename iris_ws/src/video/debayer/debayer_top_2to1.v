// Two pixels/clock, first pixel in [15:8]. SC431HAI native BGGR at (0,0).
// 3x3 bilinear interpolation, same-colour reflection at every border.
// One complete line of raster delay permits flushing the final image row.
// Outputs are linear RGB: exposure statistics precede white balance/gamma.
module debayer_top_2to1 #(
    parameter H_TOTAL = 1100,
    parameter H_ACTIVE = 960,
    parameter V_ACTIVE = 1080,
    parameter BAYER_BGGR = 1
) (
    input in_pclk, in_rstn,
    input raw_vs_i, raw_hs_i, raw_de_i, raw_valid_i,
    input [15:0] raw_datax4_i,
    input [2:0] i_r_gain, i_g_gain, i_b_gain,
    output reg rgb_vs_o, rgb_hs_o, rgb_de_o, rgb_valid_o,
    output wire [47:0] rgb_datax2_o
);
reg [47:0] rgb_rggb;
assign rgb_datax2_o = BAYER_BGGR ?
    {rgb_rggb[31:24],rgb_rggb[39:32],rgb_rggb[47:40],
     rgb_rggb[7:0],rgb_rggb[15:8],rgb_rggb[23:16]} : rgb_rggb;
localparam XW = $clog2(H_ACTIVE);
localparam TW = $clog2(H_TOTAL);
reg [15:0] row1 [0:H_ACTIVE-1];
reg [15:0] row2 [0:H_ACTIVE-1];
reg [2:0] raster [0:H_TOTAL-1];
reg [TW-1:0] raster_addr;
reg [TW:0] raster_fill;
wire [2:0] delayed = (raster_fill < H_TOTAL) ? 3'b000 : raster[raster_addr];
wire active = raw_de_i && raw_valid_i;
reg [XW-1:0] x;
reg [11:0] y;
reg de_d, vs_d;
integer k;
initial begin
    for (k=0; k<H_TOTAL; k=k+1) raster[k] = 3'b000;
end
reg [15:0] top_s, mid_s, bot_s;
reg hs_s, vs_s, de_s, odd_s;
always @(posedge in_pclk) begin
    if (!in_rstn) begin
        raster_addr <= 0; raster_fill <= 0;
        x <= 0; y <= 0; de_d <= 0; vs_d <= 0;
        top_s <= 0; mid_s <= 0; bot_s <= 0;
        hs_s <= 0; vs_s <= 0; de_s <= 0; odd_s <= 0;
    end else begin
        if (raster_fill < H_TOTAL) raster_fill <= raster_fill + 1'b1;
        raster[raster_addr] <= {raw_hs_i, raw_vs_i, active};
        raster_addr <= (raster_addr == H_TOTAL-1) ? 0 : raster_addr + 1'b1;
        de_d <= active;
        vs_d <= raw_vs_i;
        if (raw_vs_i && !vs_d) y <= 0;
        else if (de_d && !active) y <= y + 1'b1;
        if (active || delayed[0]) begin
            x <= (x == H_ACTIVE-1) ? 0 : x + 1'b1;
            top_s <= (y == 1) ? raw_datax4_i : row2[x];
            mid_s <= row1[x];
            bot_s <= active ? raw_datax4_i : row2[x];
        end else x <= 0;
        if (active) begin
            row1[x] <= raw_datax4_i;
            row2[x] <= row1[x];
        end
        hs_s <= delayed[2]; vs_s <= delayed[1]; de_s <= delayed[0];
        odd_s <= ~y[0]; // centre row is incoming row minus one
    end
end
reg [15:0] top_p, mid_p, bot_p;
reg [7:0] top_left, mid_left, bot_left;
reg hs_p, vs_p, de_p, odd_p, first_s;
wire [7:0] tl = first_s ? top_p[7:0] : top_left;
wire [7:0] ml = first_s ? mid_p[7:0] : mid_left;
wire [7:0] bl = first_s ? bot_p[7:0] : bot_left;
wire [7:0] tr = de_s ? top_s[15:8] : top_p[15:8];
wire [7:0] mr = de_s ? mid_s[15:8] : mid_p[15:8];
wire [7:0] br = de_s ? bot_s[15:8] : bot_p[15:8];
function [7:0] avg2;
    input [7:0] a,b;
    reg [8:0] sum;
    begin sum = {1'b0,a}+{1'b0,b}+9'd1; avg2=sum[8:1]; end
endfunction
function [7:0] avg4;
    input [7:0] a,b,c,d;
    reg [9:0] sum;
    begin
        sum={2'b0,a}+{2'b0,b}+{2'b0,c}+{2'b0,d}+10'd2;
        avg4=sum[9:2];
    end
endfunction
always @(posedge in_pclk) begin
    if (!in_rstn) begin
        top_p<=0; mid_p<=0; bot_p<=0;
        top_left<=0; mid_left<=0; bot_left<=0;
        hs_p<=0; vs_p<=0; de_p<=0; odd_p<=0; first_s<=1;
        rgb_vs_o<=0; rgb_hs_o<=0; rgb_de_o<=0; rgb_valid_o<=0;
        rgb_rggb<= 0;
    end else begin
        top_p<=top_s; mid_p<=mid_s; bot_p<=bot_s;
        top_left<=top_p[7:0]; mid_left<=mid_p[7:0]; bot_left<=bot_p[7:0];
        first_s <= !de_p;
        hs_p<=hs_s; vs_p<=vs_s; de_p<=de_s; odd_p<=odd_s;
        rgb_hs_o<=hs_p; rgb_vs_o<=vs_p; rgb_de_o<=de_p; rgb_valid_o<=de_p;
        if (!de_p) rgb_rggb<= 0;
        else if (!odd_p) begin // R G row
            rgb_rggb <= {
                mid_p[15:8], avg4(top_p[15:8],bot_p[15:8],ml,mid_p[7:0]),
                avg4(tl,top_p[7:0],bl,bot_p[7:0]),
                avg2(mid_p[15:8],mr), mid_p[7:0], avg2(top_p[7:0],bot_p[7:0])};
        end else begin // G B row
            rgb_rggb <= {
                avg2(top_p[15:8],bot_p[15:8]), mid_p[15:8], avg2(ml,mid_p[7:0]),
                avg4(top_p[15:8],tr,bot_p[15:8],br),
                avg4(top_p[7:0],bot_p[7:0],mid_p[15:8],mr), mid_p[7:0]};
        end
    end
end
endmodule
