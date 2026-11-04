`timescale 1ns/1ps
// Single-master, 16-bit register / 8-bit data I2C/SCCB transactions.
// SDA is open drain. SCL is output-only: clock stretching and multi-master
// arbitration are deliberately unsupported by this board interface.
// Device addresses are SEVEN bits; lsb_first applies only to register bytes.
module video_i2c_master #(
    parameter CLOCK_HZ=100000000,
    parameter I2C_HZ=100000,
    parameter TIMEOUT_CYCLES=CLOCK_HZ/10
)(
    input wire clk,resetn,start,read,lsb_first,
    input wire [6:0] device_addr,
    input wire [15:0] reg_addr,
    input wire [7:0] write_data,
    output reg busy,done,nack,timeout,
    output reg [7:0] read_data,
    output reg scl,
    inout wire sda
);
    localparam QDIV_RAW=(CLOCK_HZ+4*I2C_HZ-1)/(4*I2C_HZ);
    localparam QDIV=(QDIV_RAW<2) ? 2:QDIV_RAW;
    localparam LIMIT=(TIMEOUT_CYCLES<1) ? 1:TIMEOUT_CYCLES;
    localparam IDLE=0,FREE=1,START_HOLD=2,
        TX_LOW=3,TX_RISE=4,TX_HIGH=5,TX_FALL=6,
        ACK_LOW=7,ACK_RISE=8,ACK_HIGH=9,ACK_FALL=10,
        RS_LOW=11,RS_RISE=12,RS_START=13,RS_FALL=14,
        RX_LOW=15,RX_RISE=16,RX_HIGH=17,RX_FALL=18,
        NACK_LOW=19,NACK_RISE=20,NACK_HIGH=21,NACK_FALL=22,
        STOP_LOW=23,STOP_RISE=24,STOP_RELEASE=25,STOP_DONE=26,
        START_WAIT=27,RS_RISE_WAIT=28,RS_START_WAIT=29,
        STOP_RISE_WAIT=30,FREE_WAIT=31;
    reg [4:0] state;
    reg sda_low;
    // ADS User Guide 5.19/5.15/5.1: keep the asynchronous first stage distinct.
    reg sda_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg sda_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg [31:0] divider,watchdog;
    reg [7:0] tx_byte,data_q,addr_first,addr_second;
    reg [6:0] dev_q;
    reg read_q;
    reg [2:0] bit_index;
    reg [1:0] byte_index;
    wire tick=divider==QDIV-1;
    assign sda=sda_low ? 1'b0:1'bz;

    always @(posedge clk or negedge resetn)
        if(!resetn)begin sda_meta<=1;sda_sync<=1;end
        else begin sda_meta<=sda;sda_sync<=sda_meta;end

    always @(posedge clk or negedge resetn)begin
        if(!resetn)begin
            state<=IDLE;scl<=1;sda_low<=0;busy<=0;done<=0;
            nack<=0;timeout<=0;read_data<=0;divider<=0;watchdog<=0;
            tx_byte<=0;data_q<=0;dev_q<=0;read_q<=0;
            addr_first<=0;addr_second<=0;bit_index<=7;byte_index<=0;
        end else begin
            done<=0;
            if(!busy)begin
                divider<=0;watchdog<=0;
                if(start)begin
                    busy<=1;nack<=0;timeout<=0;read_data<=0;
                    scl<=1;sda_low<=0;state<=FREE;
                    dev_q<=device_addr;read_q<=read;data_q<=write_data;
                    addr_first<=lsb_first ? reg_addr[7:0]:reg_addr[15:8];
                    addr_second<=lsb_first ? reg_addr[15:8]:reg_addr[7:0];
                    tx_byte<={device_addr,1'b0};bit_index<=7;byte_index<=0;
                end
            end else if(watchdog>=LIMIT-1)begin
                // Unknown bus state: release pins and report failure, never retry.
                timeout<=1;busy<=0;done<=1;scl<=1;sda_low<=0;state<=IDLE;
            end else begin
                watchdog<=watchdog+1'b1;
                if(tick)begin
                    divider<=0;
                    case(state)
                        FREE:if(sda_sync)state<=FREE_WAIT;
                        FREE_WAIT:if(sda_sync)begin sda_low<=1;state<=START_HOLD;end
                                  else state<=FREE;
                        // START hold, repeated-START setup/hold and STOP setup
                        // each get a half period, not only one quarter tick.
                        START_HOLD:state<=START_WAIT;
                        START_WAIT:begin scl<=0;state<=TX_LOW;end
                        TX_LOW:begin scl<=0;sda_low<=!tx_byte[bit_index];state<=TX_RISE;end
                        TX_RISE:begin scl<=1;state<=TX_HIGH;end
                        TX_HIGH:state<=TX_FALL;
                        TX_FALL:begin
                            scl<=0;
                            if(bit_index==0)state<=ACK_LOW;
                            else begin bit_index<=bit_index-1'b1;state<=TX_LOW;end
                        end
                        ACK_LOW:begin sda_low<=0;state<=ACK_RISE;end
                        ACK_RISE:begin scl<=1;state<=ACK_HIGH;end
                        ACK_HIGH:begin
                            if(sda_sync!==1'b0)nack<=1;
                            state<=ACK_FALL;
                        end
                        ACK_FALL:begin
                            scl<=0;bit_index<=7;
                            if(nack)state<=STOP_LOW;
                            else case(byte_index)
                                0:begin tx_byte<=addr_first;byte_index<=1;state<=TX_LOW;end
                                1:begin tx_byte<=addr_second;byte_index<=2;state<=TX_LOW;end
                                2:if(read_q)state<=RS_LOW;
                                  else begin tx_byte<=data_q;byte_index<=3;state<=TX_LOW;end
                                3:if(read_q)state<=RX_LOW;else state<=STOP_LOW;
                            endcase
                        end
                        RS_LOW:begin sda_low<=0;state<=RS_RISE;end
                        RS_RISE:begin scl<=1;state<=RS_RISE_WAIT;end
                        RS_RISE_WAIT:state<=RS_START;
                        RS_START:begin sda_low<=1;state<=RS_START_WAIT;end
                        RS_START_WAIT:state<=RS_FALL;
                        RS_FALL:begin
                            scl<=0;tx_byte<={dev_q,1'b1};byte_index<=3;
                            bit_index<=7;state<=TX_LOW;
                        end
                        RX_LOW:begin scl<=0;sda_low<=0;state<=RX_RISE;end
                        RX_RISE:begin scl<=1;state<=RX_HIGH;end
                        RX_HIGH:begin read_data[bit_index]<=sda_sync;state<=RX_FALL;end
                        RX_FALL:begin
                            scl<=0;
                            if(bit_index==0)state<=NACK_LOW;
                            else begin bit_index<=bit_index-1'b1;state<=RX_LOW;end
                        end
                        // A single-byte read ends with master NACK, then STOP.
                        NACK_LOW:begin sda_low<=0;state<=NACK_RISE;end
                        NACK_RISE:begin scl<=1;state<=NACK_HIGH;end
                        NACK_HIGH:state<=NACK_FALL;
                        NACK_FALL:begin scl<=0;state<=STOP_LOW;end
                        STOP_LOW:begin scl<=0;sda_low<=1;state<=STOP_RISE;end
                        STOP_RISE:begin scl<=1;state<=STOP_RISE_WAIT;end
                        STOP_RISE_WAIT:state<=STOP_RELEASE;
                        STOP_RELEASE:begin sda_low<=0;state<=STOP_DONE;end
                        STOP_DONE:if(sda_sync)begin busy<=0;done<=1;state<=IDLE;end
                        default:begin timeout<=1;busy<=0;done<=1;scl<=1;sda_low<=0;state<=IDLE;end
                    endcase
                end else divider<=divider+1'b1;
            end
        end
    end
endmodule
