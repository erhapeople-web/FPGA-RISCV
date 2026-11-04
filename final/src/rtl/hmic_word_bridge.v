// Isolated single-beat HMIC adapter. resetn must reset the HMIC too.
// cpu_resetn cancels upstream ownership but drains accepted vendor commands.
module hmic_word_bridge(input wire clk,resetn,cpu_resetn,req_valid,req_write,rsp_ready,
input wire [31:0] req_addr,req_wdata,input wire [3:0] req_wstrb,
output wire req_ready,output reg rsp_valid,rsp_error,write_accepted,
output reg [31:0] rsp_data,
output wire [27:0] awaddr,araddr,output wire awvalid,arvalid,
input wire awready,arready,wready,wlast,rvalid,rlast,
input wire [3:0] wid,rid,input wire [255:0] rdata,
output reg [255:0] wdata,output reg [31:0] wstrb,
output wire [3:0] awlen,arlen,output reg fault);
localparam IDLE=0,AW=1,WD=2,AR=3,RD=4,RESP=5;
reg [2:0] state;
reg [27:0] addr_q;reg [2:0] lane_q;reg cancelled;
wire killed=cancelled || !cpu_resetn;
assign req_ready=resetn && cpu_resetn && state==IDLE && !fault && !rvalid && !wready;
assign awaddr=addr_q;assign araddr=addr_q;
assign awlen=0;assign arlen=0;
assign awvalid=resetn && cpu_resetn && state==AW && !fault && !rvalid;
assign arvalid=resetn && cpu_resetn && state==AR && !fault && !wready;
wire read_expected=state==RD || (state==AR && arvalid && arready);
wire write_expected=state==WD || (state==AW && awvalid && awready);
wire unexpected=(rvalid && !read_expected) || (wready && !write_expected);
always @(posedge clk)begin
 if(!resetn)begin state<=IDLE;rsp_valid<=0;rsp_error<=0;write_accepted<=0;rsp_data<=0;
  addr_q<=0;lane_q<=0;cancelled<=0;fault<=0;wdata<=0;wstrb<=0;end
 else begin
  if(!cpu_resetn)begin cancelled<=1;rsp_valid<=0;end
  case(state)
   IDLE:if(req_valid && req_ready)begin
    cancelled<=0;rsp_error<=0;write_accepted<=0;rsp_data<=0;
    addr_q<={req_addr[29:5],3'b000};lane_q<=req_addr[4:2];
    wdata<=({224'b0,req_wdata} << (req_addr[4:2]*32));
    wstrb<=({28'b0,req_wstrb} << (req_addr[4:2]*4));
    if(|req_addr[31:30] || |req_addr[1:0] || (req_write && req_wstrb==0))begin
     rsp_valid<=1;rsp_error<=1;state<=RESP;
    end else state<=req_write ? AW:AR;
   end
   AW:if(!cpu_resetn)state<=IDLE;
      else if(awvalid && awready)state<=WD;
   AR:if(!cpu_resetn)state<=IDLE;
      else if(arvalid && arready)state<=RD;
   RESP:if(!cpu_resetn || (rsp_valid && rsp_ready))begin rsp_valid<=0;state<=IDLE;end
   default:begin end
  endcase
  // Consume every HMIC beat without waiting on CPU response readiness.
  if(write_expected && wready)begin
   if(!wlast || wid!=0)fault<=1;
   if(killed)state<=IDLE;
   else begin state<=RESP;rsp_valid<=1;rsp_error<=!wlast || wid!=0 || fault || unexpected;write_accepted<=wlast && wid==0 && !fault && !unexpected;end
  end
  if(read_expected && rvalid)begin
   if(!rlast || rid!=0)fault<=1;
   if(killed)state<=IDLE;
   else begin state<=RESP;rsp_valid<=1;rsp_error<=!rlast || rid!=0 || fault || unexpected;rsp_data<=rdata[lane_q*32+:32];end
  end
  // Out-of-contract data is never silently allowed to poison a later command.
  // Keep a pre-existing CPU reply stable; fault blocks all subsequent work.
  if(unexpected)begin
   fault<=1;
   if(state==AW || state==AR)begin
    if(killed)state<=IDLE;
    else begin state<=RESP;rsp_valid<=1;rsp_error<=1;write_accepted<=0;end
   end
  end
 end
end
endmodule
