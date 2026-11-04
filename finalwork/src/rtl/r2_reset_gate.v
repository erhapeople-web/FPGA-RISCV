module r2_reset_gate(input wire cpu_clk,system_resetn,ddr_init_async,output wire cpu_resetn,output reg init_fault);
(* syn_preserve=1, syn_allow_retiming=0 *) reg [1:0] init_sync;
reg init_seen;
always @(posedge cpu_clk or negedge system_resetn) begin
 if(!system_resetn) begin init_sync<=0;init_seen<=0;init_fault<=0;end
 else begin
  init_sync<={init_sync[0],ddr_init_async};
  if(init_sync[1]) init_seen<=1;
  if(init_seen && !init_sync[1]) init_fault<=1;
 end
end
assign cpu_resetn=system_resetn && init_sync[1] && !init_fault;
endmodule
