module ai_cpu_top(input wire clk,resetn,input wire uart_rx,output wire uart_tx,output wire [7:0] led);
    wire cpu_clk,locked;
    wire release_reset=resetn && locked;
    reg [2:0] reset_pipe;
    board_clock u_clock(.clk27(clk),.resetn(resetn),.clk100(cpu_clk),.locked(locked));
    always @(posedge cpu_clk or negedge release_reset)
        if(!release_reset)reset_pipe<=0;else reset_pipe<={reset_pipe[1:0],1'b1};
    wire cpu_resetn=reset_pipe[2];
    // Fixed competition configuration: all normal ROM/RAM traffic uses Cache/AXI.
    ai_soc #(.CACHE_ENABLE(1),.ICACHE_SET_BITS(9),.CACHE_SET_BITS(8))
        u_soc(.clk(cpu_clk),.resetn(cpu_resetn),.uart_rx(uart_rx),.uart_tx(uart_tx),.gpio_out(led));
endmodule
