// One-shot, non-backpressuring RGB tap -> committed INT8 RGBA DDR frame.
// Only CPU-selected inactive pair may be written. Completion follows final B.
// Overflow/short frame/error never publishes success; all accepted AXI writes
// finish before the error token releases busy. Fixed 256-byte bursts stay in 4K.
module iris_style_capture #(
    parameter FRAME_WORDS=76800, parameter FIFO_AW=8
)(
    input wire clk, video_clk, rst_n,
    input wire request, pair,
    output reg busy, done, error,
    output wire capture_enable,
    input wire i_vs, i_valid, i_sof, i_eof,
    input wire [31:0] i_rgba,
    output reg [31:0] awaddr,
    output wire [7:0] awlen,
    output wire awvalid, input wire awready,
    output wire [127:0] wdata,
    output wire wlast, wvalid, input wire wready,
    input wire [1:0] bresp, input wire bvalid,
    output wire bready
);
reg request_toggle;
reg [2:0] request_sync;
reg enabled, saw_sof, vs_d, failed, error_token;
reg [1:0] pack_count;
reg [95:0] pack;
wire fifo_full, fifo_empty;
wire [FIFO_AW:0] fifo_level;
wire [129:0] fifo_dout;
wire pack_word = enabled && i_valid && pack_count==3;
wire fifo_push = !fifo_full && (pack_word || error_token);
wire [129:0] fifo_din = error_token ? {2'b11,128'd0} :
                                      {1'b0,i_eof,i_rgba,pack};
wire fifo_pop;
assign capture_enable=enabled;
always @(posedge video_clk or negedge rst_n) begin
    if(!rst_n)begin
        request_sync<=0;enabled<=0;saw_sof<=0;vs_d<=0;
        failed<=0;error_token<=0;pack_count<=0;pack<=0;
    end else begin
        request_sync<={request_sync[1:0],request_toggle};vs_d<=i_vs;
        if(request_sync[2]!=request_sync[1])begin
            enabled<=1;saw_sof<=0;failed<=0;error_token<=0;pack_count<=0;
        end else begin
            if(error_token && !fifo_full)error_token<=0;
            if(enabled && i_valid)begin
                if(i_sof)saw_sof<=1;
                case(pack_count)
                    0:pack[31:0]<=i_rgba;
                    1:pack[63:32]<=i_rgba;
                    2:pack[95:64]<=i_rgba;
                endcase
                pack_count<=pack_count+1'b1;
                if((pack_word && fifo_full) || (i_eof && pack_count!=3))begin
                    enabled<=0;failed<=1;error_token<=1;
                end else if(i_eof)enabled<=0;
            end
            if(enabled && i_vs && !vs_d && saw_sof)begin
                enabled<=0;failed<=1;error_token<=1;
            end
        end
    end
end
afifo_simple #(.DW(130),.AW(FIFO_AW)) u_fifo(
    .wclk(video_clk),.wrst_n(rst_n),.winc(fifo_push),.din(fifo_din),.wfull(fifo_full),
    .rclk(clk),.rrst_n(rst_n),.rinc(fifo_pop),.dout(fifo_dout),.rempty(fifo_empty),.rlevel(fifo_level)
);
reg [2:0] failure_sync;
localparam IDLE=0, WAIT_BURST=1, POP=2, GET=3, AW=4, W=5, RESP=6;
reg [2:0] state;
reg [127:0] hold_data;
reg hold_eof;
reg [3:0] beat;
reg [16:0] words;
reg bad, padding;
assign awlen=8'd15;
assign awvalid=state==AW;
assign wdata=hold_data;
assign wvalid=state==W;
assign wlast=beat==15;
assign bready=state==RESP;
assign fifo_pop=state==POP && !fifo_empty;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
        request_toggle<=0;failure_sync<=0;state<=IDLE;
        busy<=0;done<=0;error<=0;bad<=0;padding<=0;words<=0;beat<=0;
        awaddr<=0;hold_data<=0;hold_eof<=0;
    end else begin
        failure_sync<={failure_sync[1:0],failed};
        case(state)
            IDLE:if(request)begin
                request_toggle<=~request_toggle;busy<=1;done<=0;error<=0;
                bad<=0;padding<=0;words<=0;beat<=0;
                awaddr<=pair ? 32'h03200000 : 32'h03000000;
                state<=WAIT_BURST;
            end
            WAIT_BURST:if(fifo_level>=16 || (failure_sync[2] && !fifo_empty))begin
                beat<=0;state<=POP;
            end
            POP:if(!fifo_empty)state<=GET;
            GET:begin
                if(fifo_dout[129])begin
                    if(beat==0)begin busy<=0;done<=1;error<=1;state<=IDLE;end
                    else begin
                        bad<=1;padding<=1;hold_data<=0;hold_eof<=1;state<=W;
                    end
                end else begin
                    hold_data<=fifo_dout[127:0];hold_eof<=fifo_dout[128];
                    state<=beat==0 ? AW : W;
                end
            end
            AW:if(awready)state<=W;
            W:if(wready)begin
                words<=words+1'b1;
                if(hold_eof && (words!=FRAME_WORDS-1 || beat!=15))bad<=1;
                if(beat==15)state<=RESP;
                else begin
                    beat<=beat+1'b1;
                    if(padding || hold_eof)begin
                        bad<=1;padding<=1;hold_data<=0;hold_eof<=1;state<=W;
                    end else state<=POP;
                end
            end
            RESP:if(bvalid)begin
                if(bresp!=0)bad<=1;
                if(hold_eof)begin
                    busy<=0;done<=1;error<=bad || bresp!=0 || words!=FRAME_WORDS;
                    state<=IDLE;
                end else begin awaddr<=awaddr+32'd256;state<=WAIT_BURST;end
            end
        endcase
    end
end
endmodule
