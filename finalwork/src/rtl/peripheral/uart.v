// 8N1 UART with independent engines and a 128-byte receive FIFO.  The CPU
// may finish a packet/ACK while the next UART packet is already arriving.
module uart #(parameter CLOCK_HZ=100000000,BAUD=115200)(
    input wire clk,resetn,input wire rx,output wire tx,
    input wire tx_valid,output wire tx_ready,input wire [7:0] tx_data,
    output wire rx_valid,input wire rx_take,output wire [7:0] rx_data,output reg rx_overrun
);
    localparam DIV=(CLOCK_HZ+BAUD/2)/BAUD;
    reg [15:0] tx_tick,rx_tick;
    reg [3:0] tx_left,rx_bit;
    reg [9:0] tx_shift;
    reg [7:0] rx_shift;
    // ADS User Guide 5.19/5.15/5.1: first-stage D has an unambiguous scalar name.
    reg rx_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg rx_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    wire [1:0] rx_sync={rx_sync_q,rx_meta};
    reg [1:0] rx_state;
    reg [7:0] rx_fifo[0:127];
    reg [6:0] rx_read_ptr,rx_write_ptr;
    reg [7:0] rx_count;
    wire rx_pop=rx_take && rx_valid;
    wire rx_complete=rx_state==3 && rx_tick==0 && rx_sync_q;
    wire rx_push=rx_complete && (rx_count!=128 || rx_pop);
    assign rx_valid=rx_count!=0;
    assign rx_data=rx_valid ? rx_fifo[rx_read_ptr] : 8'b0;
    // RAM contents need no reset; the count invalidates every old entry.
    always @(posedge clk)if(resetn && rx_push)rx_fifo[rx_write_ptr]<=rx_shift;
    assign tx_ready=tx_left==0;
    assign tx=tx_left==0 ? 1'b1:tx_shift[0];
    always @(posedge clk)begin
        if(!resetn)begin
            tx_tick<=0;tx_left<=0;tx_shift<=10'h3ff;
            rx_meta<=1;rx_sync_q<=1;rx_state<=0;rx_tick<=0;rx_bit<=0;rx_shift<=0;rx_overrun<=0;
            rx_read_ptr<=0;rx_write_ptr<=0;rx_count<=0;
        end else begin
            rx_meta<=rx;rx_sync_q<=rx_meta;
            if(tx_valid && tx_ready)begin tx_shift<={1'b1,tx_data,1'b0};tx_left<=10;tx_tick<=DIV-1;end
            else if(tx_left!=0)begin
                if(tx_tick==0)begin tx_tick<=DIV-1;tx_left<=tx_left-1'b1;tx_shift<={1'b1,tx_shift[9:1]};end
                else tx_tick<=tx_tick-1'b1;
            end
            if(rx_pop)rx_read_ptr<=rx_read_ptr+1'b1;
            if(rx_push)rx_write_ptr<=rx_write_ptr+1'b1;
            case({rx_push,rx_pop})
                2'b10:rx_count<=rx_count+1'b1;
                2'b01:rx_count<=rx_count-1'b1;
                default:begin end
            endcase
            if(rx_complete && !rx_push)rx_overrun<=1;
            case(rx_state)
                0:if(!rx_sync[1])begin rx_tick<=DIV/2-1;rx_state<=1;end
                1:if(rx_tick!=0)rx_tick<=rx_tick-1'b1;
                  else if(!rx_sync[1])begin rx_tick<=DIV-1;rx_bit<=0;rx_state<=2;end
                  else rx_state<=0;
                2:if(rx_tick!=0)rx_tick<=rx_tick-1'b1;
                  else begin
                      rx_shift[rx_bit]<=rx_sync[1];rx_tick<=DIV-1;
                      if(rx_bit==7)rx_state<=3;else rx_bit<=rx_bit+1'b1;
                  end
                3:if(rx_tick!=0)rx_tick<=rx_tick-1'b1;
                  else begin
                      rx_state<=0;
                  end
            endcase
        end
    end
endmodule
