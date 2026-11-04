`timescale 1ns/1ps
module board_clock(input wire clk27,resetn,output wire clk100,locked);
`ifdef RTL_SIM
    reg model_clk=0;
    reg [4:0] lock_delay=0;
    always #5 model_clk=~model_clk;
    always @(posedge clk27 or negedge resetn)
        if(!resetn)lock_delay<=0;else if(!lock_delay[4])lock_delay<=lock_delay+1'b1;
    assign clk100=model_clk;assign locked=resetn && lock_delay[4];
`else
    // Logos2 primitive: 27 * 25 / 6.75 = 100 MHz, VCO = 675 MHz.
    GTP_GPLL #(.CLKIN_FREQ(27.0),.STATIC_RATIOI(1),.STATIC_RATIOM(1),
        .STATIC_RATIOF(25.0),.STATIC_RATIO0(6.75),.STATIC_DUTYF(25),.STATIC_DUTY0(7),
        .INTERNAL_FB("CLKOUTF"),.EXTERNAL_FB("DISABLE"),.BANDWIDTH("OPTIMIZED")) u_pll(
        .CLKIN1(clk27),.CLKIN2(1'b0),.CLKIN_SEL(1'b0),.CLKFB(1'b0),.RST(!resetn),.PLL_PWD(1'b0),
        .CLKOUT0(clk100),.LOCK(locked),.DPS_CLK(1'b0),.DPS_EN(1'b0),.DPS_DIR(1'b0),
        .CLKOUT0_SYN(1'b0),.CLKOUT1_SYN(1'b0),.CLKOUT2_SYN(1'b0),.CLKOUT3_SYN(1'b0),
        .CLKOUT4_SYN(1'b0),.CLKOUT5_SYN(1'b0),.CLKOUT6_SYN(1'b0),.CLKOUTF_SYN(1'b0),
        .APB_CLK(1'b0),.APB_RST_N(1'b0),.APB_ADDR(5'b0),.APB_SEL(1'b0),.APB_EN(1'b0),
        .APB_WRITE(1'b0),.APB_WDATA(16'b0));
`endif
endmodule
