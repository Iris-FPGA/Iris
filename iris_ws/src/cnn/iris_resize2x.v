// Iris custom instruction ABI v1: INT8 NHWC nearest-neighbour 2x DMA.
// Command 0x208 additionally copies an unchanged tensor through AXI DMA.
// One outstanding AXI transaction, 128-bit aligned full beats. Channels are
// 4/8/16/32 for resize; C3 is also supported for unchanged copy/stream.
// Each input row must contain an integral number of 16-byte beats.
// Byte values are copied unchanged. Completion follows the final write B.
module iris_resize2x #(parameter BURST_DMA=0,RGB_MODEL_ONLY=0,CHUNK_BEATS=2) (
    input wire clk, input wire rst_n,
    input wire vendor_idle,
    input wire cmd_valid, input wire [9:0] cmd_function_id,
    input wire [31:0] cmd_inputs_0, cmd_inputs_1,
    output wire cmd_ready,
    output reg rsp_valid, output reg [31:0] rsp_outputs_0,
    input wire rsp_ready,
    output wire busy,
    output wire [31:0] araddr, output wire [7:0] arlen,
    output wire arvalid, input wire arready,
    input wire [127:0] rdata, input wire rvalid, output wire rready,
    input wire rlast, input wire [1:0] rresp,
    output wire [31:0] awaddr, output wire [7:0] awlen,
    output wire awvalid, input wire awready,
    output wire [127:0] wdata, output wire wvalid, output wire wlast, input wire wready,
    input wire bvalid, output wire bready, input wire [1:0] bresp
);
    localparam IDLE=0, LOOKUP=1, READ_ADDR=2, READ_DATA=3,
               WRITE_ADDR=4, WRITE_DATA=5, WRITE_RESP=6,
               CHECK_ROW=7, CHECK_BYTES=8, CHECK_RANGES=9, CHECK_VALID=10, PUBLISH=11,
               BURST_WAIT=12;
    reg [3:0] state;
    reg [31:0] src_base,dst_base;
    reg [10:0] height,width;
    reg [5:0] channels;
    reg dimensions_valid,channels_valid;
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
    wire [15:0] cfg_row_bytes = channels==3 ? ({5'd0,width[10:0]}<<1)+{5'd0,width[10:0]} : !RGB_MODEL_ONLY && channels==4 ? {width[10:0],2'b0} :
        !RGB_MODEL_ONLY && channels==8 ? {width[10:0],3'b0} : channels==16 ? {width[10:0],4'b0} :
        {width[10:0],5'b0};
    reg [26:0] cfg_input_bytes;
    reg [32:0] src_end, dst_end;
    wire cfg_valid = dimensions_valid && channels_valid &&
        ((!RGB_MODEL_ONLY && (channels==4 || channels==8)) || channels==16 || channels==32 ||
         (channels==3 && cmd_function_id!=10'h204)) &&
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
        if (!RGB_MODEL_ONLY && !copy_mode && channels==4)
            expanded = source_addr[3] ?
                {cached_data[127:96],cached_data[127:96],cached_data[95:64],cached_data[95:64]} :
                {cached_data[63:32],cached_data[63:32],cached_data[31:0],cached_data[31:0]};
        else if (!RGB_MODEL_ONLY && !copy_mode && channels==8)
            expanded = source_addr[3] ? {cached_data[127:64],cached_data[127:64]} :
                                       {cached_data[63:0],cached_data[63:0]};
    end
    wire fast_owner=BURST_DMA && state==BURST_WAIT;
    wire fast_start=BURST_DMA && state==CHECK_VALID && ranges_valid;
    wire [31:0] fast_araddr,fast_awaddr,fast_audit;
    wire [7:0] fast_arlen,fast_awlen,fast_error;
    wire [127:0] fast_wdata,fast_stream_data;
    wire fast_stream_ready;
    wire fast_arvalid,fast_rready,fast_awvalid,fast_wvalid,fast_wlast,fast_bready,fast_finished;
    assign araddr = BURST_DMA ? fast_araddr : requested_addr;
    assign arlen = BURST_DMA ? fast_arlen : 8'd0;
    assign arvalid = BURST_DMA ? fast_arvalid && fast_owner : state==READ_ADDR;
    assign rready = BURST_DMA ? fast_rready && fast_owner : state==READ_DATA;
    assign awaddr = BURST_DMA ? fast_awaddr : dst_cursor;
    assign awlen = BURST_DMA ? fast_awlen : 8'd0;
    assign awvalid = BURST_DMA ? fast_awvalid && fast_owner : state==WRITE_ADDR;
    assign wdata = BURST_DMA ? fast_wdata : expanded;
    assign wvalid = BURST_DMA ? fast_wvalid && fast_owner : state==WRITE_DATA;
    assign wlast = BURST_DMA ? fast_wlast : 1'b1;
    assign bready = BURST_DMA ? fast_bready && fast_owner : state==WRITE_RESP;
    generate if(BURST_DMA)begin:g_burst
        iris_tensor_burst #(.RGB_MODEL_ONLY(RGB_MODEL_ONLY),.CHUNK_BEATS(CHUNK_BEATS)) u_burst(
            .clk(clk),.rst_n(rst_n),.start(fast_start),.abort(stopping),
            .src(src_base),.dst(dst_base),.rows(height[10:0]),.row_bytes(row_bytes[15:0]),
            .channels(channels[5:0]),.copy_mode(copy_mode),.stream_mode(stream_mode),
            .stream_ready(fast_stream_ready),.stream_data(fast_stream_data),
            .stream_ack(cmd_fire && cmd_function_id==10'h20e),
            .finished(fast_finished),.error_code(fast_error),.dummy_audit(fast_audit),
            .araddr(fast_araddr),.arlen(fast_arlen),.arvalid(fast_arvalid),.arready(arready && fast_owner),
            .rdata(rdata),.rvalid(rvalid && fast_owner),.rready(fast_rready),.rlast(rlast),.rresp(rresp),
            .awaddr(fast_awaddr),.awlen(fast_awlen),.awvalid(fast_awvalid),.awready(awready && fast_owner),
            .wdata(fast_wdata),.wvalid(fast_wvalid),.wlast(fast_wlast),.wready(wready && fast_owner),
            .bvalid(bvalid && fast_owner),.bready(fast_bready),.bresp(bresp));
    end else begin:g_scalar
        assign fast_araddr=0;assign fast_arlen=0;assign fast_arvalid=0;assign fast_rready=0;
        assign fast_awaddr=0;assign fast_awlen=0;assign fast_awvalid=0;
        assign fast_wdata=0;assign fast_wvalid=0;assign fast_wlast=0;assign fast_bready=0;
        assign fast_finished=0;assign fast_error=0;assign fast_audit=0;
        assign fast_stream_ready=0;assign fast_stream_data=0;
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; rsp_valid<=0; rsp_outputs_0<=0;
            src_base<=0; dst_base<=0; height<=0; width<=0; channels<=0;
            dimensions_valid<=0;channels_valid<=0;
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
                        else begin
                            height<=cmd_inputs_0[10:0];width<=cmd_inputs_1[10:0];
                            dimensions_valid<=cmd_inputs_0!=0 && cmd_inputs_0<=1024 &&
                                              cmd_inputs_1!=0 && cmd_inputs_1<=1024;
                        end
                    10'h203: if (busy) rsp_outputs_0<=32'hfffffffe;
                        else begin
                            channels<=cmd_inputs_0[5:0];
                            channels_valid<=cmd_inputs_0==3 || (!RGB_MODEL_ONLY && (cmd_inputs_0==4 || cmd_inputs_0==8)) ||
                                            cmd_inputs_0==16 || cmd_inputs_0==32;
                        end
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
                    10'h205: rsp_outputs_0<={16'b0,error_code,4'b0,
                        BURST_DMA ? fast_stream_ready : state==PUBLISH,error,done,busy};
                    10'h209: rsp_outputs_0<=BURST_DMA ? fast_audit : bad_dummy_lanes;
                    10'h20a: rsp_outputs_0<=BURST_DMA ? fast_stream_data[31:0] : cached_data[31:0];
                    10'h20b: rsp_outputs_0<=BURST_DMA ? fast_stream_data[63:32] : cached_data[63:32];
                    10'h20c: rsp_outputs_0<=BURST_DMA ? fast_stream_data[95:64] : cached_data[95:64];
                    10'h20d: rsp_outputs_0<=BURST_DMA ? fast_stream_data[127:96] : cached_data[127:96];
                    10'h20e: if(BURST_DMA ? !fast_stream_ready : state!=PUBLISH)rsp_outputs_0<=32'hffffffff;
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
                            output_offset<=0; output_row<=0; dst_cursor<=dst_base;
                            state<=BURST_DMA ? BURST_WAIT : LOOKUP;
                    end
                end
                BURST_WAIT: if(fast_finished)begin
                    state<=IDLE;done<=fast_error==0 && !stopping;
                    bad_dummy_lanes<=fast_audit;
                    if(fast_error!=0)begin error<=1;error_code<=fast_error;end
                end
                LOOKUP: if(!BURST_DMA)begin
                    if (stopping) begin state<=IDLE; done<=0; end
                    else if (cache_valid && cached_addr==source_aligned) state<=stream_mode ? PUBLISH : WRITE_ADDR;
                    else begin requested_addr<=source_aligned; state<=READ_ADDR; end
                end
                READ_ADDR: if (!BURST_DMA && arready) state<=READ_DATA;
                READ_DATA: if (!BURST_DMA && rvalid) begin
                    if(!RGB_MODEL_ONLY && copy_mode && channels==4 && rresp==0)bad_dummy_lanes<=bad_dummy_lanes+
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
                PUBLISH: if(!BURST_DMA)begin
                    if(stopping)begin state<=IDLE;done<=0;end
                    else if(cmd_fire && cmd_function_id==10'h20e)begin
                        if(output_offset+16==row_bytes)begin
                            if(output_row+1==height)begin state<=IDLE;done<=1;end
                            else begin output_row<=output_row+1;output_offset<=0;
                                source_row<=source_row+row_bytes;state<=LOOKUP;end
                        end else begin output_offset<=output_offset+16;state<=LOOKUP;end
                    end
                end
                WRITE_ADDR: if (!BURST_DMA && awready) state<=WRITE_DATA;
                WRITE_DATA: if (!BURST_DMA && wready) state<=WRITE_RESP;
                WRITE_RESP: if (!BURST_DMA && bvalid) begin
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

// Two input beats are reused for both nearest-neighbour output rows. The
// small explicit register bank adds no RAM10 blocks. Every AXI burst stays
// within a 4 KiB page; abort/error drains the transaction already published.
// The caller validates shape, the 256 MiB DDR window and non-overlap before
// start, allowing the internal address counters to use only 28 bits.
module iris_tensor_burst #(parameter RGB_MODEL_ONLY=0,CHUNK_BEATS=2) (
    input wire clk,rst_n,start,abort,
    input wire [31:0] src,dst,
    input wire [10:0] rows,
    input wire [15:0] row_bytes,
    input wire [5:0] channels,
    input wire copy_mode,stream_mode,stream_ack,
    output wire stream_ready,
    output wire [127:0] stream_data,
    output reg finished,
    output reg [7:0] error_code,
    output wire [31:0] dummy_audit,
    output wire [31:0] araddr,awaddr,
    output wire [7:0] arlen,awlen,
    output wire arvalid,awvalid,wvalid,wlast,rready,bready,
    input wire arready,awready,wready,rvalid,rlast,bvalid,
    input wire [127:0] rdata,
    input wire [1:0] rresp,bresp,
    output wire [127:0] wdata
);
    localparam IDLE=0,CHUNK=1,AR=2,R=3,SET_WRITE=4,AW=5,W=7,B=8,PUBLISH=9,ADVANCE=10;
    localparam IA=$clog2(CHUNK_BEATS);
    reg [3:0] state;
    reg [27:0] source_cursor,top_cursor,write_address;
    reg [20:0] audit_count;
    assign dummy_audit={11'd0,audit_count};
    reg [10:0] row;
    reg [15:0] remaining;
    reg [IA:0] input_beats,read_index,read_end;
    reg [7:0] read_length;
    reg [IA+1:0] output_index,segment_end;
    reg [7:0] write_length;
    reg bottom;
    (* syn_ramstyle="registers" *) reg [127:0] buffer_data[0:CHUNK_BEATS-1];
    // A C32 pixel must remain whole in the reuse bank. Split its AXI read
    // when necessary, while retaining both halves in the same chunk.
    wire [11:0] row_beats=remaining[15:4];
    wire [IA:0] next_input_beats=row_beats>=CHUNK_BEATS ? CHUNK_BEATS : row_beats[IA:0];
    wire [8:0] read_page_beats=9'd256-{1'b0,source_cursor[11:4]};
    wire [IA:0] first_read_beats=read_page_beats<next_input_beats ? read_page_beats[IA:0] : next_input_beats;
    wire [IA+1:0] output_beats=copy_mode ? {1'b0,input_beats} : {input_beats,1'b0};
    wire [31:0] output_row_bytes={16'd0,row_bytes}<<1;
    wire [27:0] current_write_address=top_cursor+(bottom ? output_row_bytes[27:0] : 28'd0)+
        ({{(26-IA){1'b0}},output_index}<<4);
    wire [8:0] write_page_beats=9'd256-{1'b0,current_write_address[11:4]};
    wire [IA+1:0] output_remaining=output_beats-output_index;
    wire [IA+1:0] next_write_beats=write_page_beats>=output_remaining ?
        output_remaining : write_page_beats;
    wire [IA+4:0] chunk_bytes={input_beats,4'b0};
    wire [IA+5:0] output_chunk_bytes=copy_mode ? {1'b0,chunk_bytes} : {chunk_bytes,1'b0};
    wire [IA+1:0] next_output=output_index+1'b1;
    wire [IA-1:0] selected_buffer=stream_mode || copy_mode ? output_index[IA-1:0] :
        channels==32 ? ((output_index>>2)<<1)|output_index[0] : output_index>>1;
    reg [127:0] read_q;
    always @* begin
        read_q=buffer_data[selected_buffer];
    end
    assign stream_data=read_q;
    assign stream_ready=state==PUBLISH;
    reg [127:0] expanded;
    always @* begin
        expanded=read_q;
        if(!RGB_MODEL_ONLY && !copy_mode && channels==4)
            expanded=output_index[0] ?
                {read_q[127:96],read_q[127:96],read_q[95:64],read_q[95:64]} :
                {read_q[63:32],read_q[63:32],read_q[31:0],read_q[31:0]};
        else if(!RGB_MODEL_ONLY && !copy_mode && channels==8)
            expanded=output_index[0] ? {read_q[127:64],read_q[127:64]} :
                                      {read_q[63:0],read_q[63:0]};
    end
    assign araddr={4'd0,source_cursor}+({{(31-IA){1'b0}},read_index}<<4);
    assign arlen=read_length;
    assign arvalid=state==AR;
    assign rready=state==R;
    assign awaddr={4'd0,write_address};
    assign awlen=write_length;
    assign awvalid=state==AW;
    assign wdata=expanded;
    assign wvalid=state==W;
    assign wlast=next_output==segment_end;
    assign bready=state==B;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;finished<=0;error_code<=0;audit_count<=0;
            source_cursor<=0;top_cursor<=0;write_address<=0;row<=0;remaining<=0;
            input_beats<=0;read_index<=0;read_end<=0;read_length<=0;output_index<=0;segment_end<=0;
            write_length<=0;bottom<=0;
        end else begin
            finished<=0;
            if(abort && state!=IDLE && error_code==0)error_code<=4;
            case(state)
                IDLE:if(start)begin
                    source_cursor<=src[27:0];top_cursor<=dst[27:0];row<=0;remaining<=row_bytes;
                    error_code<=0;audit_count<=0;state<=CHUNK;
                end
                CHUNK:if(abort || error_code!=0)begin state<=IDLE;finished<=1;end
                    else begin
                        input_beats<=next_input_beats;read_index<=0;
                        read_end<=first_read_beats;read_length<=first_read_beats-1'b1;state<=AR;
                    end
                AR:if(arready)state<=R;
                R:if(rvalid)begin
                    // A short/long response is an error even when RRESP is OK.
                    // Long responses are drained to RLAST before releasing DDR.
                    if(rresp!=0 || rlast!=(read_index==read_end-1'b1))error_code<=2;
                    if(read_index<CHUNK_BEATS)buffer_data[read_index[IA-1:0]]<=rdata;
                    if(!RGB_MODEL_ONLY && copy_mode && channels==4 && rresp==0)
                        audit_count<=audit_count+{20'd0,rdata[31:24]!=8'h80}+
                            {20'd0,rdata[63:56]!=8'h80}+{20'd0,rdata[95:88]!=8'h80}+
                            {20'd0,rdata[127:120]!=8'h80};
                    if(rlast)begin
                        if(rresp!=0 || read_index!=read_end-1'b1 || error_code!=0 || abort)begin
                            state<=IDLE;finished<=1;
                        end else if(read_end<input_beats)begin
                            read_length<=input_beats-read_end-1'b1;
                            read_end<=input_beats;read_index<=read_index+1'b1;state<=AR;
                        end else begin
                            bottom<=0;output_index<=0;state<=stream_mode ? PUBLISH : SET_WRITE;
                        end
                    end else if(read_index<CHUNK_BEATS)read_index<=read_index+1'b1;
                end
                SET_WRITE:if(abort || error_code!=0)begin state<=IDLE;finished<=1;end
                    else begin
                        write_address<=current_write_address;write_length<=next_write_beats-1'b1;
                        segment_end<=output_index+next_write_beats;state<=AW;
                    end
                AW:if(awready)state<=W;
                W:if(wready)begin
                    output_index<=next_output;
                    if(wlast)state<=B;
                end
                B:if(bvalid)begin
                    if(bresp!=0 || error_code!=0 || abort)begin
                        if(bresp!=0)error_code<=3;
                        state<=IDLE;finished<=1;
                    end else if(output_index<output_beats)state<=SET_WRITE;
                    else if(!copy_mode && !bottom)begin bottom<=1;output_index<=0;state<=SET_WRITE;end
                    else state<=ADVANCE;
                end
                PUBLISH:if(abort || error_code!=0)begin state<=IDLE;finished<=1;end
                    else if(stream_ack)begin
                        if(next_output==output_beats)state<=ADVANCE;
                        else output_index<=next_output;
                    end
                ADVANCE:begin
                    if(abort || error_code!=0)begin state<=IDLE;finished<=1;end
                    else begin
                        source_cursor<=source_cursor+chunk_bytes;
                        top_cursor<=top_cursor+output_chunk_bytes;
                        if(remaining==chunk_bytes)begin
                            if(row+1'b1==rows)begin state<=IDLE;finished<=1;end
                            else begin
                                row<=row+1'b1;remaining<=row_bytes;
                                if(!copy_mode)top_cursor<=top_cursor+output_chunk_bytes+output_row_bytes;
                                state<=CHUNK;
                            end
                        end else begin remaining<=remaining-chunk_bytes;state<=CHUNK;end
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
