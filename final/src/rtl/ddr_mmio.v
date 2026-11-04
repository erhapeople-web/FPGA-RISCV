module ddr_mmio(input clk,resetn,valid,write,input[31:0]addr,wdata,input[3:0]wstrb,output ready,output reg rvalid,input rready,output reg[31:0]rdata,output reg error,
input available,ddr_fault,output req_valid,input req_ready,output[31:0]req_addr,req_wdata,output[3:0]req_wstrb,output req_write,
input rsp_valid,output rsp_ready,input[31:0]rsp_data,input rsp_error,write_accepted);
reg[31:0]stage_addr,stage_data,addr_q,data_q,result;reg[3:0]stage_mask,mask_q;
reg queued,busy,result_valid,result_error,result_accepted,write_q;
wire accept=valid&&ready;
wire aligned=addr[31:8]==24'h200060&&addr[1:0]==0;
wire submit=accept&&aligned&&write&&wstrb==15&&addr[7:0]==4&&(wdata==1||wdata==2)&&!busy&&!result_valid&&available&&!ddr_fault;
wire pop=accept&&aligned&&!write&&addr[7:0]==32&&result_valid;
assign ready=resetn&&!rvalid;
assign req_valid=resetn&&queued;assign req_addr=addr_q;assign req_wdata=data_q;assign req_wstrb=mask_q;assign req_write=write_q;
assign rsp_ready=resetn&&busy&&!queued&&!result_valid;
always @(posedge clk)begin
 if(!resetn)begin rvalid<=0;rdata<=0;error<=0;stage_addr<=0;stage_data<=0;stage_mask<=0;queued<=0;busy<=0;result_valid<=0;result_error<=0;result_accepted<=0;result<=0;addr_q<=0;data_q<=0;mask_q<=0;write_q<=0;end
 else begin
  if(rvalid&&rready)rvalid<=0;
  if(req_valid&&req_ready)queued<=0;
  if(rsp_valid&&rsp_ready)begin busy<=0;result_valid<=1;result<=rsp_data;result_error<=rsp_error;result_accepted<=write_accepted;end
  if(pop)result_valid<=0;
  if(submit)begin queued<=1;busy<=1;addr_q<=stage_addr;data_q<=stage_data;mask_q<=stage_mask;write_q<=wdata==2;end
  if(accept)begin
   rvalid<=1;rdata<=0;error<=0;
   if(!aligned||(write&&wstrb!=15))error<=1;
   else if(write)case(addr[7:0])
    4:if(!submit)error<=1;
    16:stage_addr<=wdata;20:stage_data<=wdata;
    24:if(|wdata[31:4])error<=1;else stage_mask<=wdata[3:0];
    default:error<=1;
   endcase
   else case(addr[7:0])
    0:rdata<=32'h44440001;
    8:rdata<={26'b0,ddr_fault,!available,(result_valid&&result_accepted),(result_valid&&result_error),result_valid,busy};
    16:rdata<=stage_addr;20:rdata<=stage_data;24:rdata<={28'b0,stage_mask};
    32:if(result_valid)rdata<=result;else error<=1;
    default:error<=1;
   endcase
  end
 end
end
endmodule
