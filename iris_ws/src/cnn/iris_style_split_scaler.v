// A 640x480 composite enlarged by 9/4 to 1440x1080.
// The native row renderer runs ahead of this reader in the same scanline.
// One synchronous read port and the previous word cover pairs crossing a
// source-word boundary; no second read port or duplicated frame is needed.
module iris_style_split_scaler #(parameter FULL_WIDTH=0)(
 input wire clk,rst_n,i_hs,i_vs,i_de,i_have_frame,i_good,
 input wire [10:0] i_x,
 input wire i_source_valid,input wire [8:0] i_source_addr,
 input wire [47:0] i_source_rgb,
 output reg o_hs,o_vs,o_de,output reg [47:0] o_rgb
);
(* syn_ramdecomp="area" *) reg [47:0] row_rgb[0:319];
reg [47:0] pair_q,previous_pair;
reg [9:0] source_x;
reg [3:0] phase;
wire inside_image=i_de && (FULL_WIDTH ? i_x<960 : (i_x>=120 && i_x<840));
wire [9:0] second_x=source_x+(FULL_WIDTH ? (phase==4'd2) : (phase>=5));
wire [8:0] read_addr=inside_image ? second_x[9:1] : 9'd0;
reg first_odd_q,second_odd_q,cross_q,inside_q;
reg hs_q,vs_q,de_q;
wire [47:0] first_pair=cross_q ? previous_pair : pair_q;
always @(posedge clk)begin
 if(i_source_valid)row_rgb[i_source_addr]<=i_source_rgb;
 pair_q<=row_rgb[read_addr];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  source_x<=0;phase<=0;previous_pair<=0;
  first_odd_q<=0;second_odd_q<=0;cross_q<=0;inside_q<=0;
  hs_q<=0;vs_q<=0;de_q<=0;o_hs<=0;o_vs<=0;o_de<=0;o_rgb<=0;
 end else begin
  if(inside_image)begin
   source_x<=source_x+(phase!=0);
   phase<=phase==0 ? (FULL_WIDTH ? 4'd2 : 4'd8) : phase-1'b1;
  end else begin source_x<=0;phase<=0;end
  previous_pair<=pair_q;
  first_odd_q<=source_x[0];second_odd_q<=second_x[0];
  cross_q<=source_x[9:1]!=second_x[9:1];
  inside_q<=inside_image && i_have_frame && i_good;
  hs_q<=i_hs;vs_q<=i_vs;de_q<=i_de;
  o_hs<=hs_q;o_vs<=vs_q;o_de<=de_q;
  o_rgb<=inside_q ? {first_odd_q ? first_pair[23:0] : first_pair[47:24],
                     second_odd_q ? pair_q[23:0] : pair_q[47:24]} : 48'd0;
 end
end
endmodule
