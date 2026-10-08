// Iris custom instruction ABI v1: INT8 NHWC nearest-neighbour 2x DMA.
// Command 0x208 additionally copies an unchanged tensor through AXI DMA.
// One outstanding AXI transaction, 128-bit aligned full beats. Channels are
// 4/8/16/32; each input row must contain an integral number of 16-byte beats.
// Byte values are copied unchanged. Completion follows the final write B.
module iris_resize2x (
    input wire clk, input wire rst_n,
    input wire vendor_idle,
    input wire cmd_valid, input wire [9:0] cmd_function_id,
    input wire [31:0] cmd_inputs_0, cmd_inputs_1,
    output wire cmd_ready,
    output reg rsp_valid, output reg [31:0] rsp_outputs_0,
    input wire rsp_ready,
    output wire busy,
    output wire [31:0] araddr, output wire arvalid, input wire arready,
    input wire [127:0] rdata, input wire rvalid, output wire rready,
    input wire rlast, input wire [1:0] rresp,
    output wire [31:0] awaddr, output wire awvalid, input wire awready,
    output wire [127:0] wdata, output wire wvalid, input wire wready,
    input wire bvalid, output wire bready, input wire [1:0] bresp
);
    localparam IDLE=0, LOOKUP=1, READ_ADDR=2, READ_DATA=3,
               WRITE_ADDR=4, WRITE_DATA=5, WRITE_RESP=6,
               CHECK_ROW=7, CHECK_BYTES=8, CHECK_RANGES=9, CHECK_VALID=10, PUBLISH=11;
    reg [3:0] state;
    reg [31:0] src_base, dst_base, height, width, channels;
    reg [31:0] row_bytes, source_row, output_offset, dst_cursor;
    reg [31:0] output_row;
    reg [127:0] cached_data;
    reg [31:0] cached_addr, requested_addr;
    reg cache_valid, done, error, abort_pending, copy_mode, stream_mode;
    reg [31:0] bad_dummy_lanes;
    reg [7:0] error_code;
    // The only supported channel counts are powers of two. Bound arithmetic
    // widths and register each validation stage instead of placing three
    // 32-bit multipliers and range adders on the command-to-state path.
    wire [15:0] cfg_row_bytes = channels==4 ? {width[10:0],2'b0} :
        channels==8 ? {width[10:0],3'b0} : channels==16 ? {width[10:0],4'b0} :
        {width[10:0],5'b0};
    reg [26:0] cfg_input_bytes;
    reg [32:0] src_end, dst_end;
    wire cfg_valid = height != 0 && height <= 1024 && width != 0 && width <= 1024 &&
        (channels==4 || channels==8 || channels==16 || channels==32) &&
        src_base[3:0]==0 && dst_base[3:0]==0 && cfg_row_bytes[3:0]==0;
    wire ranges_valid =
        src_end <= 33'h010000000 && dst_end <= 33'h010000000 &&
        (src_end <= {1'b0,dst_base} || dst_end <= {1'b0,src_base});

    assign busy = state != IDLE;
    wire checking = state>=CHECK_ROW && state<=CHECK_VALID;
    assign cmd_ready = (!rsp_valid || rsp_ready) && !checking;
    wire cmd_fire = cmd_valid && cmd_ready;
    wire abort_now = cmd_fire && cmd_function_id==10'h206;
    wire stopping = abort_pending || abort_now;

    // Address of the source bytes needed by this output beat. 32-channel
    // pixels take two beats; smaller pixels duplicate whole channel groups.
    wire [31:0] source_offset = copy_mode ? output_offset : channels==32 ?
        ((output_offset & 32'hffffffc0) >> 1) + (output_offset & 32'h10) :
        channels==16 ? (output_offset >> 5) << 4 : output_offset >> 1;
    wire [31:0] source_addr = source_row + source_offset;
    wire [31:0] source_aligned = source_addr & 32'hfffffff0;
    reg [127:0] expanded;
    always @* begin
        expanded = cached_data;
        // Fixed wiring avoids sixteen dynamically indexed byte selectors.
        // The two cases select pixels 0/1 or 2/3, then duplicate each pixel.
        if (!copy_mode && channels==4)
            expanded = source_addr[3] ?
                {cached_data[127:96],cached_data[127:96],cached_data[95:64],cached_data[95:64]} :
                {cached_data[63:32],cached_data[63:32],cached_data[31:0],cached_data[31:0]};
        else if (!copy_mode && channels==8)
            expanded = source_addr[3] ? {cached_data[127:64],cached_data[127:64]} :
                                       {cached_data[63:0],cached_data[63:0]};
    end
    assign araddr = requested_addr;
    assign arvalid = state==READ_ADDR;
    assign rready = state==READ_DATA;
    assign awaddr = dst_cursor;
    assign awvalid = state==WRITE_ADDR;
    assign wdata = expanded;
    assign wvalid = state==WRITE_DATA;
    assign bready = state==WRITE_RESP;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; rsp_valid<=0; rsp_outputs_0<=0;
            src_base<=0; dst_base<=0; height<=0; width<=0; channels<=0;
            row_bytes<=0; source_row<=0; output_offset<=0; dst_cursor<=0;
            output_row<=0; cached_data<=0; cached_addr<=0; requested_addr<=0;
            cache_valid<=0; done<=0; error<=0; error_code<=0; abort_pending<=0;
            cfg_input_bytes<=0; src_end<=0; dst_end<=0; copy_mode<=0;stream_mode<=0;bad_dummy_lanes<=0;
        end else begin
            if (rsp_valid && rsp_ready) rsp_valid<=0;
            if (cmd_fire) begin
                rsp_valid<=1;
                rsp_outputs_0<=0;
                case (cmd_function_id)
                    10'h200: rsp_outputs_0<=32'h49520101;
                    10'h201: if (busy) rsp_outputs_0<=32'hfffffffe;
                        else begin src_base<=cmd_inputs_0; dst_base<=cmd_inputs_1; end
                    10'h202: if (busy) rsp_outputs_0<=32'hfffffffe;
                        else begin height<=cmd_inputs_0; width<=cmd_inputs_1; end
                    10'h203: if (busy) rsp_outputs_0<=32'hfffffffe;
                        else channels<=cmd_inputs_0;
                    10'h204,10'h208,10'h20f: begin
                        if (busy || !vendor_idle) rsp_outputs_0<=32'hfffffffe;
                        else if (!cfg_valid) begin
                            rsp_outputs_0<=32'hffffffff; done<=0; error<=1; error_code<=1;
                        end else begin
                            // CI waits for the validation response, so Start
                            // retains its rejection contract without software
                            // depending on a fixed number of validation cycles.
                            rsp_valid<=0;
                            cache_valid<=0; done<=0; error<=0; error_code<=0;
                            abort_pending<=0; copy_mode<=cmd_function_id!=10'h204;stream_mode<=cmd_function_id==10'h20f;bad_dummy_lanes<=0;state<=CHECK_ROW;
                        end
                    end
                    10'h205: rsp_outputs_0<={16'b0,error_code,4'b0,state==PUBLISH,error,done,busy};
                    10'h209: rsp_outputs_0<=bad_dummy_lanes;
                    10'h20a: rsp_outputs_0<=cached_data[31:0];
                    10'h20b: rsp_outputs_0<=cached_data[63:32];
                    10'h20c: rsp_outputs_0<=cached_data[95:64];
                    10'h20d: rsp_outputs_0<=cached_data[127:96];
                    10'h20e: if(state!=PUBLISH)rsp_outputs_0<=32'hffffffff;
                    10'h206: begin
                        // Accept abort immediately, drain any published AXI
                        // address/data/response before declaring memory reusable.
                        if (busy) begin abort_pending<=1; error<=1; error_code<=4; end
                        else begin done<=0; error<=0; error_code<=0; cache_valid<=0; end
                    end
                    default: rsp_outputs_0<=32'hffffffff;
                endcase
            end
            case (state)
                CHECK_ROW: begin row_bytes<=cfg_row_bytes; state<=CHECK_BYTES; end
                CHECK_BYTES: begin cfg_input_bytes<=height[10:0]*row_bytes[15:0]; state<=CHECK_RANGES; end
                CHECK_RANGES: begin
                    src_end<={1'b0,src_base}+{6'b0,cfg_input_bytes};
                    dst_end<={1'b0,dst_base}+(copy_mode ? {6'b0,cfg_input_bytes} : ({6'b0,cfg_input_bytes}<<2));
                    state<=CHECK_VALID;
                end
                CHECK_VALID: begin
                    rsp_valid<=1;
                    if (!ranges_valid) begin
                        rsp_outputs_0<=32'hffffffff; done<=0; error<=1; error_code<=1; state<=IDLE;
                    end else begin
                        rsp_outputs_0<=0; source_row<=src_base;
                        output_offset<=0; output_row<=0; dst_cursor<=dst_base; state<=LOOKUP;
                    end
                end
                LOOKUP: begin
                    if (stopping) begin state<=IDLE; done<=0; end
                    else if (cache_valid && cached_addr==source_aligned) state<=stream_mode ? PUBLISH : WRITE_ADDR;
                    else begin requested_addr<=source_aligned; state<=READ_ADDR; end
                end
                READ_ADDR: if (arready) state<=READ_DATA;
                READ_DATA: if (rvalid) begin
                    if(copy_mode && rresp==0)bad_dummy_lanes<=bad_dummy_lanes+
                        {31'd0,rdata[31:24]!=8'h80}+{31'd0,rdata[63:56]!=8'h80}+
                        {31'd0,rdata[95:88]!=8'h80}+{31'd0,rdata[127:120]!=8'h80};
                    if (rresp!=0 || !rlast) begin error<=1; error_code<=2; end
                    // Drain a malformed multi-beat response through RLAST.
                    if (rlast) begin
                        if (rresp!=0 || error || stopping) begin state<=IDLE; done<=0; end
                        else begin cached_data<=rdata; cached_addr<=requested_addr;
                            cache_valid<=1; state<=LOOKUP; end
                    end
                end
                PUBLISH: begin
                    if(stopping)begin state<=IDLE;done<=0;end
                    else if(cmd_fire && cmd_function_id==10'h20e)begin
                        if(output_offset+16==row_bytes)begin
                            if(output_row+1==height)begin state<=IDLE;done<=1;end
                            else begin output_row<=output_row+1;output_offset<=0;
                                source_row<=source_row+row_bytes;state<=LOOKUP;end
                        end else begin output_offset<=output_offset+16;state<=LOOKUP;end
                    end
                end
                WRITE_ADDR: if (awready) state<=WRITE_DATA;
                WRITE_DATA: if (wready) state<=WRITE_RESP;
                WRITE_RESP: if (bvalid) begin
                    if (bresp!=0) begin error<=1; error_code<=3; state<=IDLE; done<=0; end
                    else if (stopping) begin state<=IDLE; done<=0; end
                    else if (output_offset+16 == (copy_mode ? row_bytes : row_bytes*2)) begin
                        if (output_row+1 == (copy_mode ? height : height*2)) begin state<=IDLE; done<=1; end
                        else begin
                            output_row<=output_row+1; output_offset<=0;
                            dst_cursor<=dst_cursor+16;
                            if (copy_mode || output_row[0]) source_row<=source_row+row_bytes;
                            state<=LOOKUP;
                        end
                    end else begin
                        output_offset<=output_offset+16; dst_cursor<=dst_cursor+16;
                        state<=LOOKUP;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule
