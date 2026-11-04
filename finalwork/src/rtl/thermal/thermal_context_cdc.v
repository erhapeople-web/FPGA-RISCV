`timescale 1ns/1ps
// Coherent bundled-data context snapshot, independent of CPU functional reset.
// Both reset inputs flush the complete protocol. Each domain synchronizes its
// release; a stopped source cannot create a new acknowledged sample.
// Both release flops use raw asynchronous assertion; all business state uses
// the local release_q, so its asynchronous reset deasserts synchronously.
// A request crosses two src synchronizer stages before source capture. An ack
// crosses two dst stages, is observed by the FSM, then waits one extra dst edge.
// MAX_AGE_CYCLES bounds time since dst publication, not since physical events;
// the source-capture-to-publication handshake latency is additional.
module thermal_context_cdc #(
    parameter REQUEST_INTERVAL=1000,
    parameter MAX_AGE_CYCLES=4096
)(input wire src_clk,src_resetn,input wire [31:0] src_data,
  input wire dst_clk,dst_resetn,output wire [31:0] dst_data);
    wire link_resetn=src_resetn && dst_resetn;
    reg src_release_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg src_release_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg dst_release_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg dst_release_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge src_clk or negedge link_resetn)
        if(!link_resetn)begin src_release_meta<=0;src_release_q<=0;end
        else begin src_release_meta<=1;src_release_q<=src_release_meta;end
    always @(posedge dst_clk or negedge link_resetn)
        if(!link_resetn)begin dst_release_meta<=0;dst_release_q<=0;end
        else begin dst_release_meta<=1;dst_release_q<=dst_release_meta;end

    reg request_toggle /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg request_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg request_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ack_toggle /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg [31:0] held_data /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge src_clk or negedge src_release_q)begin
        if(!src_release_q)begin request_meta<=0;request_sync_q<=0;ack_toggle<=0;held_data<=0;end
        else begin
            request_meta<=request_toggle;request_sync_q<=request_meta;
            if(request_sync_q!=ack_toggle)begin held_data<=src_data;ack_toggle<=request_sync_q;end
        end
    end

    reg ack_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ack_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg src_ready_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg src_ready_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg [31:0] dst_value /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg data_valid;
    localparam INTERVAL=(REQUEST_INTERVAL<1)?1:REQUEST_INTERVAL;
    localparam AGE_LIMIT=(MAX_AGE_CYCLES<1)?1:MAX_AGE_CYCLES;
    localparam IW=(INTERVAL<2)?1:$clog2(INTERVAL);
    localparam AW=(AGE_LIMIT<2)?1:$clog2(AGE_LIMIT+1);
    reg [IW-1:0] interval_count;
    reg [AW-1:0] age_count;
    reg [1:0] state;
    localparam WAIT_READY=0,WAIT_ACK=1,SETTLE=2,IDLE=3;
    // Bit31 is validity of this protocol epoch, never the input's bit31.
    assign dst_data={data_valid,dst_value[30:0]};
    always @(posedge dst_clk or negedge dst_release_q)begin
        if(!dst_release_q)begin
            ack_meta<=0;ack_sync_q<=0;src_ready_meta<=0;src_ready_sync_q<=0;
            request_toggle<=0;dst_value<=0;data_valid<=0;state<=WAIT_READY;
            interval_count<=0;age_count<=AGE_LIMIT;
        end else begin
            ack_meta<=ack_toggle;ack_sync_q<=ack_meta;
            src_ready_meta<=src_release_q;src_ready_sync_q<=src_ready_meta;
            if(age_count<AGE_LIMIT)age_count<=age_count+1'b1;
            if(age_count>=AGE_LIMIT-1)data_valid<=0;
            if(!src_ready_sync_q)begin
                request_toggle<=0;data_valid<=0;state<=WAIT_READY;interval_count<=0;
            end else case(state)
              WAIT_READY:begin request_toggle<=!request_toggle;state<=WAIT_ACK;end
              WAIT_ACK:if(ack_sync_q==request_toggle)state<=SETTLE;
              // Keep held_data stable through one more complete dst edge.
              SETTLE:begin dst_value<=held_data;data_valid<=1;age_count<=0;interval_count<=0;state<=IDLE;end
              IDLE:if(interval_count>=INTERVAL-1)begin request_toggle<=!request_toggle;state<=WAIT_ACK;interval_count<=0;end
                   else interval_count<=interval_count+1'b1;
              default:begin request_toggle<=0;data_valid<=0;state<=WAIT_READY;end
            endcase
        end
    end
endmodule
