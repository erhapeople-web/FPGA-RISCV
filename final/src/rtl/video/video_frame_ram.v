`timescale 1ns/1ps
// Three independent, simple dual-port block RAM banks. Each bank has one
// camera-clock write port and one pixel-clock synchronous read port. Never
// reset/clear the arrays: bank ownership and display_valid mask stale contents.
// The template requests PDS block RAM; actual DRM inference is a PDS gate.
module video_frame_ram #(
    parameter DEPTH = 57600,
    parameter ADDR_WIDTH = 16
)(
    input wr_clk, wr_en,
    input [1:0] wr_bank,
    input [ADDR_WIDTH-1:0] wr_addr,
    input [15:0] wr_data,
    input rd_clk, rd_en,
    input [1:0] rd_bank,
    input [ADDR_WIDTH-1:0] rd_addr,
    output [15:0] rd_data
);
    reg [15:0] bank0 [0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [15:0] bank1 [0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [15:0] bank2 [0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [15:0] q0, q1, q2;
    reg [1:0] bank_q;
    always @(posedge wr_clk) begin
        if (wr_en && wr_addr < DEPTH) begin
            case (wr_bank)
                0: bank0[wr_addr] <= wr_data;
                1: bank1[wr_addr] <= wr_data;
                2: bank2[wr_addr] <= wr_data;
                default: ;
            endcase
        end
    end
    always @(posedge rd_clk) begin
        bank_q <= rd_bank;
        if (rd_en && rd_addr < DEPTH) begin
            if (rd_bank == 0) q0 <= bank0[rd_addr];
            if (rd_bank == 1) q1 <= bank1[rd_addr];
            if (rd_bank == 2) q2 <= bank2[rd_addr];
        end
    end
    assign rd_data = bank_q == 0 ? q0 : bank_q == 1 ? q1 : q2;
endmodule
