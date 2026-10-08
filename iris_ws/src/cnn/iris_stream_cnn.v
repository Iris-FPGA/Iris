// SRAM line-buffer CNN: DDR input -> Conv3s2 -> Conv3(d) -> Conv1 -> NN2x DDR.
// CI 0x240..0x24b. One full frame task, no intermediate DDR tensors.
// AXI has one read burst and one write burst in flight independently. Writes
// are completely staged before AW; WVALID never bubbles inside a burst.
module iris_stream_cnn #(
    parameter WIDTH=640, HEIGHT=480, DILATION=2
)(
    input wire clk,rst_n,vendor_idle,
    input wire cmd_valid,input wire [9:0] cmd_function_id,
    input wire [31:0] cmd_inputs_0,cmd_inputs_1,output wire cmd_ready,
    output reg rsp_valid,output reg [31:0] rsp_outputs_0,input wire rsp_ready,
    output reg busy,output wire irq,
    output wire [31:0] araddr,output wire [7:0] arlen,
    output wire arvalid,input wire arready,
    input wire [127:0] rdata,input wire rvalid,output wire rready,
    input wire rlast,input wire [1:0]rresp,
    output wire [31:0] awaddr,output wire [7:0]awlen,
    output wire awvalid,input wire awready,
    output wire [127:0]wdata,output wire wvalid,input wire wready,output wire wlast,
    input wire bvalid,output wire bready,input wire [1:0]bresp
);
    localparam PIXELS=WIDTH*HEIGHT, BEATS=PIXELS/4, LOW_WIDTH=WIDTH/2, LOW_HEIGHT=HEIGHT/2;
    localparam ROW_WORDS=WIDTH/4;
    localparam R_IDLE=0,R_ADDR=1,R_DATA=2,R_PRIME=3,R_PIXELS=4,R_FETCH=5,R_DONE=6,R_DRAIN=7;
    localparam W_COLLECT=0,W_FETCH=1,W_LATCH=2,W_ADDR=3,W_DATA=4,W_RESP=5,W_DONE=6;
    reg [2:0] rs,ws;
    reg [31:0] src,dst,read_cursor,write_cursor;
    reg [31:0] read_remaining;
    reg [4:0] read_beats,write_beats;
    reg [4:0] r_index;
    reg [3:0] read_word,stage_index,send_index;
    reg [1:0] read_lane;
    reg [10:0] low_x,low_y,row_word;
    reg row_repeat;
    reg [31:0] first_pixel;
    reg [127:0] input_burst [0:15], output_row [0:ROW_WORDS-1], output_burst [0:15];
    reg [127:0] input_q,row_q,write_q;
    reg [31:0] cycles,last_cycles,dummy_bad,read_count,write_count;
    reg done,error,abort_pending,core_start;
    reg [7:0]error_code;
    wire stopping=abort_pending || error;
    assign irq=done && !error;
    assign cmd_ready=!rsp_valid || rsp_ready;
    wire cmd_fire=cmd_valid && cmd_ready;
    wire [2:0] configured,core_done;
    wire [31:0] core_pixels [0:2];
    wire [31:0] p0,p1,p2;
    wire v0,v1,v2,ready0,ready1,ready2;
    wire input_valid=busy && !stopping && rs==R_PIXELS;
    wire [31:0] input_pixel=input_q[read_lane*32+:32];
    wire parameter_valid=cmd_fire && cmd_function_id==10'h244 && !busy &&
                         cmd_inputs_0[31:10]==0 && cmd_inputs_0[7:6]==0 && cmd_inputs_0[9:8]<3 &&
                         cmd_inputs_0[5:0]<52 &&
                         (!(cmd_inputs_0[5:0]>=40 && cmd_inputs_0[5:0]<44) || !cmd_inputs_1[31]) &&
                         (!(cmd_inputs_0[5:0]>=44 && cmd_inputs_0[5:0]<48) ||
                          ($signed(cmd_inputs_1)>=-31 && $signed(cmd_inputs_1)<=0));
    wire [31:0] pixel0_count=core_pixels[0];
    iris_stream_conv #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.STRIDE(2),.KERNEL(3),.DILATION(1)) u0(
        .clk(clk),.rst_n(rst_n),.start(core_start),.abort(stopping),
        .parameter_valid(parameter_valid && cmd_inputs_0[9:8]==0),.parameter_index(cmd_inputs_0[5:0]),.parameter_value(cmd_inputs_1),
        .parameters_ready(configured[0]),.i_valid(input_valid),.i_pixel(input_pixel),.i_ready(ready0),
        .o_valid(v0),.o_pixel(p0),.o_ready(ready1),.frame_done(core_done[0]),.pixel_count(core_pixels[0]));
    iris_stream_conv #(.WIDTH(LOW_WIDTH),.HEIGHT(LOW_HEIGHT),.STRIDE(1),.KERNEL(3),.DILATION(DILATION)) u1(
        .clk(clk),.rst_n(rst_n),.start(core_start),.abort(stopping),
        .parameter_valid(parameter_valid && cmd_inputs_0[9:8]==1),.parameter_index(cmd_inputs_0[5:0]),.parameter_value(cmd_inputs_1),
        .parameters_ready(configured[1]),.i_valid(v0),.i_pixel(p0),.i_ready(ready1),
        .o_valid(v1),.o_pixel(p1),.o_ready(ready2),.frame_done(core_done[1]),.pixel_count(core_pixels[1]));
    wire output_ready=busy && !stopping && ws==W_COLLECT;
    iris_stream_conv #(.WIDTH(LOW_WIDTH),.HEIGHT(LOW_HEIGHT),.STRIDE(1),.KERNEL(1),.DILATION(1)) u2(
        .clk(clk),.rst_n(rst_n),.start(core_start),.abort(stopping),
        .parameter_valid(parameter_valid && cmd_inputs_0[9:8]==2),.parameter_index(cmd_inputs_0[5:0]),.parameter_value(cmd_inputs_1),
        .parameters_ready(configured[2]),.i_valid(v1),.i_pixel(p1),.i_ready(ready2),
        .o_valid(v2),.o_pixel(p2),.o_ready(output_ready),.frame_done(core_done[2]),.pixel_count(core_pixels[2]));
    assign araddr=read_cursor;
    assign arlen=read_beats-1'b1;
    assign arvalid=busy && rs==R_ADDR;
    assign rready=busy && (rs==R_DATA || rs==R_DRAIN);
    assign awaddr=write_cursor;
    assign awlen=write_beats-1'b1;
    assign awvalid=busy && ws==W_ADDR;
    assign wdata=write_q;
    assign wvalid=busy && ws==W_DATA;
    assign wlast=send_index==write_beats-1'b1;
    assign bready=busy && ws==W_RESP;
    wire [3:0] next_send=ws==W_DATA && wready ? send_index+1'b1 : send_index;
    // Canonical registered simple-dual-port RAM accesses, no reset on arrays.
    always @(posedge clk)begin
        if(rvalid && rready && rs==R_DATA && r_index<16)input_burst[r_index[3:0]]<=rdata;
        if(rs==R_PRIME || rs==R_FETCH)input_q<=input_burst[read_word];
        if(v2 && output_ready && low_x[0])output_row[low_x>>1]<={p2,p2,first_pixel,first_pixel};
        if(ws==W_FETCH)row_q<=output_row[row_word+stage_index];
        if(ws==W_LATCH)output_burst[stage_index]<=row_q;
        write_q<=output_burst[next_send];
    end
    wire [32:0] src_end={1'b0,src}+PIXELS*4;
    wire [32:0] dst_end={1'b0,dst}+PIXELS*4;
    wire addresses_valid=src[3:0]==0 && dst[3:0]==0 && src_end<=33'h010000000 && dst_end<=33'h010000000 &&
                          (src_end<={1'b0,dst} || dst_end<={1'b0,src});
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            rs<=R_DONE;ws<=W_DONE;src<=0;dst<=0;read_cursor<=0;write_cursor<=0;read_remaining<=0;
            read_beats<=0;write_beats<=0;r_index<=0;read_word<=0;read_lane<=0;stage_index<=0;send_index<=0;
            low_x<=0;low_y<=0;row_word<=0;row_repeat<=0;first_pixel<=0;cycles<=0;last_cycles<=0;
            dummy_bad<=0;read_count<=0;write_count<=0;busy<=0;done<=0;error<=0;abort_pending<=0;error_code<=0;
            core_start<=0;rsp_valid<=0;rsp_outputs_0<=0;
        end else begin
            core_start<=0;
            if(rsp_valid && rsp_ready)rsp_valid<=0;
            if(cmd_fire)begin
                rsp_valid<=1;rsp_outputs_0<=0;
                case(cmd_function_id)
                    10'h240:rsp_outputs_0<=32'h49430101;
                    10'h241:if(busy)rsp_outputs_0<=32'hfffffffe;else begin src<=cmd_inputs_0;dst<=cmd_inputs_1;end
                    10'h242:rsp_outputs_0<={16'(HEIGHT),16'(WIDTH)};
                    10'h243:case(cmd_inputs_0)
                        0:rsp_outputs_0<=core_pixels[0];1:rsp_outputs_0<=core_pixels[1];2:rsp_outputs_0<=core_pixels[2];
                        default:rsp_outputs_0<=32'hffffffff;
                    endcase
                    10'h244:if(busy)rsp_outputs_0<=32'hfffffffe;else if(!parameter_valid)rsp_outputs_0<=32'hffffffff;
                    10'h245:begin
                        if(busy || !vendor_idle)rsp_outputs_0<=32'hfffffffe;
                        else if(!addresses_valid || configured!=3'b111)rsp_outputs_0<=32'hffffffff;
                        else begin
                            busy<=1;done<=0;error<=0;abort_pending<=0;error_code<=0;core_start<=1;
                            cycles<=0;dummy_bad<=0;read_count<=0;write_count<=0;read_cursor<=src;write_cursor<=dst;
                            read_remaining<=BEATS;read_beats<=BEATS>=16 ? 16 : BEATS;read_word<=0;read_lane<=0;r_index<=0;
                            rs<=R_ADDR;ws<=W_COLLECT;low_x<=0;low_y<=0;row_word<=0;row_repeat<=0;send_index<=0;
                        end
                    end
                    10'h246:rsp_outputs_0<={16'd0,error_code,4'd0,configured==3'b111,error,done,busy};
                    10'h247:if(busy)begin abort_pending<=1;error<=1;error_code<=4;end
                    10'h248:rsp_outputs_0<=dummy_bad;
                    10'h249:rsp_outputs_0<=read_count;
                    10'h24a:rsp_outputs_0<=write_count;
                    10'h24b:rsp_outputs_0<=busy ? cycles : last_cycles;
                    10'h24c:if(busy)rsp_outputs_0<=32'hfffffffe;else done<=0;
                    default:rsp_outputs_0<=32'hffffffff;
                endcase
            end
            if(busy)begin
                cycles<=cycles+1'b1;
                case(rs)
                    R_ADDR:if(arready)begin r_index<=0;rs<=R_DATA;end
                    R_DATA:if(rvalid)begin
                        read_count<=read_count+1'b1;
                        dummy_bad<=dummy_bad+{31'd0,rdata[31:24]!=8'h80}+{31'd0,rdata[63:56]!=8'h80}+
                                   {31'd0,rdata[95:88]!=8'h80}+{31'd0,rdata[127:120]!=8'h80};
                        if(rresp!=0 || rlast!=(r_index==read_beats-1) ||
                           rdata[31:24]!=8'h80 || rdata[63:56]!=8'h80 || rdata[95:88]!=8'h80 || rdata[127:120]!=8'h80)begin
                            error<=1;error_code<=rresp!=0 ? 2 : rlast!=(r_index==read_beats-1) ? 5 : 6;
                            rs<=rlast ? R_DONE : R_DRAIN;
                        end else if(rlast)begin
                            if(stopping)rs<=R_DONE;
                            else begin read_word<=0;read_lane<=0;rs<=R_PRIME;end
                        end else r_index<=r_index+1'b1;
                    end
                    R_DRAIN:if(rvalid && rlast)rs<=R_DONE;
                    R_PRIME,R_FETCH:if(stopping)rs<=R_DONE;else rs<=R_PIXELS;
                    R_PIXELS:if(stopping)rs<=R_DONE;else if(ready0)begin
                        if(read_lane==3)begin
                            read_lane<=0;
                            if(read_word==read_beats-1)begin
                                read_cursor<=read_cursor+{23'd0,read_beats,4'd0};
                                read_remaining<=read_remaining-read_beats;
                                if(read_remaining==read_beats)rs<=R_DONE;
                                else begin
                                    read_beats<=read_remaining-read_beats>=16 ? 16 : read_remaining-read_beats;
                                    rs<=R_ADDR;
                                end
                            end else begin read_word<=read_word+1'b1;rs<=R_FETCH;end
                        end else read_lane<=read_lane+1'b1;
                    end
                    default:begin end
                endcase
                case(ws)
                    W_COLLECT:if(stopping)ws<=W_DONE;
                        else if(v2)begin
                            if(!low_x[0])first_pixel<=p2;
                            if(low_x==LOW_WIDTH-1)begin
                                low_x<=0;row_word<=0;row_repeat<=0;stage_index<=0;
                                write_beats<=ROW_WORDS>=16 ? 16 : ROW_WORDS;ws<=W_FETCH;
                            end else low_x<=low_x+1'b1;
                        end
                    W_FETCH:if(stopping)ws<=W_DONE;else ws<=W_LATCH;
                    W_LATCH:if(stopping)ws<=W_DONE;
                        else if(stage_index==write_beats-1)begin send_index<=0;ws<=W_ADDR;end
                        else begin stage_index<=stage_index+1'b1;ws<=W_FETCH;end
                    W_ADDR:if(awready)begin send_index<=0;ws<=W_DATA;end
                    W_DATA:if(wready)begin
                        write_count<=write_count+1'b1;
                        if(wlast)ws<=W_RESP;else send_index<=send_index+1'b1;
                    end
                    W_RESP:if(bvalid)begin
                        if(bresp!=0)begin error<=1;error_code<=3;ws<=W_DONE;end
                        else if(stopping)ws<=W_DONE;
                        else begin
                            write_cursor<=write_cursor+{23'd0,write_beats,4'd0};stage_index<=0;
                            if(row_word+write_beats==ROW_WORDS)begin
                                row_word<=0;write_beats<=ROW_WORDS>=16 ? 16 : ROW_WORDS;
                                if(!row_repeat)begin row_repeat<=1;ws<=W_FETCH;end
                                else if(low_y==LOW_HEIGHT-1)ws<=W_DONE;
                                else begin low_y<=low_y+1'b1;ws<=W_COLLECT;end
                            end else begin
                                row_word<=row_word+write_beats;
                                write_beats<=ROW_WORDS-row_word-write_beats>=16 ? 16 : ROW_WORDS-row_word-write_beats;
                                ws<=W_FETCH;
                            end
                        end
                    end
                    default:begin end
                endcase
                if(rs==R_DONE && ws==W_DONE)begin
                    busy<=0;last_cycles<=cycles;
                    if(!stopping && core_done==3'b111 && read_count==BEATS && write_count==BEATS)done<=1;
                    else if(!stopping)begin error<=1;error_code<=7;end
                end
            end
        end
    end
endmodule
