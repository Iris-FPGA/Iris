// Sensor byte-clock edge counter, Gray synchronized to a stable reference.
// Difference over one reference second gives average edges/second; a gated
// MIPI clock includes LP idle time and does not give the HS burst clock rate.
module clock_frequency_meter #(parameter REF_HZ=100_000_000)(
 input i_clock,i_ref_clock,rst_n,output reg [31:0] o_hz
);
reg [31:0] counter,gray,meta,synced,previous;
reg [31:0] gate;
wire [31:0] next_count=counter+32'd1;
function [31:0] decode;
 input [31:0] g;
 integer n;
 begin decode[31]=g[31];for(n=30;n>=0;n=n-1)decode[n]=decode[n+1]^g[n];end
endfunction
always @(posedge i_clock or negedge rst_n)begin
 if(!rst_n)begin counter<=0;gray<=0;end
 else begin counter<=next_count;gray<=next_count^(next_count>>1);end
end
always @(posedge i_ref_clock or negedge rst_n)begin
 if(!rst_n)begin meta<=0;synced<=0;previous<=0;gate<=0;o_hz<=0;end
 else begin
  meta<=gray;synced<=meta;
  if(gate==REF_HZ-1)begin
   gate<=0;o_hz<=decode(synced)-previous;previous<=decode(synced);
  end else gate<=gate+1'b1;
 end
end
endmodule
