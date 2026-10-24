// Layer-reused 8x8 INT8 Conv. Four independently banked input rows and a
// layer-local weight RAM replace repeated AXI reads of the same convolution
// window. All 64 products issue every clock, including across pixel boundaries.
// SAME 3x3, stride 1/2; NHWC C3/C8/C16/C32. No model-specific weights in RTL.
module iris_rain_conv (
    input wire clk, rst_n, start, abort,
    input wire [7:0] width, height,
    input wire [5:0] input_channels, output_channels,
    input wire stride2,
    input wire signed [7:0] input_zero, output_zero, activation_min, activation_max,
    input wire weight_valid, input wire [9:0] weight_index,
    input wire [127:0] weight_data,
    input wire parameter_valid, input wire [6:0] parameter_index,
    input wire [31:0] parameter_data,
    input wire i_valid, input wire [63:0] i_data, output wire i_ready,
    output reg o_valid, output reg [63:0] o_data,
    output reg row_done, input wire row_ack,
    output reg done, output reg [31:0] cycles
);
    localparam WAIT_ROW=0, RUN=1, DRAIN=2, WAIT_ACK=3, FINISH=4;
    reg [2:0] state;
    reg active;
    reg [7:0] ix, iy, ox, oy;
    reg [1:0] input_group, group_index, output_group;
    reg [3:0] tap;
    reg [7:0] weight_address;
    reg [9:0] output_groups_seen;
    wire [1:0] group_last = input_channels==32 ? 3 : input_channels==16 ? 1 : 0;
    wire [1:0] out_group_last = output_channels==32 ? 3 : output_channels==16 ? 1 : 0;
    wire [1:0] group_shift = input_channels==32 ? 2 : input_channels==16 ? 1 : 0;
    wire [7:0] ow = stride2 ? width>>1 : width;
    wire [7:0] oh = stride2 ? height>>1 : height;
    wire signed [10:0] first_row = $signed({3'd0,oy})*(stride2 ? 2 : 1)-(stride2 ? 0 : 1);
    wire signed [10:0] last_row = first_row+2;
    wire signed [10:0] keep_end = (first_row<0 ? 11'sd0 : first_row)+4;
    assign i_ready = active && iy<height && $signed({3'd0,iy})<keep_end;
    wire input_fire = i_valid && i_ready;
    wire row_available = iy>=height || $signed({3'd0,iy})>last_row;
    wire issue = active && state==RUN;
    wire first = group_index==0 && tap==0;
    wire last = group_index==group_last && tap==8;
    wire last_in_row = last && output_group==out_group_last && ox==ow-1;
    wire [3:0] tap_x= tap%3, tap_y=tap/3;
    wire signed [10:0] rx = $signed({3'd0,ox})*(stride2 ? 2 : 1)+$signed({7'd0,tap_x})-(stride2 ? 0 : 1);
    wire signed [10:0] ry = first_row+$signed({7'd0,tap_y});
    wire padding = rx<0 || rx>=width || ry<0 || ry>=height;
    wire [8:0] read_address = ({1'b0,rx[7:0]}<<group_shift)+group_index;
    wire [8:0] write_address = ({1'b0,ix}<<group_shift)+input_group;
    wire [63:0] line_q [0:3];
    generate for(genvar bank=0;bank<4;bank=bank+1)begin:g_line
        reg [63:0] memory [0:511];
        reg [63:0] q;
        always @(posedge clk)begin
            if(input_fire && iy[1:0]==bank)memory[write_address]<=i_data;
            if(issue && !padding && ry[1:0]==bank)q<=memory[read_address];
        end
        assign line_q[bank]=q;
    end endgenerate
    wire [63:0] weights_q [0:7];
    generate for(genvar bank=0;bank<8;bank=bank+1)begin:g_weight
        reg [63:0] memory [0:143];
        reg [63:0] q;
        always @(posedge clk)begin
            if(weight_valid && weight_index[1:0]==bank/2)
                memory[weight_index[9:2]]<=weight_data[(bank%2)*64+:64];
            if(issue)q<=memory[weight_address];
        end
        assign weights_q[bank]=q;
    end endgenerate
    reg signed [31:0] bias[0:31], multiplier[0:31];
    reg signed [7:0] shift[0:31];
    always @(posedge clk)begin
        if(parameter_valid)begin
            if(parameter_index<32)bias[parameter_index[4:0]]<=parameter_data;
            else if(parameter_index<64)multiplier[parameter_index[4:0]]<=parameter_data;
            else shift[parameter_index[4:0]]<=parameter_data[7:0];
        end
    end
    reg [5:0] valid_pipe, first_pipe, last_pipe, row_pipe;
    reg [1:0] out_group_pipe[0:5];
    reg [1:0] bank_q;
    reg padding_q;
    wire [63:0] sample = padding_q ? {8{input_zero}} : line_q[bank_q];
    wire signed [8:0] centered[0:7];
    generate for(genvar c=0;c<8;c=c+1)begin:g_center
        assign centered[c]=$signed({sample[c*8+7],sample[c*8+:8]})-$signed({input_zero[7],input_zero});
    end endgenerate
    reg signed [16:0] products[0:63];
    reg signed [17:0] pairs[0:31];
    reg signed [18:0] quads[0:15];
    reg signed [19:0] sums[0:7];
    reg signed [31:0] acc[0:7], quant_hold[0:7];
    reg [3:0] quant_remaining;
    reg [2:0] quant_index;
    reg [1:0] quant_group;
    reg [2:0] quant_index_pipe[0:3];
    reg [63:0] packed_output;
    wire quant_valid;
    wire [7:0] quant_value;
    wire [4:0] quant_channel = {quant_group,quant_index};
    iris_cnn_requant u_quant(
        .clk(clk),.rst_n(rst_n && !abort),.i_valid(quant_remaining!=0),
        .i_value(quant_hold[quant_index]),.i_multiplier(multiplier[quant_channel]),
        .i_shift(shift[quant_channel]),.i_zero(output_zero),
        .i_min(activation_min),.i_max(activation_max),
        .o_valid(quant_valid),.o_value(quant_value));
    integer j;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=WAIT_ROW;active<=0;ix<=0;iy<=0;ox<=0;oy<=0;input_group<=0;
            group_index<=0;output_group<=0;tap<=0;weight_address<=0;
            valid_pipe<=0;first_pipe<=0;last_pipe<=0;row_pipe<=0;
            bank_q<=0;padding_q<=0;quant_remaining<=0;quant_index<=0;quant_group<=0;
            o_valid<=0;o_data<=0;row_done<=0;done<=0;cycles<=0;packed_output<=0;
            output_groups_seen<=0;
            for(j=0;j<6;j=j+1)out_group_pipe[j]<=0;
            for(j=0;j<4;j=j+1)quant_index_pipe[j]<=0;
        end else begin
            o_valid<=0;
            if(active)cycles<=cycles+1'b1;
            valid_pipe<={valid_pipe[4:0],issue};
            first_pipe<={first_pipe[4:0],first};
            last_pipe<={last_pipe[4:0],last};
            row_pipe<={row_pipe[4:0],last_in_row};
            out_group_pipe[0]<=output_group;
            for(j=1;j<6;j=j+1)out_group_pipe[j]<=out_group_pipe[j-1];
            if(issue)begin bank_q<=ry[1:0];padding_q<=padding;end
            if(valid_pipe[0])for(j=0;j<64;j=j+1)
                products[j]<=centered[j%8]*$signed(weights_q[j/8][(j%8)*8+:8]);
            if(valid_pipe[1])for(j=0;j<32;j=j+1)
                pairs[j]<=$signed(products[j*2])+$signed(products[j*2+1]);
            if(valid_pipe[2])for(j=0;j<16;j=j+1)
                quads[j]<=$signed(pairs[j*2])+$signed(pairs[j*2+1]);
            if(valid_pipe[3])for(j=0;j<8;j=j+1)
                sums[j]<=$signed(quads[j*2])+$signed(quads[j*2+1]);
            if(valid_pipe[4])for(j=0;j<8;j=j+1)begin
                acc[j]<=(first_pipe[4] ? bias[{out_group_pipe[4],3'b000}+j] : acc[j])+$signed(sums[j]);
                if(last_pipe[4])quant_hold[j]<=(first_pipe[4] ? bias[{out_group_pipe[4],3'b000}+j] : acc[j])+$signed(sums[j]);
            end
            if(quant_remaining!=0)begin
                quant_remaining<=quant_remaining-1'b1;quant_index<=quant_index+1'b1;
            end
            if(valid_pipe[4] && last_pipe[4])begin
                quant_remaining<=output_channels==3 ? 3 : 8;quant_index<=0;quant_group<=out_group_pipe[4];
            end
            quant_index_pipe[0]<=quant_index;
            for(j=1;j<4;j=j+1)quant_index_pipe[j]<=quant_index_pipe[j-1];
            if(quant_valid)begin
                packed_output[quant_index_pipe[3]*8+:8]<=quant_value;
                if(quant_index_pipe[3]==(output_channels==3 ? 2 : 7))begin
                    o_data<=output_channels==3 ? {40'd0,quant_value,packed_output[15:0]} : {quant_value,packed_output[55:0]};
                    o_valid<=1;
                    output_groups_seen<=output_groups_seen+1'b1;
                end
            end
            if(input_fire)begin
                if(input_group==group_last)begin
                    input_group<=0;
                    if(ix==width-1)begin ix<=0;iy<=iy+1'b1;end
                    else ix<=ix+1'b1;
                end else input_group<=input_group+1'b1;
            end
            case(state)
                WAIT_ROW:if(active && row_available)state<=RUN;
                RUN:begin
                    weight_address<=weight_address+1'b1;
                    if(group_index==group_last)begin
                        group_index<=0;
                        if(tap==8)begin
                            tap<=0;
                            if(output_group==out_group_last)begin
                                output_group<=0;weight_address<=0;
                                if(ox==ow-1)begin ox<=0;state<=DRAIN;end
                                else ox<=ox+1'b1;
                            end else output_group<=output_group+1'b1;
                        end else tap<=tap+1'b1;
                    end else group_index<=group_index+1'b1;
                end
                DRAIN:if(output_groups_seen==({2'd0,ow}<< (output_channels==32 ? 2 : output_channels==16 ? 1 : 0)) && !o_valid)begin
                    row_done<=1;state<=WAIT_ACK;
                end
                WAIT_ACK:if(row_ack)begin
                    row_done<=0;output_groups_seen<=0;
                    if(oy==oh-1)begin active<=0;done<=1;state<=FINISH;end
                    else begin oy<=oy+1'b1;state<=WAIT_ROW;end
                end
                default:begin end
            endcase
            if(start || abort)begin
                state<=WAIT_ROW;active<=start;ix<=0;iy<=0;ox<=0;oy<=0;input_group<=0;
                group_index<=0;output_group<=0;tap<=0;weight_address<=0;
                valid_pipe<=0;quant_remaining<=0;o_valid<=0;row_done<=0;done<=0;cycles<=0;
                output_groups_seen<=0;
            end
        end
    end
endmodule
