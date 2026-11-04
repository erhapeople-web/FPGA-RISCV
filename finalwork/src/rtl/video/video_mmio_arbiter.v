// Registered CPU video transaction boundary. The CPU holds its request until
// cpu_ready. IDLE captures it, APPLY executes exactly one peripheral pulse,
// and REPLY retains data/error until the original CPU request is accepted.
// Automatic startup keeps its existing direct interface and owns the bus
// through APPLY ACK; it cannot acquire ownership during a CPU transaction.
module video_mmio_arbiter #(
 parameter SETTLE_CYCLES=256,
 parameter APPLY_TIMEOUT=20000000
)(
 input wire clk,resetn,start_ready,
 input wire cpu_access,cpu_write,input wire [7:0] cpu_addr,
 input wire [31:0] cpu_wdata,input wire [3:0] cpu_wstrb,
 output wire cpu_ready,cpu_error,output wire [31:0] cpu_rdata,
 input wire mmio_busy,mmio_error,input wire [31:0] mmio_rdata,
 output wire mmio_access,mmio_write,output wire [7:0] mmio_addr,
 output wire [31:0] mmio_wdata,output wire [3:0] mmio_wstrb,
 output wire auto_done,auto_error
);
 localparam CPU_IDLE=0,CPU_APPLY=1,CPU_REPLY=2;
 reg [1:0] cpu_state;
 reg request_write;
 reg [7:0] request_addr;
 reg [31:0] request_wdata;
 reg [3:0] request_wstrb;
 reg [31:0] reply_data;
 reg reply_error;
 wire auto_access,auto_write,auto_own;
 wire [7:0] auto_addr;wire [31:0] auto_wdata;wire [3:0] auto_wstrb;
 video_autostart #(.SETTLE_CYCLES(SETTLE_CYCLES),.APPLY_TIMEOUT(APPLY_TIMEOUT)) u_auto(
  .clk(clk),.resetn(resetn),.ready(start_ready),.mmio_busy(mmio_busy),
  .cpu_access(cpu_access || cpu_state!=CPU_IDLE),.accepted(auto_access && auto_own),.error(mmio_error),
  .access(auto_access),.write(auto_write),.addr(auto_addr),.wdata(auto_wdata),
  .wstrb(auto_wstrb),.owning(auto_own),.done(auto_done),.failed(auto_error));
 assign cpu_ready=resetn && cpu_state==CPU_REPLY;
 assign cpu_error=reply_error;
 assign cpu_rdata=reply_data;
 assign mmio_access=resetn && (auto_own ? auto_access:cpu_state==CPU_APPLY);
 assign mmio_write=auto_own ? auto_write:request_write;
 assign mmio_addr=auto_own ? auto_addr:request_addr;
 assign mmio_wdata=auto_own ? auto_wdata:request_wdata;
 assign mmio_wstrb=auto_own ? auto_wstrb:request_wstrb;
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin
   cpu_state<=CPU_IDLE;request_write<=0;request_addr<=0;request_wdata<=0;request_wstrb<=0;
   reply_data<=0;reply_error<=0;
  end else case(cpu_state)
   CPU_IDLE:if(cpu_access && !auto_own)begin
    request_write<=cpu_write;request_addr<=cpu_addr;request_wdata<=cpu_wdata;request_wstrb<=cpu_wstrb;
    cpu_state<=CPU_APPLY;
   end
   CPU_APPLY:begin
    reply_data<=mmio_rdata;reply_error<=mmio_error;cpu_state<=CPU_REPLY;
   end
   CPU_REPLY:if(cpu_access && cpu_ready)cpu_state<=CPU_IDLE;
   default:begin cpu_state<=CPU_IDLE;reply_data<=0;reply_error<=1;end
  endcase
 end
endmodule
