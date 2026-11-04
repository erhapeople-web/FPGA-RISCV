module ddr_path(input clk,dclk,global_resetn,cpu_resetn,init_done,
input req_valid,req_write,rsp_ready,input[31:0]req_addr,req_wdata,input[3:0]req_wstrb,
output req_ready,rsp_valid,rsp_error,write_accepted,output[31:0]rsp_data,output available,ddr_fault,
output[27:0]awaddr,araddr,output awvalid,arvalid,input awready,arready,wready,wlast,rvalid,rlast,
input[3:0]wid,rid,input[255:0]rdata,output[255:0]wdata,output[31:0]wstrb,output[3:0]awlen,arlen);
(* syn_preserve=1, syn_allow_retiming=0 *)reg[1:0]drst,srst,avail_sync,fault_sync;
reg seen,quarantine;wire fault;
always @(posedge dclk or negedge global_resetn)if(!global_resetn)drst<=0;else drst<={drst[0],1'b1};
always @(posedge clk or negedge global_resetn)if(!global_resetn)srst<=0;else srst<={srst[0],1'b1};
always @(posedge dclk or negedge drst[1])if(!drst[1])begin seen<=0;quarantine<=0;end
else begin if(init_done)seen<=1;if((seen&&!init_done)||fault)quarantine<=1;end
wire active=drst[1]&&init_done&&!quarantine&&!fault;
always @(posedge clk or negedge srst[1])if(!srst[1])begin avail_sync<=0;fault_sync<=0;end else begin avail_sync<={avail_sync[0],active};fault_sync<={fault_sync[0],(quarantine||fault)};end
assign available=avail_sync[1];assign ddr_fault=fault_sync[1];
wire dv,dr,dw,rv,rr,re,wa;wire[31:0]da,dd,rd;wire[3:0]ds;
ddr_word_cdc mailbox(.sclk(clk),.dclk(dclk),.global_resetn(global_resetn),.cpu_resetn(cpu_resetn),
.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),.rsp_data(rsp_data),.write_accepted(write_accepted),
.d_req_valid(dv),.d_req_ready(dr),.d_req_write(dw),.d_req_addr(da),.d_req_wdata(dd),.d_req_wstrb(ds),.d_rsp_valid(rv),.d_rsp_ready(rr),.d_rsp_error(re),.d_rsp_data(rd),.d_write_accepted(wa));
wire bridge_ready,raw_awvalid,raw_arvalid;assign dr=bridge_ready&&active;
/* An init drop also blocks a previously queued, not-yet-accepted address.
   Quarantine prevents resumption after init returns; only cold reset recovers. */
assign awvalid=raw_awvalid&&active;assign arvalid=raw_arvalid&&active;
hmic_word_bridge bridge(.clk(dclk),.resetn(drst[1]),.cpu_resetn(1'b1),.req_valid(dv&&active),.req_ready(bridge_ready),.req_write(dw),.req_addr(da),.req_wdata(dd),.req_wstrb(ds),
.rsp_valid(rv),.rsp_ready(rr),.rsp_error(re),.rsp_data(rd),.write_accepted(wa),
.awaddr(awaddr),.araddr(araddr),.awvalid(raw_awvalid),.arvalid(raw_arvalid),.awready(awready&&active),.arready(arready&&active),.wready(wready),.wlast(wlast),.rvalid(rvalid),.rlast(rlast),.wid(wid),.rid(rid),.rdata(rdata),.wdata(wdata),.wstrb(wstrb),.awlen(awlen),.arlen(arlen),.fault(fault));
endmodule
