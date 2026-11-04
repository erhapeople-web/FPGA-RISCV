`timescale 1ns/1ps
// Four-entry CDC mailbox queue. Only Gray pointers cross the clock boundary.
// Payload stays unchanged from the write until the synchronized write pointer
// makes it visible to the reader. Global reset must reset BOTH FIFO domains.
module video_async_fifo #(
    parameter WIDTH = 34,
    parameter ADDR_BITS = 2
)(
    input wr_clk, wr_rstn,
    input wr_valid,
    input [WIDTH-1:0] wr_data,
    output wr_ready,
    input rd_clk, rd_rstn,
    output rd_valid,
    output [WIDTH-1:0] rd_data,
    input rd_ready
);
    localparam DEPTH = (1 << ADDR_BITS);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_BITS:0] wbin, wgray, rbin, rgray;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_BITS:0] rgray_w1, rgray_w2;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_BITS:0] wgray_r1, wgray_r2;
    reg full, empty;
    wire [ADDR_BITS:0] wnext = wbin + (wr_valid && wr_ready);
    wire [ADDR_BITS:0] rnext = rbin + (rd_valid && rd_ready);
    wire [ADDR_BITS:0] wgray_next = (wnext >> 1) ^ wnext;
    wire [ADDR_BITS:0] rgray_next = (rnext >> 1) ^ rnext;
    wire [ADDR_BITS:0] full_compare =
        {~rgray_w2[ADDR_BITS:ADDR_BITS-1], rgray_w2[ADDR_BITS-2:0]};
    assign wr_ready = !full;
    assign rd_valid = !empty;
    assign rd_data = mem[rbin[ADDR_BITS-1:0]];
    always @(posedge wr_clk or negedge wr_rstn) begin
        if (!wr_rstn) begin
            wbin <= 0; wgray <= 0; full <= 0;
            rgray_w1 <= 0; rgray_w2 <= 0;
        end else begin
            rgray_w1 <= rgray; rgray_w2 <= rgray_w1;
            wbin <= wnext; wgray <= wgray_next;
            full <= (wgray_next == full_compare);
            if (wr_valid && wr_ready) mem[wbin[ADDR_BITS-1:0]] <= wr_data;
        end
    end
    always @(posedge rd_clk or negedge rd_rstn) begin
        if (!rd_rstn) begin
            rbin <= 0; rgray <= 0; empty <= 1;
            wgray_r1 <= 0; wgray_r2 <= 0;
        end else begin
            wgray_r1 <= wgray; wgray_r2 <= wgray_r1;
            rbin <= rnext; rgray <= rgray_next;
            empty <= (rgray_next == wgray_r2);
        end
    end
`ifndef SYNTHESIS
    initial if (ADDR_BITS < 2) $fatal(1, "video_async_fifo requires ADDR_BITS >= 2");
`endif
endmodule
