// Gemmlowp double rounding, with a full-width intermediate result. Unlike
// iris_cnn_requant this primitive does not clamp to INT8 between Add stages.
module iris_rain_scale(
    input wire clk,rst_n,i_valid,
    input wire signed [31:0] i_value,i_multiplier,
    input wire signed [7:0] i_shift,
    output reg o_valid,output reg signed [31:0] o_value
);
    reg [1:0] valid;
    reg signed [63:0] product;
    reg signed [31:0] high;
    reg [5:0] right1,right2;
    wire [5:0] left=i_shift>0 ? i_shift : 0;
    wire signed [31:0] shifted=i_value<<<left;
    wire signed [64:0] nudged={product[63],product}+65'sd1073741824;
    wire [31:0] mask=right2==0 ? 0 : 32'hffffffff>>(32-right2);
    wire [31:0] threshold=(mask>>1)+{31'd0,high[31]};
    wire signed [31:0] divided=(high>>>right2)+$signed({31'd0,(high & mask)>threshold});
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin valid<=0;o_valid<=0;product<=0;high<=0;right1<=0;right2<=0;o_value<=0;end
        else begin
            valid<={valid[0],i_valid};o_valid<=valid[1];
            if(i_valid)begin product<=shifted*i_multiplier;right1<=i_shift<0 ? -i_shift : 0;end
            if(valid[0])begin high<=nudged>>>31;right2<=right1;end
            if(valid[1])o_value<=divided;
        end
    end
endmodule

module iris_rain_add(
    input wire clk,rst_n,i_valid,
    input wire signed [7:0] i_a,i_b,
    input wire signed [31:0] offset_a,offset_b,offset_out,mult_a,mult_b,mult_out,
    input wire signed [7:0] shift_a,shift_b,shift_out,
    input wire [4:0] left_shift,
    input wire signed [7:0] activation_min,activation_max,
    output reg o_valid,output reg [7:0] o_value
);
    wire signed [31:0] av=(offset_a+$signed(i_a))<<<left_shift;
    wire signed [31:0] bv=(offset_b+$signed(i_b))<<<left_shift;
    wire signed [31:0] scaled_a,scaled_b,scaled_out;
    wire valid_a,valid_b,valid_out;
    reg sum_valid;
    reg signed [31:0] sum;
    iris_rain_scale ua(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_value(av),.i_multiplier(mult_a),
        .i_shift(shift_a),.o_valid(valid_a),.o_value(scaled_a));
    iris_rain_scale ub(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_value(bv),.i_multiplier(mult_b),
        .i_shift(shift_b),.o_valid(valid_b),.o_value(scaled_b));
    iris_rain_scale uo(.clk(clk),.rst_n(rst_n),.i_valid(sum_valid),.i_value(sum),.i_multiplier(mult_out),
        .i_shift(shift_out),.o_valid(valid_out),.o_value(scaled_out));
    wire signed [32:0] translated={scaled_out[31],scaled_out}+{offset_out[31],offset_out};
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin sum_valid<=0;sum<=0;o_valid<=0;o_value<=0;end
        else begin
            sum_valid<=valid_a && valid_b;
            if(valid_a && valid_b)sum<=scaled_a+scaled_b;
            o_valid<=valid_out;
            if(valid_out)o_value<=translated<$signed(activation_min) ? activation_min :
                translated>$signed(activation_max) ? activation_max : translated[7:0];
        end
    end
endmodule
