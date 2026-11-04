`timescale 1ns/1ps
// Digital-logic reset only. The raw DDR reset must still start the PLL chain;
// feeding this output back into that chain would deadlock the destination clk.
module thermal_ddr_reset_release(
    input wire clk,
    input wire raw_resetn,
    output wire logic_resetn
);
    reg release_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg release_sync_q=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge raw_resetn)begin
        // Positive qualification makes unknown reset fail closed in RTL sim.
        // It is ordinary active-low async reset hardware, not an X detector.
        if(raw_resetn)begin
            release_meta<=1'b1;
            release_sync_q<=release_meta;
        end else begin
            release_meta<=1'b0;
            release_sync_q<=1'b0;
        end
    end
    // No combinational raw-reset bypass to a functional reset consumer.
    assign logic_resetn=release_sync_q;
endmodule
