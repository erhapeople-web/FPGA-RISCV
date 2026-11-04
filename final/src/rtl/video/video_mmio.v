// All registers are in the CPU domain. Snapshot payload is stable before ACK
// traverses the two synchronizer stages. Bus writes have exactly one accept pulse.
module video_mmio #(parameter SNAP_TIMEOUT=20000000)(
 input wire clk,resetn,input wire access,write,input wire [7:0] addr,
 input wire [31:0] wdata,input wire [3:0] wstrb,
 output reg [31:0] rdata,output reg error,
 input wire [31:0] live_status,input wire [15:0] camera_id,
 input wire [7:0] config_error,input wire control_applied,
 input wire cam_ack,pix_ack,clear_cam_ack,clear_pix_ack,input wire [127:0] cam_held,pix_held,
 output reg [3:0] control,output reg snap_request,clear_toggle,
 output reg pipeline_reset,config_restart,output wire operation_busy);
 (* async_reg="true" *) reg ca_meta,ca_sync,pa_meta,pa_sync;
 (* async_reg="true" *) reg cc_meta,cc_sync,cp_meta,cp_sync;
 reg busy,apply_busy,clear_busy;reg [3:0] control_shadow;reg [31:0] cmd_seq,snap_seq,sticky,age;
 reg [127:0] cam_snapshot,pix_snapshot;
 reg timed_out;
 assign operation_busy=busy;
 wire cmd_write=write && addr==8'h08 && wstrb[0];
 wire [3:0] cmd=wdata[3:0]; // APPLY=1, SNAPSHOT=2, CLEAR=4, RESET=8
 wire one_cmd=(cmd==1 || cmd==2 || cmd==4 || cmd==8);
 always @* begin
  error=0;rdata=0;
  case(addr)
   8'h00:rdata=32'h43415601;
   8'h04:rdata={28'b0,control_shadow}; // bit0 CAP; bit1 DISPLAY; bit2 TEST; bit3 FREEZE
   8'h08:begin if(!write)error=1;end
   8'h0c:rdata={cmd_seq[27:0],timed_out,2'b0,busy};
   8'h10:rdata=live_status;
   8'h14:rdata={16'b0,camera_id};
   8'h18:rdata={16'd180,16'd320};
   8'h1c:rdata=sticky | {24'b0,config_error};
   8'h20:rdata=cam_snapshot[31:0];
   8'h24:rdata=pix_snapshot[63:32];
   8'h28:rdata=cam_snapshot[63:32];
   8'h2c:rdata=cam_snapshot[95:64];
   8'h30:rdata=pix_snapshot[95:64];
   8'h34:rdata=cam_snapshot[127:96] + pix_snapshot[127:96];
   8'h38:rdata=snap_seq;
   8'h3c:rdata=pix_snapshot[31:0];
   default:error=1;
  endcase
  if(write && addr!=8'h04 && addr!=8'h08 && addr!=8'h1c)error=1;
  if(write && addr==8'h04 && busy)error=1;
  if(cmd_write && (!one_cmd || (busy && cmd!=8)))error=1;
  if(cmd_write && cmd==2 && (live_status[7] || !live_status[2] || !live_status[3]))error=1;
 end
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin
   ca_meta<=0;ca_sync<=0;pa_meta<=0;pa_sync<=0;cc_meta<=0;cc_sync<=0;cp_meta<=0;cp_sync<=0;clear_busy<=0;
   control<=4'b0110;control_shadow<=4'b0110;apply_busy<=0;snap_request<=0;clear_toggle<=0;
   pipeline_reset<=0;config_restart<=0;busy<=0;cmd_seq<=0;snap_seq<=0;
   sticky<=0;age<=0;timed_out<=0;cam_snapshot<=0;pix_snapshot<=0;
  end else begin
   ca_meta<=cam_ack;ca_sync<=ca_meta;pa_meta<=pix_ack;pa_sync<=pa_meta;
   cc_meta<=clear_cam_ack;cc_sync<=cc_meta;cp_meta<=clear_pix_ack;cp_sync<=cp_meta;
   pipeline_reset<=0;config_restart<=0;
   sticky<=sticky | {24'b0,config_error};
   if(busy)begin
    age<=age+1;
    if(!timed_out && ((apply_busy && control_applied) ||
       (clear_busy && cc_sync==clear_toggle && cp_sync==clear_toggle) ||
       (!apply_busy && !clear_busy && ca_sync==snap_request && pa_sync==snap_request)))begin
     if(!apply_busy && !clear_busy)begin cam_snapshot<=cam_held;pix_snapshot<=pix_held;snap_seq<=snap_seq+1;end
     busy<=0;age<=0;
    end else if(age==SNAP_TIMEOUT-1)begin
     // Do not reissue an ambiguous timed-out request. RESET is required.
     timed_out<=1;sticky[8]<=1;age<=age;
    end
   end
   if(access && !error && write)begin
    if(addr==8'h04 && wstrb[0])control_shadow<=wdata[3:0];
    if(addr==8'h1c)begin
     if(wstrb[0])sticky[7:0]<=sticky[7:0]&~wdata[7:0];
     if(wstrb[1])sticky[15:8]<=sticky[15:8]&~wdata[15:8];
    end
    if(cmd_write)begin
     cmd_seq<=cmd_seq+1;
     case(cmd)
      1:begin control<=control_shadow;apply_busy<=1;clear_busy<=0;busy<=1;age<=0;timed_out<=0;end
      2:begin snap_request<=~snap_request;apply_busy<=0;clear_busy<=0;busy<=1;age<=0;timed_out<=0;end
      4:begin clear_toggle<=~clear_toggle;clear_busy<=1;apply_busy<=0;busy<=1;age<=0;timed_out<=0;end
      8:begin
       pipeline_reset<=1;config_restart<=1;busy<=0;apply_busy<=0;clear_busy<=0;timed_out<=0;age<=0;
       snap_request<=0;clear_toggle<=0;cam_snapshot<=0;pix_snapshot<=0;
      end
     endcase
    end
   end
  end
 end
endmodule
