// Bundled-data mailbox: synchronizers carry events, not changing payload bits.
module ddr_word_cdc(input wire sclk,dclk,global_resetn,cpu_resetn,req_valid,req_write,rsp_ready,
input wire[31:0]req_addr,req_wdata,input wire[3:0]req_wstrb,
output wire req_ready,output reg rsp_valid,rsp_error,write_accepted,output reg[31:0]rsp_data,
output reg d_req_valid,d_req_write,output wire d_rsp_ready,
output reg[31:0]d_req_addr,d_req_wdata,output reg[3:0]d_req_wstrb,
input wire d_req_ready,d_rsp_valid,d_rsp_error,d_write_accepted,input wire[31:0]d_rsp_data);
(* syn_preserve=1, syn_allow_retiming=0 *) reg[1:0] srst,drst,req_sync,ack_sync;
reg request_toggle,ack_toggle,pending,cancelled;
reg[68:0] request_payload;
reg[33:0] response_payload;
reg[1:0] dstate;
always @(posedge sclk or negedge global_resetn)
 if(!global_resetn)srst<=0;else srst<={srst[0],1'b1};
always @(posedge dclk or negedge global_resetn)
 if(!global_resetn)drst<=0;else drst<={drst[0],1'b1};
assign req_ready=srst[1] && cpu_resetn && !pending && !rsp_valid;
assign d_rsp_ready=drst[1] && dstate==2;
// Global reset asserts asynchronously; each domain releases its functional
// flops only from the local two-stage reset synchronizer.
always @(posedge sclk or negedge srst[1])begin
 if(!srst[1])begin ack_sync<=0;request_toggle<=0;pending<=0;cancelled<=0;request_payload<=0;rsp_valid<=0;rsp_error<=0;write_accepted<=0;rsp_data<=0;end
 else begin
  ack_sync<={ack_sync[0],ack_toggle};
  if(!cpu_resetn)begin cancelled<=1;rsp_valid<=0;end
  else if(rsp_valid && rsp_ready)rsp_valid<=0;
  if(req_valid && req_ready)begin
   request_payload<={req_write,req_wstrb,req_addr,req_wdata};
   request_toggle<=~request_toggle;pending<=1;cancelled<=0;
  end
  if(pending && ack_sync[1]==request_toggle)begin
   pending<=0;
   if(cpu_resetn && !cancelled)begin
    rsp_valid<=1;{rsp_error,write_accepted,rsp_data}<=response_payload;
   end
  end
 end
end
always @(posedge dclk or negedge drst[1])begin
 if(!drst[1])begin req_sync<=0;ack_toggle<=0;response_payload<=0;dstate<=0;d_req_valid<=0;d_req_write<=0;d_req_addr<=0;d_req_wdata<=0;d_req_wstrb<=0;end
 else begin
  req_sync<={req_sync[0],request_toggle};
  case(dstate)
   0:if(req_sync[1]!=ack_toggle)begin
    {d_req_write,d_req_wstrb,d_req_addr,d_req_wdata}<=request_payload;
    d_req_valid<=1;dstate<=1;
   end
   1:if(d_req_valid && d_req_ready)begin d_req_valid<=0;dstate<=2;end
   2:if(d_rsp_valid && d_rsp_ready)begin
    response_payload<={d_rsp_error,d_write_accepted,d_rsp_data};
    ack_toggle<=req_sync[1];dstate<=0;
   end
   default:dstate<=0;
  endcase
 end
end
endmodule
