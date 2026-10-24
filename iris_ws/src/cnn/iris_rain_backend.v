// Optional complete-model Conv/Add backend. The CPU configures operators;
// every activation byte is read, computed and written by hardware. AXI bursts
// are staged in full, never cross 4 KiB and retain ownership through RLAST/B.
// CI 0x260..267: capability, addresses, configuration, Conv parameters, start
// (rs1 0=Conv/1=Add), status, abort, elapsed clocks.
module iris_rain_backend(
    input wire clk,rst_n,vendor_idle,
    input wire cmd_valid,input wire [9:0] cmd_function_id,
    input wire [31:0] cmd_inputs_0,cmd_inputs_1,output wire cmd_ready,
    output reg rsp_valid,output reg [31:0] rsp_outputs_0,input wire rsp_ready,
    output reg busy,output wire irq,
    output reg [31:0] araddr,output reg [7:0] arlen,output reg arvalid,input wire arready,
    input wire [127:0] rdata,input wire rvalid,output wire rready,input wire rlast,input wire [1:0] rresp,
    output reg [31:0] awaddr,output reg [7:0] awlen,output reg awvalid,input wire awready,
    output wire [127:0] wdata,output wire wvalid,wlast,input wire wready,
    input wire bvalid,output wire bready,input wire [1:0] bresp
);
    localparam IDLE=0,WEIGHTS=1,CONV=2,ADD_A=3,ADD_B=4,ADD_RUN=5,ADD_WRITE=6;
    localparam R_IDLE=0,R_ADDRESS=1,R_DATA=2,R_FEED=3,R_LOAD=4;
    localparam W_IDLE=0,W_ADDRESS=1,W_READ=2,W_DATA=3,W_RESPONSE=4;
    reg [2:0] phase,read_state,write_state;
    reg [31:0] cfg[0:21];
    reg [21:0] config_loaded;
    reg [95:0] params_loaded;
    reg [63:0] params_good;
    reg [31:0] source,destination;
    reg done,failed,aborting;
    reg [31:0] elapsed;
    reg [27:0] read_next,write_next;
    reg [19:0] read_remaining;
    reg [9:0] weight_index;
    reg [4:0] read_beat,read_beats,feed_beat;
    reg [127:0] input_burst[0:15];
    reg [127:0] add_a[0:15];
    reg [127:0] input_burst_q,add_a_q;
    reg [191:0] input_queue;
    reg [4:0] input_count;
    wire [3:0] input_step=cfg[2]==3 ? 3 : 8;
    wire conv_i_valid=busy && phase==CONV && input_count>=input_step && !failed;
    wire conv_i_ready,conv_o_valid,conv_row_done,conv_done;
    wire [63:0] conv_i_data=cfg[2]==3 ? {40'd0,input_queue[23:0]} : input_queue[63:0];
    wire [63:0] conv_o_data;
    wire [31:0] conv_cycles;
    reg conv_start,conv_abort,row_ack;
    wire parameter_write=cmd_valid && cmd_ready && cmd_function_id==10'h263 && !busy && cmd_inputs_0<96;
    wire weight_write=read_state==R_DATA && rvalid && rready && phase==WEIGHTS && !failed && rresp==0;
    iris_rain_conv u_conv(
        .clk(clk),.rst_n(rst_n),.start(conv_start),.abort(conv_abort),
        .width(cfg[0][7:0]),.height(cfg[1][7:0]),
        .input_channels(cfg[2][5:0]),.output_channels(cfg[3][5:0]),.stride2(cfg[4]==2),
        .input_zero(cfg[7][7:0]),.output_zero(cfg[7][15:8]),
        .activation_min(cfg[7][23:16]),.activation_max(cfg[7][31:24]),
        .weight_valid(weight_write),.weight_index(weight_index),.weight_data(rdata),
        .parameter_valid(parameter_write),.parameter_index(cmd_inputs_0[6:0]),.parameter_data(cmd_inputs_1),
        .i_valid(conv_i_valid),.i_data(conv_i_data),.i_ready(conv_i_ready),
        .o_valid(conv_o_valid),.o_data(conv_o_data),.row_done(conv_row_done),.row_ack(row_ack),
        .done(conv_done),.cycles(conv_cycles));
    wire input_fire=conv_i_valid && conv_i_ready;
    reg [191:0] output_pack;
    reg [4:0] output_count;
    reg [8:0] output_words;
    reg [7:0] output_row;
    reg output_bank,write_bank;
    // Use the existing 4 KiB row RAM as two 2 KiB banks whenever a row
    // fits. Rain Princess rows are at most 1 KiB. The next row can compute
    // while AXI drains the previous bank; wider rows retain serial mode.
    wire row_overlap=(({8'd0,cfg[0][7:0]}>>(cfg[4]==2))*cfg[3][5:0])<=2048;
    wire [3:0] output_step=cfg[3]==3 ? 3 : 8;
    wire [191:0] appended=output_pack|({128'd0,conv_o_data}<<(output_count*8));
    reg [127:0] output_ram[0:255];
    reg [127:0] write_data;
    reg [8:0] write_word;
    reg [4:0] write_beat,write_beats;
    reg [8:0] row_write_words;
    reg [8:0] add_input_index,add_output_index;
    reg [19:0] add_processed;
    reg [4:0] add_beats;
    wire [8:0] add_chunk_bytes={add_beats,4'd0};
    wire add_i_request=busy && phase==ADD_RUN && add_input_index<add_chunk_bytes && !failed;
    reg add_i_valid;
    reg [1:0] add_dword;
    wire [3:0] add_o_valid;
    wire [31:0] add_o_value;
    wire [3:0] input_burst_address=phase==CONV ? feed_beat[3:0] : add_input_index[7:4];
    // One synchronous read port per staging RAM; four Add lanes consume a
    // dword per cycle while the complete AXI burst remains buffered.
    always @(posedge clk)begin
        if(read_state==R_DATA && rvalid && phase!=WEIGHTS)begin
            if(phase==ADD_A)add_a[read_beat[3:0]]<=rdata;
            else input_burst[read_beat[3:0]]<=rdata;
        end
        input_burst_q<=input_burst[input_burst_address];
        add_a_q<=add_a[add_input_index[7:4]];
    end
    generate for(genvar lane=0;lane<4;lane=lane+1)begin:g_add
        iris_rain_add u_add(.clk(clk),.rst_n(rst_n && !conv_abort),.i_valid(add_i_valid),
            .i_a(add_a_q[add_dword*32+lane*8+:8]),.i_b(input_burst_q[add_dword*32+lane*8+:8]),
            .offset_a(cfg[10]),.offset_b(cfg[11]),.offset_out(cfg[12]),
            .mult_a(cfg[13]),.shift_a(cfg[14][7:0]),.mult_b(cfg[15]),.shift_b(cfg[16][7:0]),
            .mult_out(cfg[17]),.shift_out(cfg[18][7:0]),.left_shift(cfg[19][4:0]),
            .activation_min(cfg[20][7:0]),.activation_max(cfg[21][7:0]),
            .o_valid(add_o_valid[lane]),.o_value(add_o_value[lane*8+:8]));
    end endgenerate
    reg [127:0] add_pack;
    wire conv_pack_write=conv_o_valid && busy && !failed && output_count+output_step>=16;
    wire add_pack_write=add_o_valid[0] && busy && !failed && add_output_index[3:0]==12;
    wire [7:0] output_write_address=conv_pack_write ?
        (row_overlap ? {output_bank,output_words[6:0]} : output_words[7:0]) : {4'd0,add_output_index[7:4]};
    wire [127:0] output_write_data=conv_pack_write ? appended[127:0] : {add_o_value,add_pack[95:0]};
    wire [8:0] output_read_address=write_state==W_READ ? write_word : write_word+1'b1;
    wire [7:0] output_read_bank_address=phase==CONV && row_overlap ?
        {write_bank,output_read_address[6:0]} : output_read_address[7:0];
    // A single synchronous read address and one write port are required for
    // RAM inference. Conditional reads in two controller branches otherwise
    // expanded this 32 Kibit row buffer into flip-flops and LUT multiplexers.
    always @(posedge clk)begin
        if(conv_pack_write || add_pack_write)output_ram[output_write_address]<=output_write_data;
        if(write_state==W_READ || (write_state==W_DATA && wready))
            write_data<=output_ram[output_read_bank_address];
    end
    assign cmd_ready=!rsp_valid || rsp_ready;
    assign irq=1'b0; // Completion is polled; no vendor PLIC completion state.
    assign rready=read_state==R_DATA;
    assign wdata=write_data;
    assign wvalid=write_state==W_DATA;
    assign wlast=write_beat==write_beats-1;
    assign bready=write_state==W_RESPONSE;
    wire [15:0] pixels={8'd0,cfg[0][7:0]}*{8'd0,cfg[1][7:0]};
    wire [19:0] input_bytes={4'd0,pixels}*cfg[2][5:0];
    wire [19:0] output_bytes=({4'd0,pixels}>>(cfg[4]==2 ? 2 : 0))*cfg[3][5:0];
    // Largest Conv weight layer is 9216 bytes, so retain fourteen bits.
    wire [13:0] expected_weights=14'd576*(cfg[2]==32 ? 4 : cfg[2]==16 ? 2 : 1)*
                                                    (cfg[3]==32 ? 4 : cfg[3]==16 ? 2 : 1);
    wire [32:0] source_end={1'b0,source}+(cmd_inputs_0==1 ? {1'b0,cfg[9]} : {13'd0,input_bytes});
    wire [32:0] destination_end={1'b0,destination}+(cmd_inputs_0==1 ? {1'b0,cfg[9]} : {13'd0,output_bytes});
    wire [32:0] weight_end={1'b0,cfg[5]}+{1'b0,cfg[6]};
    wire [32:0] second_end={1'b0,cfg[8]}+{1'b0,cfg[9]};
    wire addresses_ok=source[3:0]==0 && destination[3:0]==0 && source_end<=33'h10000000 &&
        destination_end<=33'h10000000 && (source_end<={1'b0,destination} || destination_end<={1'b0,source});
    wire conv_ok=(&config_loaded[7:0]) && (&params_loaded) && (&params_good) &&
        cfg[0]>=16 && cfg[0]<=128 && cfg[1]>=2 && cfg[1]<=128 &&
        cfg[0][3:0]==0 && !cfg[1][0] &&
        (cfg[2]==3 || cfg[2]==8 || cfg[2]==16 || cfg[2]==32) &&
        (cfg[3]==3 || cfg[3]==8 || cfg[3]==16 || cfg[3]==32) &&
        (cfg[4]==1 || cfg[4]==2) &&
        // Tight RGB rows must still be whole AXI beats after stride 2.
        ((cfg[0][7:0]>>(cfg[4]==2))*cfg[3][5:0])%16==0 &&
        $signed(cfg[7][23:16])<=$signed(cfg[7][31:24]) &&
        cfg[5][3:0]==0 && cfg[6]==expected_weights && weight_end<=33'h10000000 &&
        (weight_end<={1'b0,destination} || destination_end<={1'b0,cfg[5]});
    wire add_ok=(&config_loaded[21:8]) && cfg[9]!=0 && cfg[9]<=262144 && cfg[9][7:0]==0 &&
        cfg[8][3:0]==0 && second_end<=33'h10000000 &&
        (second_end<={1'b0,destination} || destination_end<={1'b0,cfg[8]}) &&
        $signed(cfg[10])>=-127 && $signed(cfg[10])<=128 &&
        $signed(cfg[11])>=-127 && $signed(cfg[11])<=128 &&
        $signed(cfg[12])>=-128 && $signed(cfg[12])<=127 &&
        !cfg[13][31] && !cfg[15][31] && !cfg[17][31] &&
        $signed(cfg[14])>=-31 && $signed(cfg[14])<=0 &&
        $signed(cfg[16])>=-31 && $signed(cfg[16])<=0 &&
        $signed(cfg[18])>=-31 && $signed(cfg[18])<=0 && cfg[19]<=20 &&
        $signed(cfg[20])>=-128 && $signed(cfg[21])<=127 &&
        $signed(cfg[20])<=$signed(cfg[21]);
    function [4:0] burst_beats(input [27:0] address,input [19:0] remaining);
        reg [8:0] page_beats;
        reg [19:0] words;
        begin
            page_beats=(13'd4096-{1'b0,address[11:0]})>>4;
            words=remaining>>4;
            burst_beats=words<16 ? words[4:0] : 16;
            if(page_beats<burst_beats)burst_beats=page_beats[4:0];
        end
    endfunction
    wire [27:0] add_source=source[27:0]+add_processed;
    wire [27:0] add_second=cfg[8][27:0]+add_processed;
    wire [4:0] add_first_limit=burst_beats(add_source,cfg[9][19:0]-add_processed);
    wire [4:0] add_second_limit=burst_beats(add_second,cfg[9][19:0]-add_processed);
    wire [4:0] add_write_limit=burst_beats(write_next,cfg[9][19:0]-add_processed);
    wire [4:0] add_read_limit=add_first_limit<add_second_limit ? add_first_limit : add_second_limit;
    wire [4:0] add_limit=add_read_limit<add_write_limit ? add_read_limit : add_write_limit;
    integer j;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            busy<=0;done<=0;failed<=0;aborting<=0;phase<=IDLE;elapsed<=0;
            rsp_valid<=0;rsp_outputs_0<=0;source<=0;destination<=0;config_loaded<=0;params_loaded<=0;params_good<=0;
            araddr<=0;arlen<=0;arvalid<=0;awaddr<=0;awlen<=0;awvalid<=0;
            read_state<=R_IDLE;write_state<=W_IDLE;read_next<=0;write_next<=0;read_remaining<=0;
            weight_index<=0;read_beat<=0;read_beats<=0;feed_beat<=0;
            input_queue<=0;input_count<=0;output_pack<=0;output_count<=0;output_words<=0;output_row<=0;
            output_bank<=0;write_bank<=0;
            write_word<=0;write_beat<=0;write_beats<=0;row_write_words<=0;
            conv_start<=0;conv_abort<=0;row_ack<=0;add_input_index<=0;add_output_index<=0;add_processed<=0;add_pack<=0;add_beats<=0;add_i_valid<=0;add_dword<=0;
            for(j=0;j<22;j=j+1)cfg[j]<=0;
        end else begin
            conv_start<=0;conv_abort<=0;row_ack<=0;
            if(rsp_valid && rsp_ready)rsp_valid<=0;
            if(busy)elapsed<=elapsed+1'b1;
            if(input_fire)begin input_queue<=input_queue>>(input_step*8);input_count<=input_count-input_step;end
            if(conv_o_valid && busy && !failed)begin
                if(output_count+output_step>=16)begin
                    output_words<=output_words+1'b1;
                    output_pack<=appended>>128;output_count<=output_count+output_step-16;
                end else begin output_pack<=appended;output_count<=output_count+output_step;end
            end
            add_i_valid<=add_i_request;add_dword<=add_input_index[3:2];
            if(add_i_request)add_input_index<=add_input_index+4;
            if(add_o_valid[0] && busy && !failed)begin
                add_pack[add_output_index[3:2]*32+:32]<=add_o_value;
                add_output_index<=add_output_index+4;
            end
            if(phase==ADD_RUN && add_output_index==add_chunk_bytes)begin
                phase<=ADD_WRITE;row_write_words<=add_beats;write_word<=0;
            end
            case(read_state)
                R_IDLE:if(busy && !failed)begin
                    if((phase==WEIGHTS || phase==CONV) && read_remaining!=0)begin
                        read_beats<=burst_beats(read_next,read_remaining);
                        araddr<={4'd0,read_next};arlen<=burst_beats(read_next,read_remaining)-1'b1;
                        arvalid<=1;read_beat<=0;read_state<=R_ADDRESS;
                    end else if(phase==ADD_A || phase==ADD_B)begin
                        if(phase==ADD_A)add_beats<=add_limit;
                        read_beats<=phase==ADD_A ? add_limit : add_beats;
                        arlen<=(phase==ADD_A ? add_limit : add_beats)-1'b1;
                        araddr<=(phase==ADD_A ? source : cfg[8])+add_processed;
                        arvalid<=1;read_beat<=0;read_state<=R_ADDRESS;
                    end
                end
                R_ADDRESS:if(arready)begin arvalid<=0;read_state<=R_DATA;end
                R_DATA:if(rvalid)begin
                    if(rresp!=0 || rlast!=(read_beat==read_beats-1))begin failed<=1;conv_abort<=1;end
                    if(phase==WEIGHTS)weight_index<=weight_index+1'b1;
                    read_beat<=read_beat+1'b1;
                    if(rlast)begin
                        read_state<=R_IDLE;
                        if(!failed && rresp==0 && read_beat==read_beats-1)begin
                            if(phase==WEIGHTS || phase==CONV)begin
                                read_next<=read_next+({23'd0,read_beats}<<4);
                                read_remaining<=read_remaining-({15'd0,read_beats}<<4);
                            end
                            if(phase==WEIGHTS && read_remaining==({15'd0,read_beats}<<4))begin
                                phase<=CONV;conv_start<=1;read_next<=source[27:0];read_remaining<=input_bytes;
                            end else if(phase==CONV)begin feed_beat<=0;read_state<=R_LOAD;end
                            else if(phase==ADD_A)phase<=ADD_B;
                            else if(phase==ADD_B)begin phase<=ADD_RUN;add_input_index<=0;add_output_index<=0;end
                        end
                    end
                end
                R_FEED:if(failed)read_state<=R_IDLE;
                    else if(input_count<=8 && !input_fire)begin
                        input_queue<=input_queue|({64'd0,input_burst_q}<<(input_count*8));
                        input_count<=input_count+16;feed_beat<=feed_beat+1'b1;
                        read_state<=feed_beat==read_beats-1 ? R_IDLE : R_LOAD;
                    end
                R_LOAD:read_state<=failed ? R_IDLE : R_FEED;
                default:read_state<=R_IDLE;
            endcase
            case(write_state)
                W_IDLE:if(busy && !failed)begin
                    if(phase==CONV && conv_row_done && !row_ack && output_words!=0)begin
                        row_write_words<=output_words;write_word<=0;write_state<=W_READ;
                        write_bank<=output_bank;
                        if(row_overlap)begin
                            output_bank<=~output_bank;output_words<=0;
                            row_ack<=1;output_row<=output_row+1'b1;
                        end
                    end else if(phase==ADD_WRITE)write_state<=W_READ;
                end
                W_READ:begin
                    if(failed)write_state<=W_IDLE;
                    else begin
                        write_beats<=burst_beats(write_next,{7'd0,row_write_words-write_word}<<4);
                        awaddr<={4'd0,write_next};awlen<=burst_beats(write_next,{7'd0,row_write_words-write_word}<<4)-1'b1;
                        awvalid<=1;write_beat<=0;write_state<=W_ADDRESS;
                    end
                end
                W_ADDRESS:if(awready)begin awvalid<=0;write_state<=W_DATA;end
                W_DATA:if(wready)begin
                    write_word<=write_word+1'b1;write_beat<=write_beat+1'b1;
                    write_next<=write_next+16;
                    if(wlast)write_state<=W_RESPONSE;
                end
                W_RESPONSE:if(bvalid)begin
                    if(bresp!=0)begin failed<=1;conv_abort<=1;end
                    write_state<=W_IDLE;
                    if(!failed && bresp==0)begin
                        if(write_word<row_write_words)write_state<=W_READ;
                        else if(phase==CONV)begin
                            if(!row_overlap)begin
                                row_ack<=1;output_words<=0;output_row<=output_row+1'b1;
                            end
                        end else begin
                            add_processed<=add_processed+add_chunk_bytes;
                            if(add_processed+add_chunk_bytes>=cfg[9])begin busy<=0;done<=1;phase<=IDLE;end
                            else phase<=ADD_A;
                        end
                    end
                end
                default:write_state<=W_IDLE;
            endcase
            if(busy && phase==CONV && !conv_start && conv_done && read_state==R_IDLE && write_state==W_IDLE)begin
                busy<=0;done<=1;phase<=IDLE;
            end
            if(busy && failed && read_state==R_IDLE && write_state==W_IDLE && !arvalid && !awvalid)begin
                busy<=0;done<=0;phase<=IDLE;
            end
            if(cmd_valid && cmd_ready)begin
                rsp_valid<=1;rsp_outputs_0<=32'hffffffff;
                case(cmd_function_id)
                    10'h260:rsp_outputs_0<=32'h49500101;
                    10'h261:if(!busy)begin source<=cmd_inputs_0;destination<=cmd_inputs_1;rsp_outputs_0<=0;end
                    10'h262:if(!busy && cmd_inputs_0<22)begin
                        cfg[cmd_inputs_0]<=cmd_inputs_1;config_loaded[cmd_inputs_0]<=1;rsp_outputs_0<=0;
                    end
                    10'h263:if(!busy && cmd_inputs_0<96)begin
                        params_loaded[cmd_inputs_0]<=1;rsp_outputs_0<=0;
                        if(cmd_inputs_0>=32 && cmd_inputs_0<64)params_good[cmd_inputs_0-32]<=!cmd_inputs_1[31];
                        else if(cmd_inputs_0>=64)params_good[cmd_inputs_0-32]<=
                            $signed(cmd_inputs_1)>=-31 && $signed(cmd_inputs_1)<=7;
                    end
                    10'h264:if(busy || !vendor_idle)rsp_outputs_0<=32'hfffffffe;
                        else if(cmd_inputs_0<=1 && addresses_ok && (cmd_inputs_0==0 ? conv_ok : add_ok))begin
                            busy<=1;done<=0;failed<=0;aborting<=0;elapsed<=0;rsp_outputs_0<=0;
                            input_count<=0;input_queue<=0;output_count<=0;output_pack<=0;output_words<=0;output_row<=0;
                            output_bank<=0;write_bank<=0;
                            phase<=cmd_inputs_0==0 ? WEIGHTS : ADD_A;
                            read_next<=cfg[5][27:0];read_remaining<=cfg[6][19:0];weight_index<=0;
                            write_next<=destination[27:0];write_word<=0;add_processed<=0;
                            // Every operator must supply its own complete
                            // configuration; stale parameters cannot qualify.
                            config_loaded<=0;params_loaded<=0;
                        end
                    10'h265:rsp_outputs_0<={28'd0,aborting,failed,done,busy};
                    10'h266:begin
                        rsp_outputs_0<=0;
                        if(busy)begin failed<=1;aborting<=1;conv_abort<=1;end
                    end
                    10'h267:rsp_outputs_0<=elapsed;
                    default:begin end
                endcase
            end
        end
    end
endmodule
