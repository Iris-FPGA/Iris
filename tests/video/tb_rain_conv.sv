module tb_rain_conv;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,start=0,abort=0;
    reg [7:0] config_data[0:9];
    reg weight_valid=0,parameter_valid=0,i_valid=0,row_ack=0;
    reg [9:0] weight_index=0;
    reg [127:0] weight_data=0;
    reg [6:0] parameter_index=0;
    reg [31:0] parameter_data=0;
    reg [63:0] i_data=0;
    wire i_ready,o_valid,row_done,done;
    wire [63:0] o_data;
    wire [31:0] cycles;
    iris_rain_conv dut(.clk(clk),.rst_n(rst_n),.start(start),.abort(abort),
        .width(config_data[0]),.height(config_data[1]),
        .input_channels(config_data[2][5:0]),.output_channels(config_data[3][5:0]),
        .stride2(config_data[4][0]),.input_zero(config_data[5]),.output_zero(config_data[6]),
        .activation_min(config_data[7]),.activation_max(config_data[8]),
        .weight_valid(weight_valid),.weight_index(weight_index),.weight_data(weight_data),
        .parameter_valid(parameter_valid),.parameter_index(parameter_index),.parameter_data(parameter_data),
        .i_valid(i_valid),.i_data(i_data),.i_ready(i_ready),.o_valid(o_valid),.o_data(o_data),
        .row_done(row_done),.row_ack(row_ack),.done(done),.cycles(cycles));
    reg [63:0] inputs[0:65535],expected[0:65535];
    reg [127:0] weights[0:575];
    reg [31:0] parameters[0:95];
    string dir;
    integer input_words,output_words,ni,no,j,weight_words,ack_delay,round;
    reg [31:0] rng=32'h75ba39d1;
    always @(posedge clk)if(rst_n && o_valid)begin
        if(no>=output_words || o_data!==expected[no])
            $fatal(1,"output %0d got=%h expected=%h state=%0d",no,o_data,expected[no],dut.state);
        no=no+1;
    end
    initial begin
        if(!$value$plusargs("DIR=%s",dir))$fatal(1,"missing DIR");
        $readmemh({dir,"/config.mem"},config_data);
        input_words=config_data[0]*config_data[1]*((config_data[2]+7)/8);
        output_words=(config_data[0]>>config_data[4])*(config_data[1]>>config_data[4])*((config_data[3]+7)/8);
        // The byte config contains the low eight bits; derive large weight
        // counts from the actual channel shapes rather than truncating them.
        weight_words=9*((config_data[2]+7)/8)*((config_data[3]+7)/8)*4;
        $readmemh({dir,"/input.mem"},inputs,0,input_words-1);
        $readmemh({dir,"/output.mem"},expected,0,output_words-1);
        $readmemh({dir,"/weights.mem"},weights,0,weight_words-1);
        $readmemh({dir,"/parameters.mem"},parameters);
        repeat(4)@(negedge clk);rst_n=1;
        for(j=0;j<weight_words;j=j+1)begin
            @(negedge clk);weight_valid=1;weight_index=j;weight_data=weights[j];
        end
        @(negedge clk);weight_valid=0;
        for(j=0;j<96;j=j+1)begin
            @(negedge clk);parameter_valid=1;parameter_index=j;parameter_data=parameters[j];
        end
        @(negedge clk);parameter_valid=0;
        for(round=0;round<2;round=round+1)begin
            ni=0;no=0;ack_delay=0;
            @(negedge clk);start=1;
            @(negedge clk);start=0;
            while(!done)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                i_valid=ni<input_words && rng[3:0]!=0;
                i_data=inputs[ni];
                row_ack=row_done && ack_delay>=3;
                if(row_done)ack_delay=ack_delay+1;else ack_delay=0;
                @(posedge clk);
                if(i_valid && i_ready)ni=ni+1;
                @(negedge clk);
            end
            i_valid=0;row_ack=0;
            if(ni!=input_words || no!=output_words)$fatal(1,"incomplete %0d/%0d out %0d/%0d",ni,input_words,no,output_words);
            $display("PASS Rain Conv %s round=%0d words=%0d cycles=%0d",dir,round,no,cycles);
        end
        $finish;
    end
    initial begin #20000000;$fatal(1,"timeout state=%0d input_y=%0d output_y=%0d groups_seen=%0d",dut.state,dut.iy,dut.oy,dut.output_groups_seen);end
endmodule
