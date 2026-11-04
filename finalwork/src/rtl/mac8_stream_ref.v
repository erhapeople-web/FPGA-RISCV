`timescale 1ns/1ps
// Eight exact integer lane products followed by a checked, wrapped INT32 sum.
// See README.md for grouping/error/reset and ready/valid contract.
module mac8_stream_ref (
    input wire clk,
    input wire rst,
    input wire s_valid,
    output wire s_ready,
    input wire [63:0] s_data,
    input wire [63:0] s_weight,
    input wire [7:0] s_mask,
    input wire s_first,
    input wire s_last,
    input wire signed [31:0] s_bias,
    input wire s_unsigned,
    input wire signed [7:0] s_zero,
    output reg m_valid,
    input wire m_ready,
    output reg signed [31:0] m_data,
    output reg m_error
);
    reg active;
    reg unsigned_mode;
    reg signed [7:0] input_zero;
    reg overflow_seen;
    reg signed [31:0] accumulator;
    reg signed [8:0] lane_input;
    reg signed [7:0] lane_weight;
    reg signed [16:0] lane_product;
    reg signed [20:0] lane_sum;
    reg signed [31:0] base;
    reg signed [32:0] total;
    reg current_unsigned;
    reg signed [7:0] current_zero;
    integer lane;

    // One output slot. It must be consumed before accepting another input beat.
    assign s_ready = !rst && !m_valid;

    always @* begin
        current_unsigned = s_first ? s_unsigned : unsigned_mode;
        current_zero = s_first ? s_zero : input_zero;
        lane_sum = 21'sd0;
        lane_input = 9'sd0;
        lane_weight = 8'sd0;
        lane_product = 17'sd0;
        for (lane=0; lane<8; lane=lane+1) begin
            if (current_unsigned)
                lane_input = $signed({1'b0, s_data[lane*8 +: 8]});
            else
                lane_input = $signed({s_data[lane*8+7], s_data[lane*8 +: 8]});
            lane_input = lane_input - $signed({current_zero[7],current_zero});
            lane_weight = $signed(s_weight[lane*8 +: 8]);
            lane_product = lane_input * lane_weight;
            if (s_mask[lane])
                lane_sum = lane_sum + {{4{lane_product[16]}},lane_product};
        end
        base = s_first ? s_bias : accumulator;
        total = $signed({base[31],base}) + $signed({{12{lane_sum[20]}},lane_sum});
    end

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            unsigned_mode <= 1'b0;
            input_zero <= 8'sd0;
            overflow_seen <= 1'b0;
            accumulator <= 32'sd0;
            m_valid <= 1'b0;
            m_data <= 32'sd0;
            m_error <= 1'b0;
        end else begin
            if (m_valid && m_ready)
                m_valid <= 1'b0;
            if (s_valid && s_ready) begin
                if ((!active && !s_first) || (active && s_first) ||
                    (s_first && s_unsigned && s_zero != 8'sd0)) begin
                    // Malformed beat aborts the old group and is itself discarded.
                    active <= 1'b0;
                    unsigned_mode <= 1'b0;
                    input_zero <= 8'sd0;
                    overflow_seen <= 1'b0;
                    accumulator <= 32'sd0;
                    m_valid <= 1'b1;
                    m_data <= 32'sd0;
                    m_error <= 1'b1;
                end else begin
                    if (s_first) begin
                        unsigned_mode <= s_unsigned;
                        input_zero <= s_zero;
                    end
                    accumulator <= total[31:0];
                    overflow_seen <= (s_first ? 1'b0 : overflow_seen) | (total[32] != total[31]);
                    active <= !s_last;
                    if (s_last) begin
                        m_valid <= 1'b1;
                        m_data <= total[31:0];
                        m_error <= (s_first ? 1'b0 : overflow_seen) | (total[32] != total[31]);
                    end
                end
            end
        end
    end
endmodule
