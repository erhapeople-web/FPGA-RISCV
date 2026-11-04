module mac8_mmio(input clk,resetn,valid,write,input[31:0]addr,wdata,input[3:0]wstrb,output ready,output reg rvalid,input rready,output reg[31:0]rdata,output reg error);
reg[63:0]x,w;reg[31:0]bias,cfg;
wire sr,mv,me;wire[31:0]md;
wire accept=valid&&ready;
wire aligned=addr[31:8]==24'h200058 && addr[1:0]==0;
wire submit=accept&&aligned&&write&&wstrb==15&&addr[7:0]==4&&wdata==1&&sr;
wire pop=accept&&aligned&&!write&&addr[7:0]==40&&mv;
assign ready=resetn&&!rvalid;
mac8_stream core(.clk(clk),.rst(!resetn),.s_valid(submit),.s_ready(sr),.s_data(x),.s_weight(w),.s_mask(cfg[7:0]),.s_first(cfg[8]),.s_last(cfg[9]),.s_bias(bias),.s_unsigned(cfg[10]),.s_zero(cfg[23:16]),.m_valid(mv),.m_ready(pop),.m_data(md),.m_error(me));
always @(posedge clk)begin
 if(!resetn)begin rvalid<=0;rdata<=0;error<=0;x<=0;w<=0;bias<=0;cfg<=0;end
 else begin
 if(rvalid&&rready)rvalid<=0;
 if(accept)begin
 rvalid<=1;rdata<=0;error<=0;
 if(!aligned || (write&&wstrb!=15))error<=1;
 else if(write)case(addr[7:0])
 4:if(wdata!=1||!sr)error<=1;
 16:x[31:0]<=wdata;20:x[63:32]<=wdata;24:w[31:0]<=wdata;28:w[63:32]<=wdata;
 32:bias<=wdata;36:if((wdata&32'hff00f800)!=0)error<=1;else cfg<=wdata;
 default:error<=1;
 endcase
 else case(addr[7:0])
 0:rdata<=32'h4d380001;8:rdata<={29'b0,(mv&&me),mv,sr};
 16:rdata<=x[31:0];20:rdata<=x[63:32];24:rdata<=w[31:0];28:rdata<=w[63:32];32:rdata<=bias;36:rdata<=cfg;
 40:if(mv)rdata<=md;else error<=1;
 default:error<=1;
 endcase
 end end
end
endmodule
