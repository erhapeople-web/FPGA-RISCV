`timescale 1ns/1ps
module tb;
localparam DIV=109;
reg clk=0,dclk=0,resetn=0,rx=1;always #5 clk=~clk;always #4 dclk=~dclk;
wire tx;wire [7:0] gpio;wire av,ar;
integer cycles=0,received=0,j,k,video_count=0;reg [7:0] requests[0:39],expected[0:63],value;
ai_soc #(.FOUR_FUSION(0)) dut(.clk(clk),.resetn(resetn),.uart_rx(rx),.uart_tx(tx),.gpio_out(gpio),
 .dclk(dclk),.global_resetn(resetn),.ddr_init_done(1'b1),.ddr_awvalid(av),.ddr_arvalid(ar),
 .ddr_awready(1'b0),.ddr_arready(1'b0),.ddr_wready(1'b0),.ddr_wlast(1'b0),.ddr_rvalid(1'b0),.ddr_rlast(1'b0),
 .ddr_wid(4'd0),.ddr_rid(4'd0),.ddr_rdata(256'd0),.video_rdata(32'd0),.video_error(1'b0),.video_ready(1'b1));
always @(posedge clk)begin
 cycles=cycles+1;
 if(resetn&&dut.video_access)video_count=video_count+1;
 if(av||ar)$fatal(1,"Unexpected physical DDR request for rejected RUN");
 if(resetn&&gpio[7:4]==4'he)$fatal(1,"Production GPIO failure");
 if(dut.u_memory.u_uart.rx_overrun)$fatal(1,"UART overrun");
 if(cycles>2000000)$fatal(1,"Production UART timeout received=%0d",received);
end
initial forever begin
 @(negedge tx);repeat(DIV+DIV/2)@(negedge clk);
 for(j=0;j<8;j=j+1)begin value[j]=tx;repeat(DIV)@(negedge clk);end
 if(!tx||received>=64||value!==expected[received])$fatal(1,"ACK mismatch index=%0d got=%h",received,value);
 received=received+1;
end
task sendbyte(input [7:0] v);integer b;begin
 @(negedge clk);rx=0;repeat(DIV)@(negedge clk);
 for(b=0;b<8;b=b+1)begin rx=v[b];repeat(DIV)@(negedge clk);end
 rx=1;repeat(DIV)@(negedge clk);
end endtask
initial begin
 $readmemh("uart_requests.hex",requests);$readmemh("uart_expected.hex",expected);
 repeat(10)@(negedge clk);resetn=1;
 wait(dut.u_memory.ram[`APP_STATE_WORD]===32'h41505031&&dut.u_memory.ram[`APP_STATE_WORD+1]===1);
 for(k=0;k<20;k=k+1)sendbyte(requests[k]);wait(received==32);
 for(k=20;k<40;k=k+1)sendbyte(requests[k]);wait(received==64);
 if(video_count!=0)$fatal(1,"Rejected RUN touched camera MMIO");
 $display("PRODUCTION_UART_PASS actual_ROM=1 baud=921600 statuses=2 responses=64 rejected_RUN_video_accesses=%0d cycles=%0d",video_count,cycles);$finish;
end
endmodule
