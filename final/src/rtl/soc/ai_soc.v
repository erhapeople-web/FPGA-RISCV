// Independently authored SoC integration. Fair I/D arbitration precedes AXI.
module ai_soc #(parameter THERMAL_OBSERVE=0, parameter LOOP_BUFFER=1, CACHE_ENABLE=1, CACHE_SET_BITS=8, ICACHE_SET_BITS=9, PREDICT=1,
 parameter LOAD_PRELOOKUP=1, LOAD_PRELOOKUP_REUSE=1,
 parameter WIDE_FRONT=1, FUSION=1, FOUR_FUSION=1, TRIPLE_BRANCH=1, DUAL_ISSUE=1, FETCH_WORDS=4)(
 input wire clk,resetn,uart_rx,output wire uart_tx,output wire [7:0] gpio_out,
 output wire diag_loader_wait_seen,
 input wire dclk,global_resetn,ddr_init_done,
 output wire[27:0]ddr_awaddr,ddr_araddr,output wire ddr_awvalid,ddr_arvalid,
 input wire ddr_awready,ddr_arready,ddr_wready,ddr_wlast,ddr_rvalid,ddr_rlast,
 input wire[3:0]ddr_wid,ddr_rid,input wire[255:0]ddr_rdata,
 output wire[255:0]ddr_wdata,output wire[31:0]ddr_wstrb,output wire[3:0]ddr_awlen,ddr_arlen,
 output wire video_access,video_write,output wire[7:0]video_addr,
 output wire[31:0]video_wdata,output wire[3:0]video_wstrb,
 input wire[31:0]video_rdata,input wire video_error,input wire video_ready);
 // Fixed Cache/AXI architecture. The former TCM bypass ports are removed.
 wire iv,ir,irv,irr,ie,dv,dr,drv,drr,de,dw;
 wire [31:0] ia,idata,idata_hi,idata2,idata3,da,dd,ddata;wire [3:0] ds;
 wire ti,si,ei;
 wire retire_valid3,retire_we3;wire [31:0] retire_pc3,retire_inst3,retire_data3;wire [4:0] retire_rd3;
 wire retire_valid,retire_we,retire_valid1,retire_valid2,retire_we1,retire_we2;
 wire [31:0] retire_pc1,retire_pc2,retire_inst1,retire_inst2,retire_data1,retire_data2;
 wire [4:0] retire_rd1,retire_rd2;wire [2:0] retire_count;wire [31:0] retire_pc,retire_inst,retire_data;wire [4:0] retire_rd,stage_valid;
 // Diagnostic observation only. PC 09fch is the actual production-ROM UART
 // status LW in platform_receive; the frozen ROM is checked before building.
 generate if(THERMAL_OBSERVE)begin:g_thermal_observation
   reg [3:0] poll_hits;reg wait_seen;
   wire poll_retired=(retire_valid && retire_pc==32'h000009fc && retire_inst==32'h00062783) ||
       (retire_valid1 && retire_pc1==32'h000009fc && retire_inst1==32'h00062783) ||
       (retire_valid2 && retire_pc2==32'h000009fc && retire_inst2==32'h00062783) ||
       (retire_valid3 && retire_pc3==32'h000009fc && retire_inst3==32'h00062783);
   always @(posedge clk)begin
     if(!resetn)begin poll_hits<=0;wait_seen<=0;end
     else if(poll_retired && !wait_seen)begin
       if(poll_hits==15)wait_seen<=1;else poll_hits<=poll_hits+1'b1;
     end
   end
   assign diag_loader_wait_seen=wait_seen;
 end else begin:g_no_thermal_observation
   assign diag_loader_wait_seen=1'b0;
 end endgenerate
 wire [63:0] cycles,retired;wire [31:0] branches,mispredicts,hazards,mem_wait,ic_access,ic_miss,dc_access,dc_miss;
 wire pv,pc,pt,pr,prv,ph;wire [31:0] pa,pra,pdata;
 rv32_core #(.LOOP_BUFFER(LOOP_BUFFER),.PREDICT(PREDICT),.PRELOOKUP(LOAD_PRELOOKUP && CACHE_ENABLE),.WIDE_FRONT(WIDE_FRONT && CACHE_ENABLE),.FUSION(FUSION),.FOUR_FUSION(FOUR_FUSION),.TRIPLE_BRANCH(TRIPLE_BRANCH),.DUAL_ISSUE(DUAL_ISSUE),.FETCH_WORDS(FETCH_WORDS)) u_cpu(.clk(clk),.resetn(resetn),
  .i_valid(iv),.i_ready(ir),.i_addr(ia),.i_rvalid(irv),.i_rready(irr),.i_rdata(idata),.i_rdata_hi(idata_hi),.i_rdata2(idata2),.i_rdata3(idata3),.i_error(ie),
  .d_valid(dv),.d_ready(dr),.d_addr(da),.d_wdata(dd),.d_write(dw),.d_wstrb(ds),
  .d_rvalid(drv),.d_rready(drr),.d_rdata(ddata),.d_error(de),
  .d_probe_valid(pv),.d_probe_commit(pc),.d_probe_take(pt),.d_probe_addr(pa),
  .d_probe_ready(pr),.d_probe_result_valid(prv),.d_probe_hit(ph),.d_probe_result_addr(pra),.d_probe_data(pdata),
  .irq_timer(ti),.irq_software(si),.irq_external(ei),
  .retire_valid(retire_valid),.retire_pc(retire_pc),.retire_inst(retire_inst),.retire_data(retire_data),
  .retire_rd(retire_rd),.retire_we(retire_we),.stage_valid(stage_valid),
  .retire_valid1(retire_valid1),.retire_valid2(retire_valid2),.retire_we1(retire_we1),.retire_we2(retire_we2),
  .retire_pc1(retire_pc1),.retire_pc2(retire_pc2),.retire_inst1(retire_inst1),.retire_inst2(retire_inst2),
  .retire_data1(retire_data1),.retire_data2(retire_data2),.retire_rd1(retire_rd1),.retire_rd2(retire_rd2),.retire_count(retire_count),
  .retire_valid3(retire_valid3),.retire_we3(retire_we3),.retire_pc3(retire_pc3),.retire_inst3(retire_inst3),.retire_data3(retire_data3),.retire_rd3(retire_rd3),
  .cycles(cycles),.retired(retired),.branch_count(branches),.mispredict_count(mispredicts),.hazard_cycles(hazards),.memory_cycles(mem_wait));
 wire icv,icr,icw,icl,icrr,dcv,dcr,dcw,dcl,dcrr;
 wire [31:0] ica,icd,dca,dcd;wire [3:0] ics,dcs;
 wire cv,cr,rv,rr,re,rl;wire [31:0] rd;
 reg owner,last_owner;
 wire choose_d=dcv && (!icv || !last_owner);
 assign cv=icv || dcv;
 assign icr=cr && !choose_d;assign dcr=cr && choose_d;
 assign rr=owner ? dcrr:icrr;
 always @(posedge clk)if(!resetn)begin owner<=0;last_owner<=1;end
 else if(cv && cr)begin owner<=choose_d;last_owner<=choose_d;end
 // Cache-only mode uses the cache response slot directly. Its I-cache can
 // accept the next request on the preceding response edge; a second external
 // pending token would unnecessarily insert a bubble on every hit.
 wire ic_ready,ic_valid,ic_error;wire [31:0] ic_data0,ic_data1,ic_data2,ic_data3;
 assign ir=ic_ready;
 assign irv=ic_valid;
 assign idata=ic_data0;
 assign idata_hi=ic_data1;
 assign idata2=ic_data2;
 assign idata3=ic_data3;
 assign ie=ic_error;
 // Preserve the existing one-outstanding data handshake cycle for cycle.
 reg dt_external_pending;
 wire dc_ready,dc_valid,dc_error;wire [31:0] dc_data;
 wire cache_pr,cache_prv,cache_ph;wire [31:0] cache_pra,cache_pdata;
 assign dr=!dt_external_pending && dc_ready;
 assign drv=dt_external_pending && dc_valid;
 assign ddata=dc_data;
 assign de=dc_error;
 assign pr=cache_pr;
 assign prv=cache_prv;
 assign ph=cache_ph;
 assign pra=cache_pra;
 assign pdata=cache_pdata;
 always @(posedge clk)begin
     if(!resetn)dt_external_pending<=0;
     else begin
         if(dv && dr)dt_external_pending<=1;
         if(dt_external_pending && dc_valid && drr)dt_external_pending<=0;
     end
 end
 cache_2way #(.SET_BITS(ICACHE_SET_BITS),.INSTRUCTION(1),.ENABLE(CACHE_ENABLE),.WIDE_FETCH(WIDE_FRONT),.FETCH_WORDS(FETCH_WORDS)) u_icache(
  .clk(clk),.resetn(resetn),.req_valid(iv),.req_ready(ic_ready),.req_addr(ia),.req_wdata(32'b0),.req_write(1'b0),.req_wstrb(4'b0),
  .probe_valid(1'b0),.probe_commit(1'b0),.probe_take(1'b0),.probe_addr(32'b0),
  .probe_ready(),.probe_result_valid(),.probe_hit(),.probe_result_addr(),.probe_data(),
  .rsp_valid(ic_valid),.rsp_ready(irr),.rsp_data(ic_data0),.rsp_data_hi(ic_data1),.rsp_data2(ic_data2),.rsp_data3(ic_data3),.rsp_error(ic_error),
  .cmd_valid(icv),.cmd_ready(icr),.cmd_addr(ica),.cmd_wdata(icd),.cmd_write(icw),.cmd_line(icl),.cmd_wstrb(ics),
  .ret_valid(rv && !owner),.ret_ready(icrr),.ret_data(rd),.ret_error(re),.ret_last(rl),.accesses(ic_access),.misses(ic_miss));
 cache_2way #(.SET_BITS(CACHE_SET_BITS),.ENABLE(CACHE_ENABLE),
  .PRELOOKUP(LOAD_PRELOOKUP),.PRELOOKUP_REUSE(LOAD_PRELOOKUP_REUSE)) u_dcache(
  .clk(clk),.resetn(resetn),.req_valid(dv && !dt_external_pending),.req_ready(dc_ready),.req_addr(da),.req_wdata(dd),.req_write(dw),.req_wstrb(ds),
  .probe_valid(pv),.probe_commit(pc),.probe_take(pt),.probe_addr(pa),
  .probe_ready(cache_pr),.probe_result_valid(cache_prv),.probe_hit(cache_ph),.probe_result_addr(cache_pra),.probe_data(cache_pdata),
  .rsp_valid(dc_valid),.rsp_ready(drr && dt_external_pending),.rsp_data(dc_data),.rsp_error(dc_error),
  .cmd_valid(dcv),.cmd_ready(dcr),.cmd_addr(dca),.cmd_wdata(dcd),.cmd_write(dcw),.cmd_line(dcl),.cmd_wstrb(dcs),
  .ret_valid(rv && owner),.ret_ready(dcrr),.ret_data(rd),.ret_error(re),.ret_last(rl),.accesses(dc_access),.misses(dc_miss));
 wire arvalid;
 wire arready;
 wire [31:0] araddr;
 wire [7:0] arlen;
 wire [2:0] arsize;
 wire [1:0] arburst;
 wire rvalid;
 wire rready;
 wire [31:0] rdata;
 wire [1:0] rresp;
 wire rlast;
 wire awvalid;
 wire awready;
 wire [31:0] awaddr;
 wire [7:0] awlen;
 wire [2:0] awsize;
 wire [1:0] awburst;
 wire wvalid;
 wire wready;
 wire [31:0] wdata;
 wire [3:0] wstrb;
 wire wlast;
 wire bvalid;
 wire bready;
 wire [1:0] bresp;
 axi_master u_master(.clk(clk),.resetn(resetn),.cmd_valid(cv),.cmd_ready(cr),
  .cmd_addr(choose_d ? dca:ica),.cmd_wdata(dcd),.cmd_write(choose_d && dcw),.cmd_line(choose_d ? dcl:icl),.cmd_wstrb(dcs),
  .ret_valid(rv),.ret_ready(rr),.ret_data(rd),.ret_error(re),.ret_last(rl),
  .arvalid(arvalid),
  .arready(arready),
  .araddr(araddr),
  .arlen(arlen),
  .arsize(arsize),
  .arburst(arburst),
  .rvalid(rvalid),
  .rready(rready),
  .rdata(rdata),
  .rresp(rresp),
  .rlast(rlast),
  .awvalid(awvalid),
  .awready(awready),
  .awaddr(awaddr),
  .awlen(awlen),
  .awsize(awsize),
  .awburst(awburst),
  .wvalid(wvalid),
  .wready(wready),
  .wdata(wdata),
  .wstrb(wstrb),
  .wlast(wlast),
  .bvalid(bvalid),
  .bready(bready),
  .bresp(bresp));
 wire lv,lr,lw,lrv,lrr,le;wire [31:0] la,ld,lrd;wire [3:0] ls;
 axi_slave u_slave(.clk(clk),.resetn(resetn),
  .mem_valid(lv),.mem_ready(lr),.mem_write(lw),.mem_addr(la),.mem_wdata(ld),.mem_wstrb(ls),
  .mem_rvalid(lrv),.mem_rready(lrr),.mem_rdata(lrd),.mem_error(le),
  .arvalid(arvalid),
  .arready(arready),
  .araddr(araddr),
  .arlen(arlen),
  .arsize(arsize),
  .arburst(arburst),
  .rvalid(rvalid),
  .rready(rready),
  .rdata(rdata),
  .rresp(rresp),
  .rlast(rlast),
  .awvalid(awvalid),
  .awready(awready),
  .awaddr(awaddr),
  .awlen(awlen),
  .awsize(awsize),
  .awburst(awburst),
  .wvalid(wvalid),
  .wready(wready),
  .wdata(wdata),
  .wstrb(wstrb),
  .wlast(wlast),
  .bvalid(bvalid),
  .bready(bready),
  .bresp(bresp));
 wire mlv,mlr,mlrv,mlrr,mle;wire[31:0]mlrd;
 wire av,ar,arv,arr,ae;wire[31:0]ard;
 wire qv,qr,qrv,qrr,qe;wire[31:0]qrd;
 reg local_busy;reg[1:0]local_target;
 wire select_ai=la[31:8]==24'h200058;
 wire select_ddr=la[31:8]==24'h200060;
 assign av=lv&&!local_busy&&select_ai;
 assign qv=lv&&!local_busy&&select_ddr;
 assign mlv=lv&&!local_busy&&!select_ai&&!select_ddr;
 assign lr=!local_busy&&(select_ai?ar:select_ddr?qr:mlr);
 assign lrv=local_busy&&(local_target==1?arv:local_target==2?qrv:mlrv);
 assign lrd=local_target==1?ard:local_target==2?qrd:mlrd;assign le=local_target==1?ae:local_target==2?qe:mle;
 assign arr=local_busy&&local_target==1&&lrr;
 assign qrr=local_busy&&local_target==2&&lrr;
 assign mlrr=local_busy&&local_target==0&&lrr;
 always @(posedge clk)if(!resetn)begin local_busy<=0;local_target<=0;end
 else begin if(lrv&&lrr)local_busy<=0;if(lv&&lr)begin local_busy<=1;local_target<=select_ai?1:select_ddr?2:0;end end
 wire dvv,drrr,dww,rrv,rrr,rre,waa,available,ddr_fault;wire[31:0]daa,ddd,rrd;wire[3:0]dss;
 ddr_mmio u_ddr(.clk(clk),.resetn(resetn),.valid(qv),.ready(qr),.write(lw),.addr(la),.wdata(ld),.wstrb(ls),.rvalid(qrv),.rready(qrr),.rdata(qrd),.error(qe),
 .available(available),.ddr_fault(ddr_fault),.req_valid(dvv),.req_ready(drrr),.req_write(dww),.req_addr(daa),.req_wdata(ddd),.req_wstrb(dss),.rsp_valid(rrv),.rsp_ready(rrr),.rsp_error(rre),.rsp_data(rrd),.write_accepted(waa));
 ddr_path u_ddr_path(.clk(clk),.dclk(dclk),.global_resetn(global_resetn),.cpu_resetn(resetn),.init_done(ddr_init_done),
 .req_valid(dvv),.req_ready(drrr),.req_write(dww),.req_addr(daa),.req_wdata(ddd),.req_wstrb(dss),.rsp_valid(rrv),.rsp_ready(rrr),.rsp_error(rre),.rsp_data(rrd),.write_accepted(waa),.available(available),.ddr_fault(ddr_fault),
 .awaddr(ddr_awaddr),.araddr(ddr_araddr),.awvalid(ddr_awvalid),.arvalid(ddr_arvalid),.awready(ddr_awready),.arready(ddr_arready),.wready(ddr_wready),.wlast(ddr_wlast),.rvalid(ddr_rvalid),.rlast(ddr_rlast),.wid(ddr_wid),.rid(ddr_rid),.rdata(ddr_rdata),.wdata(ddr_wdata),.wstrb(ddr_wstrb),.awlen(ddr_awlen),.arlen(ddr_arlen));
 mac8_mmio u_mac8(.clk(clk),.resetn(resetn),.valid(av),.ready(ar),.write(lw),.addr(la),.wdata(ld),.wstrb(ls),.rvalid(arv),.rready(arr),.rdata(ard),.error(ae));
 local_memory u_memory(.clk(clk),.resetn(resetn),
  .valid(mlv),.ready(mlr),.write(lw),.addr(la),.wdata(ld),.wstrb(ls),
  .rvalid(mlrv),.rready(mlrr),.rdata(mlrd),.error(mle),.uart_rx(uart_rx),.uart_tx(uart_tx),.gpio_out(gpio_out),
  .irq_timer(ti),.irq_software(si),.irq_external(ei),.cpu_cycles(cycles),.cpu_retired(retired),
  .branches(branches),.mispredicts(mispredicts),.hazards(hazards),.mem_wait(mem_wait),
  .ic_access(ic_access),.ic_miss(ic_miss),.dc_access(dc_access),.dc_miss(dc_miss),
  .video_access(video_access),.video_write(video_write),.video_addr(video_addr),
  .video_wdata(video_wdata),.video_wstrb(video_wstrb),.video_rdata(video_rdata),.video_error(video_error),.video_ready(video_ready));
endmodule
