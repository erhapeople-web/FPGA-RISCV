`timescale 1ns/1ps
// Independent 27MHz load protection. ADC/JDRP never needs the CPU or DDR clock.
// The permission is one preserved FF Q, never a combinational state decoder.
module thermal_load_guard #(
    parameter integer CLOCK_HZ=27000000,
    parameter integer WARMUP_CYCLES=2700000,
    parameter integer CONVERSION_TIMEOUT_CYCLES=27000000,
    parameter integer LIMIT_SECONDS=300
)(
    input wire clk,resetn,alarm_async,ot_async,done_async,
    output wire permit,ot_sync,alarm_sync,
    output reg armed,fault,
    output reg [3:0] fault_reason
);
    localparam R_NONE=0,R_OT=1,R_ALARM0=2,R_CONVERSION_NOT_READY=3,
               R_CONVERSION_LOST=4,R_LIMIT=5,R_INVALID_INPUT=6;
    reg reset_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg reset_sync_q=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge resetn)
        if(!resetn)begin reset_meta<=0;reset_sync_q<=0;end
        else begin reset_meta<=1;reset_sync_q<=reset_meta;end
    wire local_resetn=reset_sync_q;
    reg alarm_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg alarm_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ot_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ot_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg done_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg done_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge local_resetn)
        if(!local_resetn)begin
            alarm_meta<=0;alarm_sync_q<=0;ot_meta<=0;ot_sync_q<=0;done_meta<=0;done_sync_q<=0;
        end else begin
            alarm_meta<=alarm_async;alarm_sync_q<=alarm_meta;
            ot_meta<=ot_async;ot_sync_q<=ot_meta;
            done_meta<=done_async;done_sync_q<=done_meta;
        end
    assign ot_sync=ot_sync_q;
    assign alarm_sync=alarm_sync_q;
    localparam WW=(WARMUP_CYCLES<2)?1:$clog2(WARMUP_CYCLES);
    localparam AW=(CONVERSION_TIMEOUT_CYCLES<2)?1:$clog2(CONVERSION_TIMEOUT_CYCLES);
    localparam TW=(CLOCK_HZ<2)?1:$clog2(CLOCK_HZ);
    localparam SW=(LIMIT_SECONDS<2)?1:$clog2(LIMIT_SECONDS);
    reg [WW-1:0] warmup_count;
    reg warmup_done,done_low_seen,done_previous;
    reg [1:0] done_fill;
    reg [AW-1:0] conversion_age;
    reg [TW-1:0] tick_count;
    reg [SW-1:0] elapsed_seconds;
    reg permit_q=0 /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    assign permit=permit_q;
    // Reset-initialized zeros are not ADC observations. Require filled input
    // stages, a real synchronized low AFTER warmup, then a real rising edge.
    wire conversion_edge=warmup_done && done_fill==3 && done_low_seen && done_sync_q && !done_previous;
    task trip;
        input [3:0] reason;
        begin permit_q<=0;fault<=1;fault_reason<=reason;end
    endtask
    always @(posedge clk or negedge local_resetn)begin
        if(!local_resetn)begin
            warmup_count<=0;warmup_done<=0;done_fill<=0;done_low_seen<=0;done_previous<=0;
            conversion_age<=0;tick_count<=0;elapsed_seconds<=0;
            permit_q<=0;armed<=0;fault<=0;fault_reason<=R_NONE;
        end else if(!fault)begin
            // The default also fails closed for X in DIGITAL simulation; this
            // is not an analog unknown-voltage or metastability detector.
            case({ot_sync_q,alarm_sync_q})
              2'b01:trip(R_ALARM0);
              2'b10,2'b11:trip(R_OT);
              2'b00:begin
                if(warmup_done && !conversion_edge && conversion_age>=CONVERSION_TIMEOUT_CYCLES-1)
                    trip(armed?R_CONVERSION_LOST:R_CONVERSION_NOT_READY);
                else if(permit_q && tick_count==CLOCK_HZ-1 && elapsed_seconds>=LIMIT_SECONDS-1)
                    trip(R_LIMIT);
                else begin
                    if(!warmup_done)begin
                        if(warmup_count>=WARMUP_CYCLES-1)warmup_done<=1;
                        else warmup_count<=warmup_count+1'b1;
                    end
                    if(done_fill!=3)done_fill<=done_fill+1'b1;
                    done_previous<=done_sync_q;
                    if(!warmup_done)done_low_seen<=0;
                    else if(done_fill==3 && !done_sync_q)done_low_seen<=1;
                    if(!warmup_done)conversion_age<=0;
                    else if(conversion_edge)begin
                        conversion_age<=0;
                        if(!armed)begin permit_q<=1;armed<=1;end
                    end else conversion_age<=conversion_age+1'b1;
                    if(permit_q)begin
                        if(tick_count==CLOCK_HZ-1)begin
                            tick_count<=0;elapsed_seconds<=elapsed_seconds+1'b1;
                        end else tick_count<=tick_count+1'b1;
                    end else begin tick_count<=0;elapsed_seconds<=0;end
                end
              end
              default:trip(R_INVALID_INPUT);
            endcase
        end
    end
`ifndef SYNTHESIS
    initial if(CLOCK_HZ<1 || WARMUP_CYCLES<1 || CONVERSION_TIMEOUT_CYCLES<4 || LIMIT_SECONDS<1 || LIMIT_SECONDS>300)
        $fatal(1,"LOAD_GUARD_PARAMETER_ERROR");
`endif
endmodule
