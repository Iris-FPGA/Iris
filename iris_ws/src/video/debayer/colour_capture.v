// KEY2 captures a complete 96x54 linear RGB thumbnail from one frame.
// UART 'C' reads the frozen image; it never triggers a new exposure/snapshot.
// Single-owner dual-clock RAM: no writes while the UART is streaming it.
// Packet: IRISCAL1, width LE16, height LE16, RGB bytes, CRC16-CCITT LE16.
module colour_capture #(
 parameter WIDTH=1920, HEIGHT=1080, STEP=20,
 parameter CW=WIDTH/STEP, CH=HEIGHT/STEP
)(
 input video_clk,uart_clk,rst_n,i_vs,i_de,
 input [47:0] i_rgb,
 input i_capture,rx_valid,input [7:0] rx_data,
 input log_active,tx_req,
 output reg tx_valid,output reg [7:0] tx_data,
 output wire tx_gate,output wire o_ready
);
localparam N=CW*CH;
localparam IDLE=0,WAIT_LOG=1,WAIT_FRAME=2,SEND=3,DRAIN=4;
reg [23:0] mem[0:N-1];
reg [23:0] read_pixel;
reg [12:0] read_addr,write_addr;
reg request_toggle,done_toggle;
reg [2:0] request_sync,done_sync;
reg vs_d,de_d,armed,capturing;
reg [11:0] x,y,next_x,next_y;
reg [2:0] state,quiet;
reg [15:0] index,crc;
reg [1:0] colour_index;
reg capture_pending,capture_busy,have_frame,empty_packet;
wire request_edge=request_sync[2]^request_sync[1];
wire done_edge=done_sync[2]^done_sync[1];
assign tx_gate=state!=IDLE;
assign o_ready=have_frame && !capture_busy;
function [15:0] crc_byte;
 input [15:0] old;input [7:0] b;
 reg [15:0] c;integer k;
 begin c=old^{b,8'b0};for(k=0;k<8;k=k+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
endfunction
always @(posedge video_clk or negedge rst_n)begin
 if(!rst_n)begin
  request_sync<=0;done_toggle<=0;vs_d<=0;de_d<=0;armed<=0;capturing<=0;
  x<=0;y<=0;next_x<=STEP/4;next_y<=STEP/2;write_addr<=0;
 end else begin
  request_sync<={request_sync[1:0],request_toggle};vs_d<=i_vs;de_d<=i_de;
  if(request_edge)armed<=1;
  if(i_vs && !vs_d)begin
   x<=0;y<=0;next_x<=STEP/4;next_y<=STEP/2;write_addr<=0;
   if(capturing)begin
    capturing<=0;
    if(write_addr==N)done_toggle<=~done_toggle;
    else armed<=1; // Retry partial/mode-transition frames; never stream stale RAM.
   end
   else if(armed)begin capturing<=1;armed<=0;end
  end else if(i_de)begin
   x<=x+1'b1;
   if(capturing && x==next_x && y==next_y && write_addr<N)begin
    write_addr<=write_addr+1'b1;next_x<=next_x+STEP/2;
   end
  end else if(de_d)begin
   x<=0;y<=y+1'b1;next_x<=STEP/4;
   if(y==next_y)next_y<=next_y+STEP;
  end
 end
end
// No reset on the memory ports; Efinity infers block RAM with two clocks.
always @(posedge video_clk)
 if(capturing && i_de && !i_vs && x==next_x && y==next_y && write_addr<N)
  mem[write_addr]<=i_rgb[23:0];
always @(posedge uart_clk)read_pixel<=mem[read_addr];
reg [7:0] ch;
always @* begin
 case(index)
  0:ch="I";1:ch="R";2:ch="I";3:ch="S";
  4:ch="C";5:ch="A";6:ch="L";7:ch="1";
  8:ch=empty_packet?0:CW;9:ch=empty_packet?0:CW>>8;
  10:ch=empty_packet?0:CH;11:ch=empty_packet?0:CH>>8;
  default:begin
   if(index==(empty_packet?12:12+3*N))ch=crc[7:0];
   else if(index==(empty_packet?13:13+3*N))ch=crc[15:8];
   else case(colour_index)
    0:ch=read_pixel[23:16];1:ch=read_pixel[15:8];default:ch=read_pixel[7:0];
   endcase
  end
 endcase
end
always @(posedge uart_clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;quiet<=0;index<=0;colour_index<=0;crc<=16'hffff;
  request_toggle<=0;done_sync<=0;read_addr<=0;tx_valid<=0;tx_data<=0;
  capture_pending<=0;capture_busy<=0;have_frame<=0;empty_packet<=0;
 end else begin
  done_sync<={done_sync[1:0],done_toggle};tx_valid<=0;
  if(i_capture)capture_pending<=1;
  if(capture_pending && state==IDLE && !capture_busy)begin
   capture_pending<=0;capture_busy<=1;have_frame<=0;request_toggle<=~request_toggle;
  end
  if(done_edge)begin capture_busy<=0;have_frame<=1;end
  if(!tx_req || tx_valid || log_active)quiet<=0;
  else if(quiet<7)quiet<=quiet+1'b1;
  case(state)
   IDLE:if(rx_valid && rx_data=="C")begin
    empty_packet<=!have_frame || capture_busy || capture_pending || i_capture;
    state<=WAIT_LOG;
   end
   WAIT_LOG:if(!log_active && quiet>=6)begin state<=SEND;index<=0;colour_index<=0;read_addr<=0;crc<=16'hffff;end
   SEND:if(tx_req && quiet>=6 && !tx_valid)begin
    tx_valid<=1;tx_data<=ch;
    if(index<(empty_packet?12:12+3*N))crc<=crc_byte(crc,ch);
    if(!empty_packet && index>=12 && index<12+3*N)begin
     if(colour_index==2)begin colour_index<=0;read_addr<=read_addr+1'b1;end
     else colour_index<=colour_index+1'b1;
    end
    if(index==(empty_packet?13:13+3*N))state<=DRAIN;
    else index<=index+1'b1;
   end
   DRAIN:if(!tx_req)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
end
endmodule
