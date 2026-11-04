// One startup transaction: CAP|DISPLAY shadow write, then APPLY, then its ACK.
// ready must remain high for SETTLE_CYCLES consecutive CPU clocks. Losing ready
// before APPLY restarts qualification; any MMIO error releases ownership and
// latches failed until reset. No write advances without an accepted transfer.
module video_autostart #(
 parameter SETTLE_CYCLES=256,
 parameter APPLY_TIMEOUT=20000000
)(
 input wire clk,resetn,ready,mmio_busy,cpu_access,accepted,error,
 output wire access,write,output wire [7:0] addr,
 output wire [31:0] wdata,output wire [3:0] wstrb,
 output wire owning,output wire done,output reg failed
);
 localparam S_WAIT=0,S_CTRL=1,S_CMD=2,S_APPLY=3,S_DONE=4,S_FAIL=5;
 localparam SW=(SETTLE_CYCLES<2)?1:$clog2(SETTLE_CYCLES);
 localparam TW=(APPLY_TIMEOUT<2)?1:$clog2(APPLY_TIMEOUT);
 reg [2:0] state;
 reg [SW-1:0] settle;
 reg [TW-1:0] age;
 assign owning=(state==S_CTRL || state==S_CMD || state==S_APPLY);
 assign access=resetn && ready && !mmio_busy && (state==S_CTRL || state==S_CMD);
 assign write=access;
 assign addr=(state==S_CTRL)?8'h04:8'h08;
 assign wdata=(state==S_CTRL)?32'h3:32'h1;
 assign wstrb=4'hf;
 assign done=(state==S_DONE);
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin state<=S_WAIT;settle<=0;age<=0;failed<=0;end
  else begin
   case(state)
    S_WAIT:begin
     age<=0;
     if(!ready)settle<=0;
     else if(settle!=SETTLE_CYCLES-1)settle<=settle+1'b1;
     else if(!mmio_busy && !cpu_access)state<=S_CTRL;
    end
    S_CTRL,S_CMD:begin
     if(!ready)begin state<=S_WAIT;settle<=0;age<=0;end
     else if(access && accepted)begin
      age<=0;
      if(error)begin failed<=1;state<=S_FAIL;end
      else if(state==S_CTRL)state<=S_CMD;
      else state<=S_APPLY;
     end else if(age==APPLY_TIMEOUT-1)begin failed<=1;state<=S_FAIL;end
     else age<=age+1'b1;
    end
    S_APPLY:begin
     if(!ready)begin state<=S_WAIT;settle<=0;age<=0;end
     else if(!mmio_busy)state<=S_DONE;
     else if(age==APPLY_TIMEOUT-1)begin failed<=1;state<=S_FAIL;end
     else age<=age+1'b1;
    end
    S_DONE:state<=S_DONE;
    S_FAIL:state<=S_FAIL;
    default:begin failed<=1;state<=S_FAIL;end
   endcase
  end
 end
endmodule
