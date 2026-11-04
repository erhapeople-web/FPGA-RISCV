`timescale 1ns/1ps
// Dedicated pixel PLL. The C1 CPU PLL remains independent and unchanged.
module video_clocks(input wire clk27,resetn,output wire pix_clk,locked);
`ifdef RTL_SIM
    reg model_clk=0;
    reg [4:0] lock_delay=0;
    // 1e9/(2*37.125e6) ns. A simulation oscillator is not a PDS timing proof.
    always #13.468013468 model_clk=~model_clk;
    always @(posedge clk27 or negedge resetn)
        if(!resetn)lock_delay<=0;
        else if(!lock_delay[4])lock_delay<=lock_delay+1'b1;
    assign pix_clk=model_clk;
    assign locked=resetn && lock_delay[4];
`else
    // Same ratios as the reference demo: 27*2*19.25/28=37.125 MHz,
    // VCO=1039.5 MHz. Device placement/PLL legality still require PDS checks.
    GTP_GPLL #(.CLKIN_FREQ(27.0),.STATIC_RATIOI(1),.STATIC_RATIOM(2),
        .STATIC_RATIOF(19.25),.STATIC_RATIO0(28.0),
        .STATIC_DUTYF(19),.STATIC_DUTY0(28),
        .INTERNAL_FB("CLKOUTF"),.EXTERNAL_FB("DISABLE"),.BANDWIDTH("OPTIMIZED")) u_pix_pll(
        .CLKIN1(clk27),.CLKIN2(1'b0),.CLKIN_SEL(1'b0),.CLKFB(1'b0),
        .RST(!resetn),.PLL_PWD(1'b0),.CLKOUT0(pix_clk),.LOCK(locked),
        .DPS_CLK(1'b0),.DPS_EN(1'b0),.DPS_DIR(1'b0),
        .CLKOUT0_SYN(1'b0),.CLKOUT1_SYN(1'b0),.CLKOUT2_SYN(1'b0),
        .CLKOUT3_SYN(1'b0),.CLKOUT4_SYN(1'b0),.CLKOUT5_SYN(1'b0),
        .CLKOUT6_SYN(1'b0),.CLKOUTF_SYN(1'b0),
        .APB_CLK(1'b0),.APB_RST_N(1'b0),.APB_ADDR(5'b0),.APB_SEL(1'b0),
        .APB_EN(1'b0),.APB_WRITE(1'b0),.APB_WDATA(16'b0));
`endif
endmodule
