// 64 KiB immutable program ROM, 64 KiB byte-enabled RAM, and MMIO.
// Local response is registered. No destructive reads or writes repeat on stall.
module local_memory #(parameter CLOCK_HZ=100000000, UART_BAUD=921600)(
    input wire clk,resetn,input wire valid,output wire ready,
    input wire write,input wire [31:0] addr,wdata,input wire [3:0] wstrb,
    output reg rvalid,input wire rready,output reg [31:0] rdata,output reg error,
    input wire uart_rx,output wire uart_tx,output reg [7:0] gpio_out,
    output wire irq_timer,irq_software,irq_external,
    input wire [63:0] cpu_cycles,cpu_retired,
    input wire [31:0] branches,mispredicts,hazards,mem_wait,ic_access,ic_miss,dc_access,dc_miss,
    output wire video_access,video_write,output wire [7:0] video_addr,
    output wire [31:0] video_wdata,output wire [3:0] video_wstrb,
    input wire [31:0] video_rdata,input wire video_error,video_ready
);
    reg [31:0] rom[0:16383];
    reg [31:0] ram[0:16383];
    initial begin
        `include "firmware_init.vh"
    end
    wire in_rom=addr[31:16]==0;
    wire in_ram=addr[31:16]==16'h1000;
    wire tx_ready,rx_valid,rx_overrun;
    wire [7:0] rx_data;
    reg uart_irq_enable,msip;
    reg [63:0] mtime,mtimecmp;
    wire uart_data_write=write && addr==32'h20000000 && wstrb[0];
    // Only a video request waits for the video arbiter. Other targets keep J5 timing.
    assign ready=resetn && (!rvalid || rready) && (!uart_data_write || tx_ready)
        && (!video_window || (|addr[1:0]) || video_ready);
    wire accept=valid && ready;
    wire video_window=addr[31:8]==24'h200070;
    // Video is a held request, not a side-effect pulse. The transaction
    // bridge captures these fields and only raises video_ready for its saved
    // reply. An unaligned access is rejected locally without bridge activity.
    assign video_access=resetn && valid && (!rvalid || rready) && video_window && !(|addr[1:0]);
    assign video_write=write;assign video_addr=addr[7:0];
    assign video_wdata=wdata;assign video_wstrb=wstrb;
    uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(UART_BAUD)) u_uart(.clk(clk),.resetn(resetn),.rx(uart_rx),.tx(uart_tx),
        .tx_valid(accept && uart_data_write),.tx_ready(tx_ready),.tx_data(wdata[7:0]),
        .rx_valid(rx_valid),.rx_take(accept && !write && addr==32'h20000008),.rx_data(rx_data),.rx_overrun(rx_overrun));
    assign irq_timer=mtime>=mtimecmp;
    assign irq_software=msip;
    assign irq_external=uart_irq_enable && rx_valid;
    function [31:0] merge_bytes;
        input [31:0] old_value,new_value;input [3:0] mask;
        integer k;
        begin for(k=0;k<4;k=k+1)merge_bytes[k*8+:8]=mask[k] ? new_value[k*8+:8]:old_value[k*8+:8];end
    endfunction
    // ROM and RAM are reachable only through the AXI slave's local port.
    wire ram_axi_write=accept && in_ram && write;
    integer lane;
    always @(posedge clk)if(ram_axi_write)
        for(lane=0;lane<4;lane=lane+1)
            if(wstrb[lane])ram[addr[15:2]][8*lane+:8]<=wdata[8*lane+:8];
    always @(posedge clk)begin
        if(!resetn)begin
            rvalid<=0;rdata<=0;error<=0;gpio_out<=0;mtime<=0;mtimecmp<=64'hffffffffffffffff;msip<=0;uart_irq_enable<=0;
        end else begin
            mtime<=mtime+1'b1;
            if(rvalid && rready)rvalid<=0;
            if(accept)begin
                rvalid<=1;rdata<=0;error<=|addr[1:0];
                if(in_rom)begin rdata<=rom[addr[15:2]];if(write)error<=1;end
                else if(in_ram)rdata<=ram[addr[15:2]];
                else if(video_window)begin
                    rdata<=(|addr[1:0]) ? 32'b0:video_rdata;
                    error<=(|addr[1:0]) || video_error;
                end
                else case(addr)
                    32'h20000000:begin if(!write)error<=1;end
                    32'h20000004:begin rdata<={29'b0,rx_overrun,rx_valid,tx_ready};if(write)error<=1;end
                    32'h20000008:begin rdata<={24'b0,rx_data};if(write)error<=1;end
                    32'h2000000c:begin rdata<={31'b0,uart_irq_enable};if(write && wstrb[0])uart_irq_enable<=wdata[0];end
                    32'h20001000:begin rdata<={24'b0,gpio_out};if(write && wstrb[0])gpio_out<=wdata[7:0];end
                    32'h20002000:begin rdata<=mtime[31:0];if(write)error<=1;end
                    32'h20002004:begin rdata<=mtime[63:32];if(write)error<=1;end
                    32'h20002008:begin rdata<=mtimecmp[31:0];if(write)mtimecmp[31:0]<=merge_bytes(mtimecmp[31:0],wdata,wstrb);end
                    32'h2000200c:begin rdata<=mtimecmp[63:32];if(write)mtimecmp[63:32]<=merge_bytes(mtimecmp[63:32],wdata,wstrb);end
                    32'h20002010:begin rdata<={31'b0,msip};if(write && wstrb[0])msip<=wdata[0];end
                    32'h20004000:begin rdata<=cpu_cycles[31:0];if(write)error<=1;end
                    32'h20004004:begin rdata<=cpu_cycles[63:32];if(write)error<=1;end
                    32'h20004008:begin rdata<=cpu_retired[31:0];if(write)error<=1;end
                    32'h2000400c:begin rdata<=cpu_retired[63:32];if(write)error<=1;end
                    32'h20004010:begin rdata<=branches;if(write)error<=1;end
                    32'h20004014:begin rdata<=mispredicts;if(write)error<=1;end
                    32'h20004018:begin rdata<=hazards;if(write)error<=1;end
                    32'h2000401c:begin rdata<=mem_wait;if(write)error<=1;end
                    32'h20004020:begin rdata<=ic_access;if(write)error<=1;end
                    32'h20004024:begin rdata<=ic_miss;if(write)error<=1;end
                    32'h20004028:begin rdata<=dc_access;if(write)error<=1;end
                    32'h2000402c:begin rdata<=dc_miss;if(write)error<=1;end
                    default:error<=1;
                endcase
            end
        end
    end
endmodule
