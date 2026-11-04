`timescale 1ns/1ps
// Eight exact integer lane products followed by a checked, wrapped INT32 sum.
// See README.md for grouping/error/reset and ready/valid contract.
//
// The product stage accepts at most one pending beat. Its registered products
// feed the balanced reduction/accumulator stage on the following edge. No new
// beat is accepted until that stage commits, so group state never needs bypass.
// Final/error responses use one held output slot; the consumer may stall it.
module mac8_stream (
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
    // Resolve first/continuing-beat mode before their own products, then
    // select the product. s_first no longer precedes subtract and multiply.
    wire signed [16:0] first_product[0:7] /* synthesis syn_keep=1 */;
    wire signed [16:0] continuing_product[0:7] /* synthesis syn_keep=1 */;
    genvar product_lane;
    generate for(product_lane=0;product_lane<8;product_lane=product_lane+1)begin:g_parallel_product
        wire signed [8:0] first_input = (s_unsigned ?
            $signed({1'b0,s_data[8*product_lane+:8]}) :
            $signed({s_data[8*product_lane+7],s_data[8*product_lane+:8]})) -
            $signed({s_zero[7],s_zero});
        wire signed [8:0] continuing_input = (unsigned_mode ?
            $signed({1'b0,s_data[8*product_lane+:8]}) :
            $signed({s_data[8*product_lane+7],s_data[8*product_lane+:8]})) -
            $signed({input_zero[7],input_zero});
        wire signed [7:0] weight = $signed(s_weight[8*product_lane+:8]);
        assign first_product[product_lane]=first_input*weight;
        assign continuing_product[product_lane]=continuing_input*weight;
    end endgenerate
    reg product_valid /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg signed [16:0] product_q [0:7] /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg first_q,last_q,bad_q,unsigned_q;
    reg signed [7:0] zero_q;
    reg signed [31:0] bias_q;
    reg signed [20:0] ext [0:7];
    reg signed [20:0] sum01, sum23, sum45, sum67, sum0123, sum4567;
    reg signed [20:0] lane_sum;
    reg signed [31:0] base;
    reg signed [32:0] total;
    integer lane,reset_lane,capture_lane;

    // The pending slot and output slot are mutually exclusive. Deliberately
    // leave a commit edge between accepted beats to serialize accumulation.
    assign s_ready = !rst && !product_valid && !m_valid;

    always @* begin
        for (lane=0; lane<8; lane=lane+1) begin
            ext[lane] = {{4{product_q[lane][16]}},product_q[lane]};
        end
        // Balanced reduction: three adder levels instead of eight serial steps.
        sum01   = ext[0] + ext[1];
        sum23   = ext[2] + ext[3];
        sum45   = ext[4] + ext[5];
        sum67   = ext[6] + ext[7];
        sum0123 = sum01 + sum23;
        sum4567 = sum45 + sum67;
        lane_sum = sum0123 + sum4567;
        base = first_q ? bias_q : accumulator;
        total = $signed({base[31],base}) + $signed({{12{lane_sum[20]}},lane_sum});
    end

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            unsigned_mode <= 1'b0;
            input_zero <= 8'sd0;
            overflow_seen <= 1'b0;
            accumulator <= 32'sd0;
            product_valid <= 1'b0;
            first_q <= 1'b0;
            last_q <= 1'b0;
            bad_q <= 1'b0;
            unsigned_q <= 1'b0;
            zero_q <= 8'sd0;
            bias_q <= 32'sd0;
            for (reset_lane=0; reset_lane<8; reset_lane=reset_lane+1)
                product_q[reset_lane] <= 17'sd0;
            m_valid <= 1'b0;
            m_data <= 32'sd0;
            m_error <= 1'b0;
        end else begin
            if (m_valid && m_ready)
                m_valid <= 1'b0;
            if (s_valid && s_ready) begin
                product_valid <= 1'b1;
                first_q <= s_first;
                last_q <= s_last;
                bad_q <= (!active && !s_first) || (active && s_first) ||
                         (s_first && s_unsigned && s_zero != 8'sd0);
                unsigned_q <= s_unsigned;
                zero_q <= s_zero;
                bias_q <= s_bias;
                for (capture_lane=0; capture_lane<8; capture_lane=capture_lane+1)
                    product_q[capture_lane] <= !s_mask[capture_lane] ? 17'sd0 :
                        s_first ? first_product[capture_lane] : continuing_product[capture_lane];
            end
            if (product_valid) begin
                product_valid <= 1'b0;
                if (bad_q) begin
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
                    if (first_q) begin
                        unsigned_mode <= unsigned_q;
                        input_zero <= zero_q;
                    end
                    accumulator <= total[31:0];
                    overflow_seen <= (first_q ? 1'b0 : overflow_seen) | (total[32] != total[31]);
                    active <= !last_q;
                    if (last_q) begin
                        m_valid <= 1'b1;
                        m_data <= total[31:0];
                        m_error <= (first_q ? 1'b0 : overflow_seen) | (total[32] != total[31]);
                    end
                end
            end
        end
    end
endmodule
