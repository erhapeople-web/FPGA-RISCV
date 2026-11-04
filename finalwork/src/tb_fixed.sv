`timescale 1ns/1ps
module tb; parameter DIV=64; reg freeclk=0,dclk=0,clk=0,rst=0,rx=1; always #18.5185 freeclk=~freeclk; always #4 dclk=~dclk; always #5 clk=~clk;
wire tx; test_ddr #(.THERMAL_DIAGNOSTIC(0)) dut(.ref_clk_p(dclk),.ref_clk_n(~dclk),.free_clk(freeclk),.rst_board(rst),.uart_rxd(rx),.uart_txd(tx)); defparam dut.u_soc.u_memory.CLOCK_HZ=115200*DIV;
reg [7:0] req[0:88],expect_bytes[0:63],v; integer count=0,k,b,rounds=0; reg collecting=0;
initial forever begin @(negedge tx); if(collecting) begin repeat(DIV+DIV/2) @(negedge clk); for(b=0;b<8;b=b+1) begin v[b]=tx; repeat(DIV) @(negedge clk); end if(!tx || count>=64 || v!==expect_bytes[count]) $fatal(1,"ACK_FAIL count=%0d got=%h expected=%h",count,v,expect_bytes[count]); count=count+1; end end
task sendbyte(input [7:0] x); integer i; begin @(negedge clk);rx=0;repeat(DIV)@(negedge clk);for(i=0;i<8;i=i+1)begin rx=x[i];repeat(DIV)@(negedge clk);end rx=1;repeat(DIV+4000)@(negedge clk);end endtask
initial begin $readmemh("requests.hex",req);$readmemh("expected.hex",expect_bytes);repeat(2)begin collecting=0;rst=0;rx=1;repeat(100)@(negedge clk);rst=1;wait(dut.cpu_resetn===1'b1); wait(dut.u_soc.u_memory.ram[1]===32'h0); wait(dut.u_soc.u_memory.ram[0]===32'h41505031 && dut.u_soc.u_memory.ram[1]===32'h1);count=0;collecting=1;for(k=0;k<56;k=k+1)sendbyte(req[k]);wait(count==32);for(k=56;k<89;k=k+1)sendbyte(req[k]);wait(count==64);for(k=0;k<13;k=k+1)if(dut.I_ips_ddr_top.memory[k]!==k+1)$fatal(1,"DATA_MISMATCH k=%0d got=%h",k,dut.I_ips_ddr_top.memory[k]);if(dut.I_ips_ddr_top.aw_count!==4)$fatal(1,"AW_COUNT %d",dut.I_ips_ddr_top.aw_count);rounds=rounds+1;$display("PRODUCTION_LOADER_ROUND_PASS %0d",rounds);end $display("PRODUCTION_LOADER_MODEL_PASS");$finish;end
initial begin #50000000;$fatal(1,"WATCHDOG count=%0d state=%h",count,dut.u_soc.u_memory.ram[1]);end
endmodule

