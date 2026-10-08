// C4 INT8 convolution with independently banked line RAM and 16 MAC lanes.
// Frame dimensions/stride/dilation are hardware parameters. BN is folded into
// weights/bias at export; ReLU is the exported quantized activation interval.
// No frame DDR traffic, software pixel arithmetic or completion IRQ dependency.
module iris_cnn_requant (
    input wire clk, rst_n, i_valid,
    input wire signed [31:0] i_value, i_multiplier,
    input wire signed [7:0] i_shift, i_zero, i_min, i_max,
    output reg o_valid, output reg [7:0] o_value
);
    reg [3:0] v;
    reg signed [63:0] product;
    reg signed [31:0] high, rounded;
    reg [5:0] right1, right2;
    reg signed [7:0] zero1,zero2,zero3,min1,min2,min3,max1,max2,max3;
    wire [5:0] left = i_shift>0 ? i_shift : 0;
    wire signed [31:0] shifted = i_value <<< left;
    wire signed [64:0] nudged = {product[63],product}+65'sd1073741824;
    wire [31:0] mask = right2==0 ? 0 : (32'hffffffff >> (32-right2));
    wire [31:0] threshold = (mask>>1)+{31'd0,high[31]};
    wire signed [31:0] shifted_high = high >>> right2;
    wire signed [31:0] divide = shifted_high + $signed({31'd0,(high & mask)>threshold});
    wire signed [32:0] translated = {rounded[31],rounded} + {{25{zero3[7]}},zero3};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin v<=0;o_valid<=0;o_value<=0;product<=0;high<=0;rounded<=0;
            right1<=0;right2<=0;zero1<=0;zero2<=0;zero3<=0;
            min1<=0;min2<=0;min3<=0;max1<=0;max2<=0;max3<=0;end
        else begin
            v<={v[2:0],i_valid};o_valid<=v[2];
            if(i_valid)begin
                product<=shifted*i_multiplier;right1<=i_shift<0 ? -i_shift : 0;
                zero1<=i_zero;min1<=i_min;max1<=i_max;
            end
            if(v[0])begin
                high<=nudged >>> 31;right2<=right1;zero2<=zero1;min2<=min1;max2<=max1;
            end
            if(v[1])begin rounded<=divide;zero3<=zero2;min3<=min2;max3<=max2;end
            if(v[2])o_value<=translated<$signed(min3) ? min3 : translated>$signed(max3) ? max3 : translated[7:0];
        end
    end
endmodule

module iris_stream_conv #(
    parameter WIDTH=640, HEIGHT=480, STRIDE=2, KERNEL=3, DILATION=1
)(
    input wire clk, rst_n, start, abort,
    input wire parameter_valid, input wire [5:0] parameter_index,
    input wire [31:0] parameter_value,
    output wire parameters_ready,
    input wire i_valid, input wire [31:0] i_pixel, output wire i_ready,
    output reg o_valid, output reg [31:0] o_pixel, input wire o_ready,
    output reg frame_done, output reg [31:0] pixel_count
);
    localparam OW=(WIDTH+STRIDE-1)/STRIDE, OH=(HEIGHT+STRIDE-1)/STRIDE;
    localparam SPAN=(KERNEL-1)*DILATION+1;
    localparam PAD_X=((OW-1)*STRIDE+SPAN-WIDTH)/2;
    localparam PAD_Y=((OH-1)*STRIDE+SPAN-HEIGHT)/2;
    // Keep the current window plus the next stride of rows. Without these
    // spare banks the producer must stop for a whole consumer output row.
    localparam ROWS=KERNEL==1 ? 1 : SPAN+STRIDE;
    localparam WAIT_ROW=0, INIT_PIXEL=1, TAPS=2, WAIT_QUANT=3, EMIT=4, FINISHED=5;
    reg [2:0] state;
    reg active;
    reg [10:0] in_x,in_y,out_x,out_y;
    reg [3:0] in_bank;
    reg [3:0] ky,kx,tap_index;
    reg [3:0] bank_q;
    reg padding_q;
    reg [10:0] row_tag [0:ROWS-1];
    reg [ROWS-1:0] row_valid;
    // A 128-bit x 9 ROM would consume eight RAM10 blocks per layer despite
    // holding only 144 bytes. Use registers for these small loaded weights;
    // keep the substantial activation line storage in block RAM.
    reg [127:0] weights [0:KERNEL*KERNEL-1];
    reg [95:0] weight_partial;
    reg [127:0] weight_q;
    reg [31:0] pointwise_input;
    reg signed [31:0] bias [0:3], multiplier [0:3];
    reg signed [7:0] shift [0:3];
    reg signed [7:0] input_zero,output_zero,activation_min,activation_max;
    reg [51:0] loaded;
    localparam [51:0] REQUIRED=KERNEL==1 ? 52'hffff00000000f : 52'hfffffffffffff;
    assign parameters_ready=(loaded & REQUIRED)==REQUIRED;
    // Stop before overwriting a row still needed by the current output row.
    wire signed [12:0] oldest=$signed({2'd0,out_y})*STRIDE-PAD_Y;
    wire signed [12:0] furthest=$signed({2'd0,out_y})*STRIDE+SPAN-1-PAD_Y;
    wire signed [12:0] keep_end=(oldest<0 ? 13'sd0 : oldest)+ROWS;
    assign i_ready=KERNEL==1 ? active && state==WAIT_ROW :
                  active && in_y<HEIGHT && $signed({2'd0,in_y})<keep_end;
    wire input_fire=i_ready && i_valid;
    wire row_available=in_y>=HEIGHT || $signed({2'd0,in_y})>furthest;
    wire signed [12:0] rx=$signed({2'd0,out_x})*STRIDE+$signed({9'd0,kx})*DILATION-PAD_X;
    wire signed [12:0] ry=$signed({2'd0,out_y})*STRIDE+$signed({9'd0,ky})*DILATION-PAD_Y;
    wire padding=rx<0 || rx>=WIDTH || ry<0 || ry>=HEIGHT;
    reg [3:0] read_bank;
    integer b;
    always @* begin
        read_bank=0;
        for(integer j=0;j<ROWS;j=j+1)
            if(row_valid[j] && row_tag[j]==ry[10:0])read_bank=j;
    end
    wire tap_fire=active && state==TAPS;
    wire tap_last=kx==KERNEL-1 && ky==KERNEL-1;
    wire [31:0] bank_read [0:ROWS-1];
    generate for(genvar rb=0;rb<ROWS;rb=rb+1)begin:g_line
      if(KERNEL!=1)begin:g_spatial
        reg [31:0] memory [0:WIDTH-1];
        reg [31:0] read_q;
        always @(posedge clk)begin
            if(input_fire && in_bank==rb)memory[in_x]<=i_pixel;
            if(tap_fire && !padding && read_bank==rb)read_q<=memory[rx[10:0]];
        end
        assign bank_read[rb]=read_q;
      end else begin:g_pointwise
        assign bank_read[rb]=32'd0;
      end
    end endgenerate
    wire [31:0] sample=KERNEL==1 ? pointwise_input : padding_q ? {4{input_zero}} : bank_read[bank_q];
    reg tap_valid_q,tap_last_q,product_valid_q,product_last_q,sum_valid_q,sum_last_q;
    reg signed [16:0] product [0:15];
    reg signed [31:0] sums [0:3],acc [0:3];
    wire signed [8:0] input_value [0:3];
    generate for(genvar c=0;c<4;c=c+1)begin:g_input
        assign input_value[c]=$signed({sample[c*8+7],sample[c*8+:8]})-$signed({input_zero[7],input_zero});
    end endgenerate
    wire quant_fire=sum_valid_q && sum_last_q;
    wire [7:0] quantized [0:3];
    wire [3:0] quant_valid;
    generate for(genvar c=0;c<4;c=c+1)begin:g_quant
        iris_cnn_requant u_quant(.clk(clk),.rst_n(rst_n && !abort),.i_valid(quant_fire),
            .i_value(acc[c]+sums[c]),.i_multiplier(multiplier[c]),.i_shift(shift[c]),
            .i_zero(output_zero),.i_min(activation_min),.i_max(activation_max),
            .o_valid(quant_valid[c]),.o_value(quantized[c]));
    end endgenerate
    integer wt;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)for(wt=0;wt<KERNEL*KERNEL;wt=wt+1)weights[wt]<=0;
        else if(parameter_valid && parameter_index<KERNEL*KERNEL*4 && parameter_index[1:0]==3)
            weights[parameter_index[5:2]]<={parameter_value,weight_partial};
    end
    always @(posedge clk)begin
        if(tap_fire)weight_q<=weights[tap_index];
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=WAIT_ROW;active<=0;in_x<=0;in_y<=0;out_x<=0;out_y<=0;in_bank<=0;
            row_valid<=0;ky<=0;kx<=0;tap_index<=0;bank_q<=0;padding_q<=0;
            tap_valid_q<=0;tap_last_q<=0;product_valid_q<=0;product_last_q<=0;sum_valid_q<=0;sum_last_q<=0;
            o_valid<=0;o_pixel<=0;frame_done<=0;pixel_count<=0;loaded<=0;weight_partial<=0;
            input_zero<=0;output_zero<=0;activation_min<=-128;activation_max<=127;pointwise_input<=0;
            for(b=0;b<4;b=b+1)begin bias[b]<=0;multiplier[b]<=0;shift[b]<=0;acc[b]<=0;sums[b]<=0;end
            for(b=0;b<16;b=b+1)product[b]<=0;
            for(b=0;b<ROWS;b=b+1)row_tag[b]<=0;
        end else begin
            if(parameter_valid)begin
                if(parameter_index<52)loaded[parameter_index]<=1'b1;
                if(parameter_index<36)case(parameter_index[1:0])
                    0:weight_partial[31:0]<=parameter_value;
                    1:weight_partial[63:32]<=parameter_value;
                    2:weight_partial[95:64]<=parameter_value;
                    default:begin end
                endcase
                else if(parameter_index<40)bias[parameter_index-36]<=parameter_value;
                else if(parameter_index<44)multiplier[parameter_index-40]<=parameter_value;
                else if(parameter_index<48)shift[parameter_index-44]<=parameter_value[7:0];
                else case(parameter_index)
                    48:input_zero<=parameter_value[7:0];49:output_zero<=parameter_value[7:0];
                    50:activation_min<=parameter_value[7:0];51:activation_max<=parameter_value[7:0];
                endcase
            end
            tap_valid_q<=tap_fire;tap_last_q<=tap_last;
            product_valid_q<=tap_valid_q;product_last_q<=tap_last_q;
            sum_valid_q<=product_valid_q;sum_last_q<=product_last_q;
            if(tap_fire)begin bank_q<=read_bank;padding_q<=padding;end
            if(tap_valid_q)for(b=0;b<16;b=b+1)
                product[b]<=input_value[b%4]*$signed(weight_q[b*8+:8]);
            if(product_valid_q)for(b=0;b<4;b=b+1)
                sums[b]<={{15{product[b*4][16]}},product[b*4]}+{{15{product[b*4+1][16]}},product[b*4+1]}+
                         {{15{product[b*4+2][16]}},product[b*4+2]}+{{15{product[b*4+3][16]}},product[b*4+3]};
            if(sum_valid_q)for(b=0;b<4;b=b+1)acc[b]<=acc[b]+sums[b];
            if(input_fire)begin
                pointwise_input<=i_pixel;
                if(in_x==WIDTH-1)begin
                    row_tag[in_bank]<=in_y;row_valid[in_bank]<=1'b1;
                    in_y<=in_y+1'b1;in_x<=0;in_bank<=in_bank==ROWS-1 ? 0 : in_bank+1'b1;
                end else in_x<=in_x+1'b1;
            end
            case(state)
                WAIT_ROW:if(KERNEL==1 ? input_fire : active && row_available)state<=INIT_PIXEL;
                INIT_PIXEL:begin
                    for(b=0;b<4;b=b+1)acc[b]<=bias[b];
                    ky<=0;kx<=0;tap_index<=0;state<=TAPS;
                end
                TAPS:if(tap_last)state<=WAIT_QUANT;
                     else begin tap_index<=tap_index+1'b1;
                         if(kx==KERNEL-1)begin kx<=0;ky<=ky+1'b1;end else kx<=kx+1'b1;end
                WAIT_QUANT:if(quant_valid[0])begin
                    o_pixel<={quantized[3],quantized[2],quantized[1],quantized[0]};o_valid<=1;state<=EMIT;
                end
                EMIT:if(o_ready)begin
                    o_valid<=0;pixel_count<=pixel_count+1'b1;
                    if(out_x==OW-1)begin out_x<=0;
                        if(out_y==OH-1)begin state<=FINISHED;active<=0;frame_done<=1;end
                        else begin out_y<=out_y+1'b1;state<=WAIT_ROW;end
                    end else begin out_x<=out_x+1'b1;state<=KERNEL==1 ? WAIT_ROW : INIT_PIXEL;end
                end
                default:begin end
            endcase
            if(start || abort)begin
                state<=WAIT_ROW;active<=start;in_x<=0;in_y<=0;out_x<=0;out_y<=0;in_bank<=0;
                row_valid<=0;o_valid<=0;frame_done<=0;pixel_count<=0;
                tap_valid_q<=0;product_valid_q<=0;sum_valid_q<=0;
            end
        end
    end
endmodule
