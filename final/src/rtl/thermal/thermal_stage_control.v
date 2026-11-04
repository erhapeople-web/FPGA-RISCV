`timescale 1ns/1ps
// Diagnostic sequencing only. Normal-mode top level must bypass all permits.
// CPU clock remains 100 MHz; these are reset/enable requests, not clock gates.
module thermal_stage_control #(
    parameter BASE_CYCLES=100000000,
    parameter DWELL_CYCLES=200000000,
    parameter TIMEOUT_CYCLES=300000000,
    // Zero keeps the original short diagnostic dwell. The sustained candidate
    // explicitly selects seconds; never multiply seconds by CLOCK_HZ into a
    // 32-bit phase counter (900 s at 100 MHz needs more than 32 bits).
    parameter integer CLOCK_HZ=100000000,
    parameter integer VIDEO_RUN_SECONDS=0
)(
    input wire clk,resetn,
    input wire ddr_init_async,base_cpu_resetn,cpu_reset_actual,loader_poll_seen,
    input wire cam_done,hdmi_done,pix_locked,video_auto_done,cam_running,
    input wire [2:0] pix_mode,
    input wire display_valid,init_fault,
    input wire [7:0] cfg_error,
    input wire measurement_ok_async,ot_async,
    output wire permit_ddr,permit_cpu,permit_cfg,permit_pipe,
    output reg [3:0] phase_gray,
    output reg [3:0] fault_reason,
    output reg fault,
    output wire [31:0] context_word
);
    localparam ADC_READY_BASE=0,DDR_WAIT=1,DDR_IDLE=2,CPU_BOOT=3,
               CPU_IDLE=4,VIDEO_CONFIG=5,VIDEO_START=6,VIDEO_RUN=7,DONE=8;
    // Sticky reason priority: OT, init fault, lost ADC, lost DDR, lost CPU,
    // configuration error, then state-specific timeout.
    localparam R_NONE=0,R_OT=1,R_ADC_LOST=2,R_INIT_FAULT=3,R_DDR_DROP=4,
               R_ADC_NOT_READY=5,R_DDR_TIMEOUT=6,R_CPU_TIMEOUT=7,
               R_CONFIG_ERROR=8,R_CONFIG_TIMEOUT=9,R_VIDEO_TIMEOUT=10,
               R_CPU_RESET_LOST=11,R_INTERNAL_STATE=12,R_VIDEO_FEEDBACK_LOST=13;

    reg stage_reset_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg stage_reset_sync_q=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge resetn)
        if(!resetn)begin stage_reset_meta<=0;stage_reset_sync_q<=0;end
        else begin stage_reset_meta<=1;stage_reset_sync_q<=stage_reset_meta;end
    wire stage_local_resetn=stage_reset_sync_q;

    reg ddr_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ddr_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg measurement_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg measurement_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ot_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ot_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge stage_local_resetn)
        if(!stage_local_resetn)begin
            ddr_meta<=0;ddr_sync_q<=0;measurement_meta<=0;measurement_sync_q<=0;ot_meta<=0;ot_sync_q<=0;
        end else begin
            ddr_meta<=ddr_init_async;ddr_sync_q<=ddr_meta;
            measurement_meta<=measurement_ok_async;measurement_sync_q<=measurement_meta;
            ot_meta<=ot_async;ot_sync_q<=ot_meta;
        end

    reg [3:0] phase_binary;
    reg [31:0] phase_age,healthy_age;
    localparam VIDEO_TICK_WIDTH=(CLOCK_HZ<2)?1:$clog2(CLOCK_HZ);
    localparam VIDEO_SECONDS_WIDTH=(VIDEO_RUN_SECONDS<2)?1:$clog2(VIDEO_RUN_SECONDS);
    reg [VIDEO_TICK_WIDTH-1:0] video_tick_count;
    reg [VIDEO_SECONDS_WIDTH-1:0] video_seconds_elapsed;
    reg ddr_seen;
    // These signals drive asynchronous reset inputs outside this module.
    // Keep one preserved FF per permit: state recoding/transition decode must
    // never be on the output side, where a short hazard would assert reset.
    reg permit_ddr_q=0 /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg permit_cpu_q=0 /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg permit_cfg_q=0 /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg permit_pipe_q=0 /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    assign permit_ddr=permit_ddr_q;
    assign permit_cpu=permit_cpu_q;
    assign permit_cfg=permit_cfg_q;
    assign permit_pipe=permit_pipe_q;

    // phase_gray is registered, not a combinational XOR of changing binary FFs.
    // Sequential advances 0..8 change exactly one Gray bit. Fault freezes phase.
    task advance_phase;
        input [3:0] next_phase;
        begin
            phase_binary<=next_phase;
            phase_gray<=next_phase^(next_phase>>1);
            permit_ddr_q<=next_phase>=DDR_WAIT && next_phase<=DONE;
            permit_cpu_q<=next_phase>=CPU_BOOT && next_phase<=VIDEO_RUN;
            permit_cfg_q<=next_phase>=VIDEO_CONFIG && next_phase<=VIDEO_RUN;
            permit_pipe_q<=next_phase>=VIDEO_START && next_phase<=VIDEO_RUN;
            phase_age<=0;healthy_age<=0;
            video_tick_count<=0;video_seconds_elapsed<=0;
        end
    endtask
    task trip;
        input [3:0] reason;
        begin
            fault<=1;fault_reason<=reason;
            permit_ddr_q<=0;permit_cpu_q<=0;permit_cfg_q<=0;permit_pipe_q<=0;
        end
    endtask

    always @(posedge clk or negedge stage_local_resetn)begin
        if(!stage_local_resetn)begin
            phase_binary<=ADC_READY_BASE;phase_gray<=0;
            phase_age<=0;healthy_age<=0;ddr_seen<=0;fault<=0;fault_reason<=R_NONE;
            video_tick_count<=0;video_seconds_elapsed<=0;
            permit_ddr_q<=0;permit_cpu_q<=0;permit_cfg_q<=0;permit_pipe_q<=0;
        end else if(!fault)begin
            // Only arm DDR-drop detection after permitting its initialization.
            if(permit_ddr && ddr_sync_q)ddr_seen<=1;
            if(ot_sync_q)trip(R_OT);
            else if(init_fault)trip(R_INIT_FAULT);
            else if(phase_binary!=ADC_READY_BASE && !measurement_sync_q)trip(R_ADC_LOST);
            else if(ddr_seen && !ddr_sync_q)trip(R_DDR_DROP);
            else if(phase_binary>=CPU_IDLE && phase_binary<=VIDEO_RUN && !cpu_reset_actual)trip(R_CPU_RESET_LOST);
            else if(phase_binary>=VIDEO_CONFIG && phase_binary<=VIDEO_RUN && |cfg_error)trip(R_CONFIG_ERROR);
            // These are steady completion/control levels in the CPU domain.
            // display_valid is intentionally excluded from a level guard:
            // image freshness/quality needs an independent end-to-end check.
            else if(phase_binary==VIDEO_RUN && (!cam_done || !hdmi_done || !pix_locked ||
                    !video_auto_done || !cam_running || pix_mode!=3'b001))trip(R_VIDEO_FEEDBACK_LOST);
            else begin
                case(phase_binary)
                  ADC_READY_BASE:begin
                      if(measurement_sync_q && healthy_age>=BASE_CYCLES-1)advance_phase(DDR_WAIT);
                      else if(phase_age>=TIMEOUT_CYCLES-1)trip(R_ADC_NOT_READY);
                      else begin
                          phase_age<=phase_age+1'b1;
                          if(measurement_sync_q)healthy_age<=healthy_age+1'b1;else healthy_age<=0;
                      end
                  end
                  DDR_WAIT:begin
                      if(ddr_sync_q && base_cpu_resetn)advance_phase(DDR_IDLE);
                      else if(phase_age>=TIMEOUT_CYCLES-1)trip(R_DDR_TIMEOUT);
                      else phase_age<=phase_age+1'b1;
                  end
                  DDR_IDLE:if(phase_age>=DWELL_CYCLES-1)advance_phase(CPU_BOOT);
                           else phase_age<=phase_age+1'b1;
                  CPU_BOOT:begin
                      if(cpu_reset_actual && loader_poll_seen)advance_phase(CPU_IDLE);
                      else if(phase_age>=TIMEOUT_CYCLES-1)trip(R_CPU_TIMEOUT);
                      else phase_age<=phase_age+1'b1;
                  end
                  CPU_IDLE:if(phase_age>=DWELL_CYCLES-1)advance_phase(VIDEO_CONFIG);
                           else phase_age<=phase_age+1'b1;
                  VIDEO_CONFIG:begin
                      if(cam_done && hdmi_done && pix_locked)advance_phase(VIDEO_START);
                      else if(phase_age>=TIMEOUT_CYCLES-1)trip(R_CONFIG_TIMEOUT);
                      else phase_age<=phase_age+1'b1;
                  end
                  VIDEO_START:begin
                      if(video_auto_done && cam_running && pix_mode==3'b001 && display_valid)advance_phase(VIDEO_RUN);
                      else if(phase_age>=TIMEOUT_CYCLES-1)trip(R_VIDEO_TIMEOUT);
                      else phase_age<=phase_age+1'b1;
                  end
                  VIDEO_RUN:begin
                      if(VIDEO_RUN_SECONDS==0)begin
                          if(phase_age>=DWELL_CYCLES-1)advance_phase(DONE);
                          else phase_age<=phase_age+1'b1;
                      end else if(video_tick_count==CLOCK_HZ-1)begin
                          video_tick_count<=0;
                          if(video_seconds_elapsed>=VIDEO_RUN_SECONDS-1)advance_phase(DONE);
                          else video_seconds_elapsed<=video_seconds_elapsed+1'b1;
                      end else video_tick_count<=video_tick_count+1'b1;
                  end
                  DONE:begin phase_age<=phase_age;healthy_age<=healthy_age;end
                  default:trip(R_INTERNAL_STATE);
                endcase
            end
        end
    end

    assign context_word[3:0]=phase_gray;
    assign context_word[7:4]=fault_reason;
    assign context_word[8]=ddr_sync_q;
    assign context_word[9]=base_cpu_resetn;
    assign context_word[10]=cpu_reset_actual;
    assign context_word[11]=loader_poll_seen;
    assign context_word[12]=pix_locked;
    assign context_word[13]=cam_done;
    assign context_word[14]=hdmi_done;
    assign context_word[15]=video_auto_done;
    assign context_word[16]=cam_running;
    assign context_word[19:17]=pix_mode;
    assign context_word[20]=init_fault;
    assign context_word[21]=|cfg_error;
    assign context_word[22]=permit_cpu;
    assign context_word[23]=permit_cfg;
    assign context_word[24]=permit_pipe;
    assign context_word[25]=fault;
    assign context_word[26]=measurement_sync_q;
    assign context_word[31:27]=0;
`ifndef SYNTHESIS
    initial if(BASE_CYCLES<1 || DWELL_CYCLES<1 || TIMEOUT_CYCLES<1)
        $fatal(1,"thermal_stage_control requires positive cycle parameters");
    initial if(CLOCK_HZ<1 || VIDEO_RUN_SECONDS<0 || VIDEO_RUN_SECONDS>900)
        $fatal(1,"thermal_stage_control requires CLOCK_HZ>=1 and 0..900 video seconds");
`endif
endmodule
