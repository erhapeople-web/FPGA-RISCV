// AI_cpu: independently authored RV32I/Zicsr machine-mode processor.
// Five architectural stages: IF transaction, ID queue, EX/MEM/WB execution groups.
// In-order retirement. No side effects from younger instructions on a trap.
module rv32_core # (parameter LOOP_BUFFER=0, parameter PREDICT=1, parameter BP_BITS=6, parameter PRELOOKUP=0, parameter WIDE_FRONT=0, parameter FUSION=0, parameter FOUR_FUSION=1, parameter TRIPLE_BRANCH=1, parameter DUAL_ISSUE=0, parameter FETCH_WORDS=2, parameter FALLTHROUGH_REUSE=0, parameter PROBE_CONTROL_FORWARD=1, parameter RETURN_TARGET_BUFFER=0, parameter RETURN_BYPASS=0, parameter NORMAL_LOAD_FORWARD=0, parameter [7:0] CONTROL_LOAD_FORMATS=8'h34, parameter BANKED_RECOVERY=1) (
    input wire clk, resetn,
    output wire i_valid, input wire i_ready, output wire [31:0] i_addr,
    input wire i_rvalid, output wire i_rready, input wire [31:0] i_rdata, i_rdata_hi, i_rdata2, i_rdata3, input wire i_error,
    output wire d_valid, input wire d_ready, output wire [31:0] d_addr, d_wdata,
    output wire d_write, output wire [3:0] d_wstrb,
    input wire d_rvalid, output wire d_rready, input wire [31:0] d_rdata, input wire d_error,
    // A speculative cache-array read has no bus or architectural side effects.
    // Only a one-cycle result paired with the actual EX->MEM transfer may retire.
    output wire d_probe_valid,d_probe_commit,d_probe_take,
    output wire [31:0] d_probe_addr,
    input wire d_probe_ready,d_probe_result_valid,d_probe_hit,
    input wire [31:0] d_probe_result_addr,d_probe_data,
    input wire irq_timer, irq_software, irq_external,
    output reg retire_valid, output reg [31:0] retire_pc, retire_inst, retire_data,
    output reg [4:0] retire_rd, output reg retire_we,
    output reg retire_valid1,retire_valid2,retire_we1,retire_we2,
    output reg [31:0] retire_pc1,retire_pc2,retire_inst1,retire_inst2,retire_data1,retire_data2,
    output reg [4:0] retire_rd1,retire_rd2,
    output reg retire_valid3,retire_we3,
    output reg [31:0] retire_pc3,retire_inst3,retire_data3,
    output reg [4:0] retire_rd3,
    output reg [2:0] retire_count,
    output wire [4:0] stage_valid,
    output reg [63:0] cycles, retired,
    output reg [31:0] branch_count, mispredict_count, hazard_cycles, memory_cycles
);

    // A payload bank per physical write port. A small last-writer table
    // selects the architectural value, allowing payloads to infer LUT RAM.
    // Reset clears validity, not the payload arrays; reads still return zero.
    reg [31:0] rf_payload0[0:31] /* synthesis syn_ramstyle="lut_ram" */;
    reg [31:0] rf_payload1[0:31] /* synthesis syn_ramstyle="lut_ram" */;
    reg [31:0] rf_payload2[0:31] /* synthesis syn_ramstyle="lut_ram" */;
    reg [1:0] rf_owner[0:31];
    reg [31:0] rf_valid;
    wire rf_we0=wv && !wfault && wwe && wrd!=0 && !(wcount>1 && wwe1 && wrd1==wrd);
    wire rf_we1=wv && !wfault && wcount>1 && wwe1 && wrd1!=0;
    wire rf_we2=FOUR_FUSION && wv && !wfault && wcount==4 && wwe2 && wrd2!=0;
    integer rf_reset_index;
    always @(posedge clk)begin
        if(!resetn)begin
            rf_valid<=0;
            for(rf_reset_index=0;rf_reset_index<32;rf_reset_index=rf_reset_index+1)rf_owner[rf_reset_index]<=0;
        end else begin
            // Match the original procedural collision priority: port 0 last.
            if(rf_we1)begin rf_owner[wrd1]<=1;rf_valid[wrd1]<=1;end
            if(rf_we2)begin rf_owner[wrd2]<=2;rf_valid[wrd2]<=1;end
            if(rf_we0)begin rf_owner[wrd]<=0;rf_valid[wrd]<=1;end
        end
        if(resetn && rf_we0)rf_payload0[wrd]<=wr;
        if(resetn && rf_we1)rf_payload1[wrd1]<=wr1;
        if(resetn && rf_we2)rf_payload2[wrd2]<=wr2;
    end
    wire [4:0] rf_raddr[0:7];
    wire [31:0] rf_rdata[0:7];
    assign rf_raddr[0]=drs1;assign rf_raddr[1]=drs2;
    assign rf_raddr[2]=di1[19:15];assign rf_raddr[3]=di1[24:20];
    assign rf_raddr[4]=5;assign rf_raddr[5]=1;
    assign rf_raddr[6]=mask_other;
    assign rf_raddr[7]=third_rs;
    genvar rf_read_port;
    generate for(rf_read_port=0;rf_read_port<8;rf_read_port=rf_read_port+1)begin:g_rf_read
        wire [4:0] index=rf_raddr[rf_read_port];
        assign rf_rdata[rf_read_port]=(index==0 || !rf_valid[index]) ? 32'b0:
            (FOUR_FUSION && rf_owner[index]==2) ? rf_payload2[index]:
            rf_owner[index]==1 ? rf_payload1[index]:rf_payload0[index];
    end endgenerate
`ifdef RTL_SIM
    // Debug aliases have no synthesis fanout. Shadow state independently
    // checks reset and simultaneous-write semantics on every cycle.
    wire [31:0] regs[0:31];
    reg [31:0] rf_shadow[0:31];
    genvar rf_debug_index;
    generate for(rf_debug_index=0;rf_debug_index<32;rf_debug_index=rf_debug_index+1)begin:g_rf_debug
        assign regs[rf_debug_index]=(rf_debug_index==0 || !rf_valid[rf_debug_index]) ? 32'b0:
            (FOUR_FUSION && rf_owner[rf_debug_index]==2) ? rf_payload2[rf_debug_index]:
            rf_owner[rf_debug_index]==1 ? rf_payload1[rf_debug_index]:rf_payload0[rf_debug_index];
        always @(negedge clk)if(resetn && regs[rf_debug_index]!==rf_shadow[rf_debug_index])
            $fatal(1,"RF_BANK_MISMATCH register=%0d",rf_debug_index);
    end endgenerate
    integer rf_shadow_index;
    always @(posedge clk)begin
        if(!resetn)for(rf_shadow_index=0;rf_shadow_index<32;rf_shadow_index=rf_shadow_index+1)rf_shadow[rf_shadow_index]<=0;
        else if(wv && !wfault)begin
            if(wcount>1 && wwe1 && wrd1!=0)rf_shadow[wrd1]<=wr1;
            if(wcount==4 && wwe2 && wrd2!=0)rf_shadow[wrd2]<=wr2;
            if(wwe && wrd!=0 && !(wcount>1 && wwe1 && wrd1==wrd))rf_shadow[wrd]<=wr;
        end
    end
`endif

    // Four in-order metadata credits decouple request issue from responses.
    // An asserted, unaccepted request remains stable through a redirect.
    reg fetch_valid,fetch_killed,recovering,fetch_resume,fetch_repredict;
    (* syn_maxfan=64 *) reg [31:0] fetch_addr,recover_pc;
    reg [31:0] fetch_next /* synthesis syn_preserve=1 syn_allow_retiming=0 syn_ramstyle="lut_ram" */;
    reg [31:0] fetch_pc_q[0:3],fetch_next_q[0:3];
    reg [3:0] fetch_kill_q;
    reg [1:0] fetch_head,fetch_tail;
    reg [2:0] fetch_count;
    reg [4:0] fetch_reserved;
    wire [1:0] fs=fetch_valid ? 1:fetch_count!=0 ? 2:0; // debug state
    reg legacy_dv, xv, mv, wv;
    reg [31:0] legacy_dp,legacy_di,legacy_dn,xp,xi,xn,xa,xb;
    reg legacy_de,xe;
    wire [31:0] iq_pc_storage[0:15],iq_inst_storage[0:15],iq_next_storage[0:15];
    wire [31:0] iq_pc[0:15],iq_inst[0:15],iq_next[0:15];
    wire [31:0] iq_follow_inst[0:15],iq_follow_next[0:15];
    reg [15:0] iq_follow_valid_storage,iq_follow_linear;
    wire [15:0] iq_follow_valid;
    reg [31:0] x_follow_inst,x_follow_next,x_follow_ra;
    reg x_follow_valid,x_follow_linear;
    // Consecutive queue PCs follow the preceding prediction. A registered
    // linear flag replaces ID-stage 32-bit add/compare chains for pairing.
    reg [15:0] iq_error_storage,iq_linear_storage;
    wire [15:0] iq_error,iq_linear;
    // Two immutable candidate banks: word 0 is the observed fallthrough,
    // words 1/2 are independently observed return-target instructions.
    // Only IQ slots 0..2 can refer to the currently activated bank. Wide
    // payload writes happen in ID, independently of the late redirect.
    reg [95:0] recovery_pc_bank[0:1],recovery_inst_bank[0:1],recovery_next_bank[0:1];
    reg [2:0] recovery_linear_bank[0:1];
    reg [2:0] recovery_slot_mask;
    reg recovery_active_bank,x_recovery_bank,x_recovery_valid;
    genvar recovery_slot;
    generate for(recovery_slot=0;recovery_slot<16;recovery_slot=recovery_slot+1)begin:g_recovery_view
        if(recovery_slot<3)begin:g_overlay
            wire selected=BANKED_RECOVERY && recovery_slot_mask[recovery_slot];
            assign iq_pc[recovery_slot]=selected ? recovery_pc_bank[recovery_active_bank][32*recovery_slot+:32]:iq_pc_storage[recovery_slot];
            assign iq_inst[recovery_slot]=selected ? recovery_inst_bank[recovery_active_bank][32*recovery_slot+:32]:iq_inst_storage[recovery_slot];
            assign iq_next[recovery_slot]=selected ? recovery_next_bank[recovery_active_bank][32*recovery_slot+:32]:iq_next_storage[recovery_slot];
            assign iq_linear[recovery_slot]=selected ? recovery_linear_bank[recovery_active_bank][recovery_slot]:iq_linear_storage[recovery_slot];
            // Candidates originate only from successful instruction reads.
            // They do not carry an independently observed further successor.
            assign iq_error[recovery_slot]=!selected && iq_error_storage[recovery_slot];
            assign iq_follow_valid[recovery_slot]=!selected && iq_follow_valid_storage[recovery_slot];
        end else begin:g_normal
            assign iq_pc[recovery_slot]=iq_pc_storage[recovery_slot];
            assign iq_inst[recovery_slot]=iq_inst_storage[recovery_slot];
            assign iq_next[recovery_slot]=iq_next_storage[recovery_slot];
            assign iq_linear[recovery_slot]=iq_linear_storage[recovery_slot];
            assign iq_error[recovery_slot]=iq_error_storage[recovery_slot];
            assign iq_follow_valid[recovery_slot]=iq_follow_valid_storage[recovery_slot];
        end
    end endgenerate
    reg [3:0] fetch_linear0_q,fetch_linear1_q;
    reg [3:0] iq_head,iq_tail;
    reg [4:0] iq_count;
    wire [3:0] iq_h1=iq_head+4'd1,iq_h2=iq_head+4'd2,iq_h3=iq_head+4'd3,iq_t1=iq_tail+4'd1;
    wire dv=WIDE_FRONT ? iq_count!=0:legacy_dv;
    wire [31:0] dp=WIDE_FRONT ? iq_lane_pc[0]:legacy_dp;
    wire [31:0] di=WIDE_FRONT ? iq_lane_inst[0]:legacy_di;
    wire [31:0] dn=WIDE_FRONT ? iq_lane_next[0]:legacy_dn;
    wire de=WIDE_FRONT ? iq_error[iq_head]:legacy_de;
    wire [31:0] di1=iq_lane_inst[1],di2=iq_lane_inst[2],di3=iq_lane_inst[3];
    reg [31:0] fetch_pred1 /* synthesis syn_preserve=1 syn_allow_retiming=0 syn_ramstyle="lut_ram" */;
    reg [31:0] fetch_pred1_q[0:3];
    reg [2:0] fetch_words_q[0:3];
    reg [31:0] fetch_pred2 /* synthesis syn_preserve=1 syn_allow_retiming=0 syn_ramstyle="lut_ram" */;
    reg [31:0] fetch_pred3 /* synthesis syn_preserve=1 syn_allow_retiming=0 syn_ramstyle="lut_ram" */;
    reg [31:0] fetch_pred2_q[0:3],fetch_pred3_q[0:3];
    reg [3:0] fetch_linear2_q,fetch_linear3_q;
    reg [3:0] fetch_linear;
    reg [2:0] xcount,mcount,wcount;
    reg x_alu_branch3,m_alu_branch3,w_alu_branch3;
    wire branch_third=x_alu_branch3;
    reg [31:0] xi3,mi3,wi3,mr2,wr2;
    reg [4:0] mrd2,wrd2;reg mwe2,wwe2;
    reg [31:0] xbranch_pc,xbranch_target;
    reg [31:0] xpc1,mpc1,wpc1;reg xsecond_wrong;
    reg xtaken_wrong,xfall_wrong;
    reg xsequential_wrong,xcall_wrong;
    reg [31:0] xi1,xi2,xn_last,x1a,x1b,mi1,mi2,mr1,mmiddle,wi1,wi2,wr1,wmiddle;
    reg [4:0] mrd1,wrd1;
    reg x_constant;reg [31:0] x_constant_value;
    reg mwe1,wwe1;
    reg [31:0] mp, mi, mn, mr, ma, ms, mcause, mtval;
    reg [4:0] mrd;
    reg [2:0] mfun;
    reg [3:0] mstrb;
    reg mwe, mmem, mstore, mfault, msent, mret, mserial, mcsrwe;
    // Carry the nonzero write qualification with the MEM payload. JALR
    // already has registered source-match tags; do not decode live mrd
    // before its target adder merely to reject architectural x0.
    reg m_write_rd /* synthesis syn_preserve=1 syn_allow_retiming=0 */;
    reg [11:0] mcsr;
    reg [31:0] mcsrdata;
    reg [31:0] wp, wi, wn, wr, wcause, wtval, wcsrdata;
    reg [4:0] wrd;
    reg wwe, wfault, wret, wserial, wcsrwe;
    reg [11:0] wcsr;
    reg [31:0] csr_status, csr_ie, csr_vec, csr_epc, csr_cause, csr_tval, csr_scratch;
    reg [31:0] committed_next;
    wire [31:0] pending_irqs={20'b0,irq_external,3'b0,irq_timer,3'b0,irq_software,3'b0};
    wire irq_wait=csr_status[3] && |(csr_ie & pending_irqs);
    wire irq_take=irq_wait && !xv && !mv && !wv;
    wire wb_redirect=wv && (wfault || wret);
    wire [31:0] irq_cause=(csr_ie[11] && irq_external) ? 32'h8000000b:
                          (csr_ie[3] && irq_software) ? 32'h80000003:32'h80000007;

    // Tagged BTB, two-bit direction counters and a resolved-path return stack.
    localparam BP_ENTRIES=1<<BP_BITS;
    // Read-only flat views retain legacy/query helper semantics. Storage and
    // training are physically partitioned by instruction-word bank below.
    localparam BTB_BANK_BITS=BP_BITS<2 ? BP_BITS:2;
    localparam BTB_BANKS=1<<BTB_BANK_BITS;
    localparam BTB_ROWS=BP_ENTRIES/BTB_BANKS;
    localparam BTB_ROW_BITS=BP_BITS>BTB_BANK_BITS ? BP_BITS-BTB_BANK_BITS:1;
    wire [BP_ENTRIES-1:0] bp_valid,bp_return;
    wire [29-BP_BITS:0] bp_tag[0:BP_ENTRIES-1];
    wire [31:0] bp_target[0:BP_ENTRIES-1];
    wire [1:0] bp_count[0:BP_ENTRIES-1];
    reg [31:0] ras[0:15],ras_top;
    // Four exact-PC tags. Only successful ROM responses at an observed
    // resolved return target fill this buffer; it never reads the bus itself.
    reg xpacket_taken_wrong,xpacket_fall_wrong;
    reg [31:0] xpacket_taken_pc,xpacket_fall_pc;
    reg x_replay_hit,x_replay_two,x_replay_linear0,x_replay_linear1;
    reg [31:0] x_replay_inst0,x_replay_inst1,x_replay_next0,x_replay_next1;
    reg x_follow_return;
    reg [3:0] rtb_valid,rtb_two,rtb_linear0,rtb_linear1;
    reg [31:0] rtb_tag[0:3],rtb_inst0[0:3],rtb_inst1[0:3],rtb_next0[0:3],rtb_next1[0:3];
    reg last_return_valid,observe_valid,observe_two,observe_linear0,observe_linear1;
    reg [31:0] last_return_pc,observe_pc,observe_inst0,observe_inst1,observe_next0,observe_next1;
    wire [1:0] return_write_index=last_return_pc[5:4];
    wire [1:0] return_read_index=x_follow_next[5:4];
    reg train_valid,train_taken,train_return;
    reg [31:0] train_pc,train_target;
    // For BP_BITS=8: bank=PC[3:2], row=PC[9:4], tag=PC[31:10].
    // No extra pipeline stage. A training edge updates exactly one bank.
    wire [BTB_BANKS-1:0] bank_train_prediction;
    genvar btb_bank,btb_row;
    generate for(btb_bank=0;btb_bank<BTB_BANKS;btb_bank=btb_bank+1)begin:g_btb_bank
        reg [BTB_ROWS-1:0] valid_bits,return_bits;
        reg [29-BP_BITS:0] tag[0:BTB_ROWS-1] /* synthesis syn_ramstyle="lut_ram" */;
        reg [31:0] target[0:BTB_ROWS-1] /* synthesis syn_ramstyle="lut_ram" */;
        reg [1:0] counter[0:BTB_ROWS-1] /* synthesis syn_ramstyle="lut_ram" */;
        wire [BTB_ROW_BITS-1:0] write_row=(train_pc>>(BTB_BANK_BITS+2)) & (BTB_ROWS-1);
        // Query the same local row used by the read/modify/write counter.
        // Only a one-bit direction result crosses the bank selection mux.
        assign bank_train_prediction[btb_bank]=
            (!valid_bits[write_row] || tag[write_row]!=train_pc[31:BP_BITS+2]) ? train_taken:
            train_taken ? counter[write_row]!=0:counter[write_row]==3;
        always @(posedge clk)begin
            if(!resetn)begin valid_bits<=0;return_bits<=0;end
            else if(train_valid && train_pc[BTB_BANK_BITS+1:2]==btb_bank)begin
                valid_bits[write_row]<=1'b1;
                tag[write_row]<=train_pc[31:BP_BITS+2];
                target[write_row]<=train_target;
                return_bits[write_row]<=train_return;
                if(!valid_bits[write_row] || tag[write_row]!=train_pc[31:BP_BITS+2])
                    counter[write_row]<=train_taken ? 2:1;
                else if(train_taken && counter[write_row]!=3)counter[write_row]<=counter[write_row]+1'b1;
                else if(!train_taken && counter[write_row]!=0)counter[write_row]<=counter[write_row]-1'b1;
            end
        end
        for(btb_row=0;btb_row<BTB_ROWS;btb_row=btb_row+1)begin:g_flat_view
            assign bp_valid[btb_row*BTB_BANKS+btb_bank]=valid_bits[btb_row];
            assign bp_return[btb_row*BTB_BANKS+btb_bank]=return_bits[btb_row];
            assign bp_tag[btb_row*BTB_BANKS+btb_bank]=tag[btb_row];
            assign bp_target[btb_row*BTB_BANKS+btb_bank]=target[btb_row];
            assign bp_count[btb_row*BTB_BANKS+btb_bank]=counter[btb_row];
        end
    end endgenerate
    reg [3:0] ras_sp;
    reg [4:0] ras_count;
    wire [31:0] recovery_target=(bp_return[fi] && ras_count!=0) ? ras_top:bp_target[fi];
    wire [31:0] chain_target=(bp_return[chain_index] && ras_count!=0) ? ras_top:bp_target[chain_index];
    wire [BP_BITS-1:0] fi=recover_pc[BP_BITS+1:2];
    wire predicted=PREDICT && bp_valid[fi] && bp_tag[fi]==recover_pc[31:BP_BITS+2] && bp_count[fi][1];
    wire [BP_BITS-1:0] chain_index=fetch_next[BP_BITS+1:2];
    wire chain_predicted=PREDICT && bp_valid[chain_index] &&
        bp_tag[chain_index]==fetch_next[31:BP_BITS+2] && bp_count[chain_index][1];

    wire [6:0] op=xi[6:0];
    wire jump_second=xcount==2 && xi1[6:0]==7'h67;
    wire rd_link=branch_inst[11:7]==1 || branch_inst[11:7]==5;
    wire rs1_link=branch_inst[19:15]==1 || branch_inst[19:15]==5;
    wire ras_push=(branch_inst[6:0]==7'h6f || branch_inst[6:0]==7'h67) && rd_link;
    wire ras_pop=branch_inst[6:0]==7'h67 && rs1_link && (!rd_link || branch_inst[11:7]!=branch_inst[19:15]);
    wire [3:0] ras_previous=ras_sp-1'b1;
    wire [3:0] ras_below=ras_sp-2'd2;
    // A completed, successful load is available at MEM just like an ALU
    // result. Pending or faulting loads still interlock the dependent EX slot.
    wire fast_hit_confirm=PRELOOKUP && resetn && mv && mmem && !mstore && !mfault && !msent &&
        !wb_redirect && d_probe_result_valid && d_probe_hit && d_probe_result_addr=={ma[31:2],2'b0};
    wire [31:0] memory_load_data=fast_hit_confirm ? d_probe_data:d_rdata;
    wire m_load_forward=mv && mmem && !mstore && !mfault &&
        (fast_hit_confirm || (NORMAL_LOAD_FORWARD && msent && d_rvalid && !d_error));
    wire m_forward=mv && mwe && mrd!=0 && !mfault && (!mmem || m_load_forward);
    wire [31:0] m_forward_data=mmem ? (NORMAL_LOAD_FORWARD ? load_result:probe_load_result):mr;
    // mwe1/wwe1 already include nonzero destination, packet count and squash.
    // Do not repeat live mrd1/count decoding before a JALR target adder.
    wire m_forward1=mv && mwe1 && !mfault;
    wire w_forward1=wv && wwe1 && !wfault;
    wire m_forward2=mv && mwe2 && !mfault;
    wire w_forward2=wv && wwe2 && !wfault;
    wire w_forward=wv && wwe && wrd!=0 && !wfault;
    wire [31:0] x_a=xi[19:15]==0 ? 0:
        (m_forward2 && mrd2==xi[19:15]) ? mr2:(m_forward1 && mrd1==xi[19:15]) ? mr1:
        (m_forward && mrd==xi[19:15]) ? m_forward_data:
        (w_forward2 && wrd2==xi[19:15]) ? wr2:(w_forward1 && wrd1==xi[19:15]) ? wr1:
        (w_forward && wrd==xi[19:15]) ? wr:xa;
    wire [31:0] x_b=xi[24:20]==0 ? 0:
        (m_forward2 && mrd2==xi[24:20]) ? mr2:(m_forward1 && mrd1==xi[24:20]) ? mr1:
        (m_forward && mrd==xi[24:20]) ? m_forward_data:
        (w_forward2 && wrd2==xi[24:20]) ? wr2:(w_forward1 && wrd1==xi[24:20]) ? wr1:
        (w_forward && wrd==xi[24:20]) ? wr:xb;
    // Keep ordinary AXI Load data out of branch/JALR next-PC control.
    // Only a matched cache-array probe can bypass into branch control.
    // Ordinary AXI load responses still interlock these consumers through WB.
    wire m_control_forward=PROBE_CONTROL_FORWARD && fast_hit_confirm && mwe && mrd!=0 && CONTROL_LOAD_FORMATS[mfun];
    wire m_alu_forward=mv && mwe && mrd!=0 && !mfault && !mmem;
    wire jalr_m_forward=mv && m_write_rd && !mfault && !mmem;
    wire [31:0] jump_base=p1_zero ? 0:
        (m_forward2 && mrd2==xi[19:15]) ? mr2:(m_forward1 && p1_m1) ? mr1:(jalr_m_forward && p1_m0) ? mr:
        (w_forward2 && wrd2==xi[19:15]) ? wr2:(w_forward1 && p1_w1) ? wr1:(w_forward && p1_w0) ? wr:xa;
    wire [31:0] control_a=xi[19:15]==0 ? 0:
        (m_forward2 && mrd2==xi[19:15]) ? mr2:(m_forward1 && mrd1==xi[19:15]) ? mr1:
        (m_control_forward && mrd==xi[19:15]) ? probe_load_result:
        (m_alu_forward && mrd==xi[19:15]) ? mr:
        (w_forward2 && wrd2==xi[19:15]) ? wr2:(w_forward1 && wrd1==xi[19:15]) ? wr1:
        (w_forward && wrd==xi[19:15]) ? wr:xa;
    wire [31:0] control_b=xi[24:20]==0 ? 0:
        (m_forward2 && mrd2==xi[24:20]) ? mr2:(m_forward1 && mrd1==xi[24:20]) ? mr1:
        (m_control_forward && mrd==xi[24:20]) ? probe_load_result:
        (m_alu_forward && mrd==xi[24:20]) ? mr:
        (w_forward2 && wrd2==xi[24:20]) ? wr2:(w_forward1 && wrd1==xi[24:20]) ? wr1:
        (w_forward && wrd==xi[24:20]) ? wr:xb;
    wire branch_second=xcount==2 && xi1[6:0]==7'h63;
    wire control_first=xcount==2 && (op==7'h63 || op==7'h6f || op==7'h67);
    wire control_consumer=op==7'h63 || op==7'h67;
    reg [4:0] xother;
    wire [4:0] x1rs1=(xcount>=3 && !branch_third) ? xother:xi1[19:15],x1rs2=branch_third ? xi2[19:15]:xi1[24:20];
    wire x1use1=(xcount>=3 && !branch_third) || (!jump_second && !(xi1[6:0]==7'h37 || xi1[6:0]==7'h17));
    wire x1use2=branch_third || xcount==2 && (xi1[6:0]==7'h33 || xi1[6:0]==7'h63);
    wire [31:0] x1_a=x1rs1==0 ? 0:(x_constant && x1rs1==xi[11:7]) ? x_constant_value:(m_forward2 && mrd2==x1rs1) ? mr2:(m_forward1 && mrd1==x1rs1) ? mr1:
        (m_forward && mrd==x1rs1 && !branch_second) ? m_forward_data:
        (m_alu_forward && mrd==x1rs1) ? mr:
        (w_forward2 && wrd2==x1rs1) ? wr2:(w_forward1 && wrd1==x1rs1) ? wr1:(w_forward && wrd==x1rs1) ? wr:x1a;
    wire [31:0] x1_b=x1rs2==0 ? 0:(x_constant && x1rs2==xi[11:7]) ? x_constant_value:(m_forward2 && mrd2==x1rs2) ? mr2:(m_forward1 && mrd1==x1rs2) ? mr1:
        (m_forward && mrd==x1rs2 && !branch_second) ? m_forward_data:
        (m_alu_forward && mrd==x1rs2) ? mr:
        (w_forward2 && wrd2==x1rs2) ? wr2:(w_forward1 && wrd1==x1rs2) ? wr1:(w_forward && wrd==x1rs2) ? wr:x1b;
    // A separate physical mux excludes ordinary AXI Load return data from branch control.
    // Qualifying x1_a/x1_b with !branch_second alone does not cut STA paths.
    wire [31:0] x1_control_a=x1rs1==0 ? 0:(x_constant && x1rs1==xi[11:7]) ? x_constant_value:(m_forward2 && mrd2==x1rs1) ? mr2:(m_forward1 && mrd1==x1rs1) ? mr1:
        (m_control_forward && mrd==x1rs1) ? probe_load_result:
        (m_alu_forward && mrd==x1rs1) ? mr:
        (w_forward2 && wrd2==x1rs1) ? wr2:(w_forward1 && wrd1==x1rs1) ? wr1:(w_forward && wrd==x1rs1) ? wr:x1a;
    wire [31:0] x1_control_b=x1rs2==0 ? 0:(x_constant && x1rs2==xi[11:7]) ? x_constant_value:(m_forward2 && mrd2==x1rs2) ? mr2:(m_forward1 && mrd1==x1rs2) ? mr1:
        (m_control_forward && mrd==x1rs2) ? probe_load_result:
        (m_alu_forward && mrd==x1rs2) ? mr:
        (w_forward2 && wrd2==x1rs2) ? wr2:(w_forward1 && wrd1==x1rs2) ? wr1:(w_forward && wrd==x1rs2) ? wr:x1b;
    wire [31:0] relation_a=p1_zero ? 0:
        (m_forward2 && mrd2==xi[19:15]) ? mr2:(m_forward1 && p1_m1) ? mr1:(m_alu_forward && p1_m0) ? mr:
        (w_forward2 && wrd2==xi[19:15]) ? wr2:(w_forward1 && p1_w1) ? wr1:(w_forward && p1_w0) ? wr:xa;
    wire [31:0] relation_b=p2_zero ? 0:
        (m_forward2 && mrd2==xi[24:20]) ? mr2:(m_forward1 && p2_m1) ? mr1:(m_alu_forward && p2_m0) ? mr:
        (w_forward2 && wrd2==xi[24:20]) ? wr2:(w_forward1 && p2_w1) ? wr1:(w_forward && p2_w0) ? wr:xb;
    wire [31:0] x1_relation_a=s1_zero ? 0:(x_constant && s1_constant_alias) ? x_constant_value:
        (m_forward2 && mrd2==x1rs1) ? mr2:(m_forward1 && s1_m1) ? mr1:(m_alu_forward && s1_m0) ? mr:
        (w_forward2 && wrd2==x1rs1) ? wr2:(w_forward1 && s1_w1) ? wr1:(w_forward && s1_w0) ? wr:x1a;
    wire [31:0] x1_relation_b=s2_zero ? 0:(x_constant && s2_constant_alias) ? x_constant_value:
        (m_forward2 && mrd2==x1rs2) ? mr2:(m_forward1 && s2_m1) ? mr1:(m_alu_forward && s2_m0) ? mr:
        (w_forward2 && wrd2==x1rs2) ? wr2:(w_forward1 && s2_w1) ? wr1:(w_forward && s2_w0) ? wr:x1b;
    wire [3:0] equal_bytes_2 /* synthesis syn_keep=1 */;
    assign equal_bytes_2[0]=relation_a[7:0]==relation_b[7:0];
    assign equal_bytes_2[1]=relation_a[15:8]==relation_b[15:8];
    assign equal_bytes_2[2]=relation_a[23:16]==relation_b[23:16];
    assign equal_bytes_2[3]=relation_a[31:24]==relation_b[31:24];
    wire [3:0] equal_bytes_5 /* synthesis syn_keep=1 */;
    assign equal_bytes_5[0]=x1_relation_a[7:0]==x1_relation_b[7:0];
    assign equal_bytes_5[1]=x1_relation_a[15:8]==x1_relation_b[15:8];
    assign equal_bytes_5[2]=x1_relation_a[23:16]==x1_relation_b[23:16];
    assign equal_bytes_5[3]=x1_relation_a[31:24]==x1_relation_b[31:24];
    // Reference upper bits can be checked before RAM data arrives. Compare
    // raw bytes/halves in parallel, then select a one-bit result by load width
    // and offset. No RAM sign bit is expanded into a 32-bit control compare.
    wire [31:0] load_compare_ref[0:3];
    assign load_compare_ref[0]=relation_b;assign load_compare_ref[1]=relation_a;
    assign load_compare_ref[2]=x1_relation_b;assign load_compare_ref[3]=x1_relation_a;
    wire [3:0] raw_load_equal;
    genvar load_compare,raw_byte;
    generate for(load_compare=0;load_compare<4;load_compare=load_compare+1)begin:g_raw_load_compare
        wire [31:0] compare_ref=load_compare_ref[load_compare];
        wire signed_byte_shape /* synthesis syn_keep=1 */=compare_ref[31:8]=={24{compare_ref[7]}};
        wire zero_byte_shape /* synthesis syn_keep=1 */=compare_ref[31:8]==0;
        wire signed_half_shape /* synthesis syn_keep=1 */=compare_ref[31:16]=={16{compare_ref[15]}};
        wire zero_half_shape /* synthesis syn_keep=1 */=compare_ref[31:16]==0;
        wire [3:0] byte_equal /* synthesis syn_keep=1 */;
        wire [1:0] half_equal /* synthesis syn_keep=1 */;
        wire [3:0] word_equal /* synthesis syn_keep=1 */;
        for(raw_byte=0;raw_byte<4;raw_byte=raw_byte+1)begin:g_byte
            assign byte_equal[raw_byte]=d_probe_data[8*raw_byte+:8]==compare_ref[7:0];
            assign word_equal[raw_byte]=d_probe_data[8*raw_byte+:8]==compare_ref[8*raw_byte+:8];
        end
        assign half_equal[0]=d_probe_data[15:0]==compare_ref[15:0];
        assign half_equal[1]=d_probe_data[31:16]==compare_ref[15:0];
        assign raw_load_equal[load_compare]=
            (((CONTROL_LOAD_FORMATS[0] && mfun==0 && signed_byte_shape) || (CONTROL_LOAD_FORMATS[4] && mfun==4 && zero_byte_shape)) && byte_equal[ma[1:0]]) ||
            (((CONTROL_LOAD_FORMATS[1] && mfun==1 && signed_half_shape) || (CONTROL_LOAD_FORMATS[5] && mfun==5 && zero_half_shape)) && half_equal[ma[1]]) ||
            (CONTROL_LOAD_FORMATS[2] && mfun==2 && (&word_equal));
    end endgenerate
    wire branch_probe_a=m_control_forward && !p1_zero && p1_m0 && !(m_forward1 && p1_m1);
    wire branch_probe_b=m_control_forward && !p2_zero && p2_m0 && !(m_forward1 && p2_m1);
    // Compare each forward candidate before the single-bit operand choice.
    wire branch_equal=(branch_probe_a && branch_probe_b) ||
        (branch_probe_a && !branch_probe_b && raw_load_equal[0]) ||
        (!branch_probe_a && branch_probe_b && raw_load_equal[1]) ||
        (!branch_probe_a && !branch_probe_b && (&equal_bytes_2));
    wire second_probe_a=m_control_forward && !s1_zero && s1_m0 && !(m_forward1 && s1_m1) && !(x_constant && s1_constant_alias);
    wire second_probe_b=m_control_forward && !s2_zero && s2_m0 && !(m_forward1 && s2_m1) && !(x_constant && s2_constant_alias);
    // Compare each forward candidate before the single-bit operand choice.
    wire second_equal=(second_probe_a && second_probe_b) ||
        (second_probe_a && !second_probe_b && raw_load_equal[2]) ||
        (!second_probe_a && second_probe_b && raw_load_equal[3]) ||
        (!second_probe_a && !second_probe_b && (&equal_bytes_5));
    reg p1_zero,p1_m0,p1_m1,p1_w0,p1_w1;
    wire [4:0] next_p1_source=fast_return ? saved_return_reg:decode_capture ? drs1:xi[19:15];
    reg p2_zero,p2_m0,p2_m1,p2_w0,p2_w1;
    wire [4:0] next_p2_source=fast_return ? 5'd0:decode_capture ? drs2:xi[24:20];
    reg s1_zero,s1_m0,s1_m1,s1_w0,s1_w1;
    wire [4:0] next_s1_source=decode_capture ? decode_r1:x1rs1;
    reg s2_zero,s2_m0,s2_m1,s2_w0,s2_w1;
    wire [4:0] next_s2_source=decode_capture ? decode_r2:x1rs2;
    reg s1_constant_alias,s2_constant_alias;
    wire x_use1=!(op==7'h37 || op==7'h17 || op==7'h6f || op==7'h0f) &&
                !(op==7'h73 && (xi[14] || xi[14:12]==0));
    wire x_use2=op==7'h33 || op==7'h23 || op==7'h63;
    // Each lane has its own control/data classification: an independent
    // younger branch must not delay the primary ALU's completed-load bypass.
    wire third_branch_load_wait=branch_third && mv && mmem && !mstore && mrd!=0 && x1rs2==mrd;
    wire load_dependency=third_branch_load_wait || mv && mmem && !mstore && mrd!=0 && !(m_forward1 && mrd1==mrd) &&
        ((((control_consumer && (op==7'h67 || funct>=4 || !m_control_forward)) || !m_load_forward) &&
          ((x_use1 && xi[19:15]==mrd) || (x_use2 && xi[24:20]==mrd))) ||
         (xcount>1 && ((branch_second && (xi1[14:12]>=4 || !m_control_forward)) || !m_load_forward) &&
          ((x1use1 && !(x_constant && x1rs1==xi[11:7]) && x1rs1==mrd) || (x1use2 && !(x_constant && x1rs2==xi[11:7]) && x1rs2==mrd))));
    wire [2:0] funct=xi[14:12];
    wire [6:0] f7=xi[31:25];
    wire [31:0] imm_i={{20{xi[31]}},xi[31:20]};
    wire [31:0] imm_s={{20{xi[31]}},xi[31:25],xi[11:7]};
    wire [31:0] imm_b={{19{xi[31]}},xi[31],xi[7],xi[30:25],xi[11:8],1'b0};
    wire [31:0] imm_j={{11{xi[31]}},xi[31],xi[19:12],xi[20],xi[30:21],1'b0};
    // This mux deliberately has no combinational load-response input. Merely
    // disabling the probe on a late load would not remove that STA data path.
    wire [31:0] probe_base=xi[19:15]==0 ? 0:
        (m_forward2 && mrd2==xi[19:15]) ? mr2:(m_forward1 && mrd1==xi[19:15]) ? mr1:
        (m_alu_forward && mrd==xi[19:15]) ? mr:
        (w_forward2 && wrd2==xi[19:15]) ? wr2:(w_forward1 && wrd1==xi[19:15]) ? wr1:
        (w_forward && wrd==xi[19:15]) ? wr:xa;
    wire [31:0] probe_address=probe_base+imm_i;
    wire probe_load_dependency=mv && mmem && !mstore && mrd!=0 && mrd==xi[19:15] && !(m_forward1 && mrd1==mrd);
    wire probe_legal_size=funct==0 || funct==1 || funct==2 || funct==4 || funct==5;
    wire probe_aligned=(!(funct==1 || funct==5) || !probe_address[0]) &&
                       (funct!=2 || !(|probe_address[1:0]));
    wire probe_cacheable=probe_address[31:16]==0 || probe_address[31:16]==16'h1000;
    assign d_probe_valid=PRELOOKUP && resetn && xv && !xe && op==7'h03 &&
        !probe_load_dependency && probe_legal_size && probe_aligned && probe_cacheable;
    assign d_probe_addr={probe_address[31:2],2'b0};
    // Wide RAM enables depend on the safe probe, not the late x_fire control.
    // The small token valid is committed only when this instruction advances.
    assign d_probe_commit=d_probe_valid && x_fire;
    assign d_probe_take=fast_hit_confirm;
    wire [31:0] csr_operand=funct[2] ? {27'b0,xi[19:15]}:x_a;
    reg [31:0] csr_read;
    reg csr_exists, csr_readonly;
    always @* begin
        csr_exists=1; csr_readonly=0; csr_read=0;
        case(xi[31:20])
          12'h300:csr_read=csr_status;
          12'h301:begin csr_read=32'h40000100; csr_readonly=1; end
          12'h304:csr_read=csr_ie;
          12'h305:csr_read=csr_vec;
          12'h340:csr_read=csr_scratch;
          12'h341:csr_read=csr_epc;
          12'h342:csr_read=csr_cause;
          12'h343:csr_read=csr_tval;
          12'h344:begin csr_read=pending_irqs; csr_readonly=1; end
          12'hc00,12'hb00:begin csr_read=cycles[31:0]; csr_readonly=1; end
          12'hc80,12'hb80:begin csr_read=cycles[63:32]; csr_readonly=1; end
          12'hc02,12'hb02:begin csr_read=retired[31:0]; csr_readonly=1; end
          12'hc82,12'hb82:begin csr_read=retired[63:32]; csr_readonly=1; end
          12'hf11,12'hf12,12'hf13,12'hf14:begin csr_read=0; csr_readonly=1; end
          default:csr_exists=0;
        endcase
    end

    // Only non-trapping integer operations enter the younger lane.
    function simple_legal;
        input [31:0] ins;
        begin
            case(ins[6:0])
              7'h37,7'h17:simple_legal=1;
              7'h13:simple_legal=(ins[14:12]!=1 || ins[31:25]==0) &&
                  (ins[14:12]!=5 || ins[31:25]==0 || ins[31:25]==7'h20);
              7'h33:simple_legal=ins[31:25]==0 || (ins[31:25]==7'h20 && (ins[14:12]==0 || ins[14:12]==5));
              default:simple_legal=0;
            endcase
        end
    endfunction
    function [31:0] simple_alu;
        input [31:0] ins,pc,a,b;
        reg [31:0] rhs;
        begin
            rhs=ins[6:0]==7'h13 ? {{20{ins[31]}},ins[31:20]}:b;
            if(ins[6:0]==7'h37)simple_alu={ins[31:12],12'b0};
            else if(ins[6:0]==7'h17)simple_alu=pc+{ins[31:12],12'b0};
            else case(ins[14:12])
              0:simple_alu=ins[6:0]==7'h33 && ins[30] ? a-b:a+rhs;
              1:simple_alu=a<<rhs[4:0];
              2:simple_alu={31'b0,$signed(a)<$signed(rhs)};
              3:simple_alu={31'b0,a<rhs};
              4:simple_alu=a^rhs;
              5:if(ins[30])simple_alu=$signed(a)>>>rhs[4:0];else simple_alu=a>>rhs[4:0];
              6:simple_alu=a|rhs;
              7:simple_alu=a&rhs;
            endcase
        end
    endfunction
    function [31:0] predict_pc;
        input [31:0] pc;
        reg [BP_BITS-1:0] idx;
        begin
            idx=pc[BP_BITS+1:2];
            predict_pc=pc+4;
            if(PREDICT && bp_valid[idx] && bp_tag[idx]==pc[31:BP_BITS+2] && bp_count[idx][1])
                predict_pc=bp_return[idx] && ras_count!=0 ? ras_top:bp_target[idx];
        end
    endfunction
    // A conservative straight-line flag is sampled with each prediction.
    // It avoids target-data -> full-PC compare -> next BTB lookup in IF.
    // A predicted branch to PC+4 may terminate a packet early; semantics
    // remain identical because the next request still starts at that PC.
    function predict_linear;
        input [31:0] pc;
        reg [BP_BITS-1:0] idx;
        begin
            idx=pc[BP_BITS+1:2];
            predict_linear=!(PREDICT && bp_valid[idx] && bp_tag[idx]==pc[31:BP_BITS+2] && bp_count[idx][1]);
        end
    endfunction
    wire first_mask=di[6:0]==7'h13 && di[14:12]==1 && di[31:20]==12'd31 && di[11:7]!=0 && !de;
    wire [4:0] mask_other=di2[19:15]==di1[11:7] ? di2[24:20]:di2[19:15];
    wire fused_decode=WIDE_FRONT && FUSION && iq_count>=3 && first_mask &&
        !iq_error[iq_h1] && !iq_error[iq_h2] && iq_linear[iq_head] && iq_linear[iq_h1] &&
        di1[6:0]==7'h13 && di1[14:12]==5 && di1[31:20]==12'h41f && di1[19:15]==di[11:7] &&
        di1[11:7]!=0 && di1[11:7]!=di[11:7] &&
        di2[6:0]==7'h33 && di2[31:25]==0 && di2[14:12]==7 && di2[11:7]==di1[11:7] &&
        (di2[19:15]==di1[11:7] || di2[24:20]==di1[11:7]) &&
        mask_other!=di[11:7] && mask_other!=di1[11:7];
    wire [31:0] di1_target=iq_lane_pc[1]+{{19{di1[31]}},di1[31],di1[7],di1[30:25],di1[11:8],1'b0};
    // All valid instruction PCs are 4-byte aligned; branch immediate bit 1
    // (instruction bit 8) therefore decides target alignment without an adder.
    wire second_branch_legal=di1[6:0]==7'h63 && (di1[14:12]<2 || di1[14:12]>=4) && !di1[8];
    wire pair_use1=di1[6:0]!=7'h37 && di1[6:0]!=7'h17;
    wire pair_use2=di1[6:0]==7'h33 || di1[6:0]==7'h63;
    // Do not consume a possible fusion prefix as the younger ordinary lane.
    wire second_mask=di1[6:0]==7'h13 && di1[14:12]==1 && di1[31:20]==12'd31 && di1[11:7]!=0;
    wire first_writes=simple_legal(di) || di[6:0]==7'h03 || di[6:0]==7'h6f || di[6:0]==7'h67;
    wire first_control_legal=(di[6:0]==7'h63 && (di[14:12]<2 || di[14:12]>=4)) || di[6:0]==7'h6f || (di[6:0]==7'h67 && di[14:12]==0);
    // The JALR base is the preceding AUIPC result, not a register-file read.
    // Target bit 1 is known from the immediate; misaligned targets stay single.
    wire call_pair=di[6:0]==7'h17 && di[11:7]!=0 && di1[6:0]==7'h67 &&
        di1[14:12]==0 && di1[19:15]==di[11:7] && !di1[21];
    wire [31:0] call_target=(dp+{di[31:12],12'b0}+{{20{di1[31]}},di1[31:20]}) & 32'hfffffffe;
    wire decode_constant=di[11:7]!=0 && (di[6:0]==7'h37 || di[6:0]==7'h17 ||
        (di[6:0]==7'h13 && di[14:12]==0 && di[19:15]==0));
    wire [31:0] decode_constant_value=di[6:0]==7'h37 ? {di[31:12],12'b0}:
        di[6:0]==7'h17 ? dp+{di[31:12],12'b0}:{{20{di[31]}},di[31:20]};
    wire paired_decode=WIDE_FRONT && DUAL_ISSUE && iq_count>=2 && !de && !iq_error[iq_h1] && !(FUSION && second_mask) &&
        (iq_linear[iq_head] || first_control_legal) &&
        (simple_legal(di) || di[6:0]==7'h03 || di[6:0]==7'h23 || first_control_legal) &&
        (simple_legal(di1) || (!first_control_legal && second_branch_legal) || call_pair) &&
        !(first_writes && !call_pair && !decode_constant && di[11:7]!=0 && ((pair_use1 && di[11:7]==di1[19:15]) ||
          (pair_use2 && di[11:7]==di1[24:20])));
    wire wait_fusion=WIDE_FRONT && FUSION && first_mask && iq_linear[iq_head] && iq_count<3 &&
        (iq_count<2 || (di1[6:0]==7'h13 && di1[14:12]==5 && di1[31:20]==12'h41f && di1[19:15]==di[11:7]));
    // Four sequential RV32I operations: bit-mask construction plus an SRLI
    // reading the unchanged source of the first SLLI. All original register
    // results and retirement events are retained; no PC/function recognition.
    wire four_decode=FOUR_FUSION && fused_decode && iq_count>=4 &&
        !iq_error[iq_h3] && iq_linear[iq_h2] &&
        di3[6:0]==7'h13 && di3[14:12]==5 && di3[31:25]==0 &&
        di3[19:15]==di[19:15] && di[19:15]!=di[11:7] && di[19:15]!=di1[11:7] &&
        di3[11:7]!=0 && di3[11:7]!=di[11:7] && di3[11:7]!=di1[11:7];
    // The secondary ALU is immediate-only, so its otherwise unused second
    // register read is reused by a third BEQ/BNE against x0. No new RF read
    // port is added. All three instructions are individually retired.
    wire [4:0] third_rs=di2[19:15];
    wire triple_branch_decode=TRIPLE_BRANCH && WIDE_FRONT && DUAL_ISSUE && iq_count>=3 &&
        !de && !iq_error[iq_h1] && !iq_error[iq_h2] && iq_linear[iq_head] && iq_linear[iq_h1] &&
        simple_legal(di) && !first_mask && simple_legal(di1) && di1[6:0]==7'h13 && !second_mask &&
        di2[6:0]==7'h63 && di2[14:12]<2 && di2[24:20]==0 && !di2[8] &&
        (di[11:7]==0 || di[11:7]!=di1[19:15]) &&
        (third_rs==0 || ((di[11:7]==0 || third_rs!=di[11:7]) && (di1[11:7]==0 || third_rs!=di1[11:7])));
    wire [31:0] third_target=dp+8+{{19{di2[31]}},di2[31],di2[7],di2[30:25],di2[11:8],1'b0};
    wire [2:0] decode_count=four_decode ? 4:fused_decode ? 3:triple_branch_decode ? 3:paired_decode ? 2:1;
    // Keep late controls in predicate form: encoding a count and decoding it
    // again unnecessarily puts FOUR_FUSION's fourth instruction on each path.
    // A second-word branch/JALR cannot also be a fusion or triple prefix.
    wire decode_ge2=fused_decode || triple_branch_decode || paired_decode;
    wire decode_ge3=fused_decode || triple_branch_decode;
    wire decode_branch_second=paired_decode && di1[6:0]==7'h63;
    wire decode_jump_second=paired_decode && call_pair;
    wire decode_branch_first_pair=paired_decode && di[6:0]==7'h63;
    wire [4:0] decode_r1=fused_decode ? mask_other:di1[19:15];
    wire [4:0] decode_r2=triple_branch_decode ? third_rs:di1[24:20];
    // Read both possible first-extra operands before the late fusion decision.
    // Fusion selects data after RF and WB forwarding, not an RF address.
    wire [31:0] rval_extra1_normal=di1[19:15]==0 ? 0:(w_forward2 && wrd2==di1[19:15]) ? wr2:
        (w_forward1 && wrd1==di1[19:15]) ? wr1:(w_forward && wrd==di1[19:15]) ? wr:rf_rdata[2];
    wire [31:0] rval_extra1_mask=mask_other==0 ? 0:(w_forward2 && wrd2==mask_other) ? wr2:
        (w_forward1 && wrd1==mask_other) ? wr1:(w_forward && wrd==mask_other) ? wr:rf_rdata[6];
    wire [31:0] rval_extra1=fused_decode ? rval_extra1_mask:rval_extra1_normal;
    // The triple-branch decision also selects data after parallel reads.
    wire [31:0] rval_extra2_normal=di1[24:20]==0 ? 0:(w_forward2 && wrd2==di1[24:20]) ? wr2:
        (w_forward1 && wrd1==di1[24:20]) ? wr1:(w_forward && wrd==di1[24:20]) ? wr:rf_rdata[3];
    wire [31:0] rval_extra2_third=third_rs==0 ? 0:(w_forward2 && wrd2==third_rs) ? wr2:
        (w_forward1 && wrd1==third_rs) ? wr1:(w_forward && wrd==third_rs) ? wr:rf_rdata[7];
    wire [31:0] rval_extra2=triple_branch_decode ? rval_extra2_third:rval_extra2_normal;
    // Only x1/x5 return hints use this path. Two fixed register taps and WB
    // bypass pre-read the alternative-path operand in ID, with no late Load
    // response or new cache access. Held EX groups preserve arriving WB data.
    wire [31:0] decode_follow_word=triple_branch_decode ? iq_lane_follow_inst[2]:decode_branch_second ? iq_lane_follow_inst[1]:iq_lane_follow_inst[0];
    wire [31:0] decode_follow_next=triple_branch_decode ? iq_lane_follow_next[2]:decode_branch_second ? iq_lane_follow_next[1]:iq_lane_follow_next[0];
    wire [1:0] decode_replay_index=decode_follow_next[5:4];
    wire decode_follow_return=decode_follow_word[6:0]==7'h67 && decode_follow_word[14:12]==0 && decode_follow_word[11:7]==0 &&
        decode_follow_word[31:20]==0 && (decode_follow_word[19:15]==1 || decode_follow_word[19:15]==5);
    wire [4:0] decode_return_reg=decode_follow_word[17] ? 5'd5:5'd1;
    wire [31:0] decode_return_ra=(w_forward2 && wrd2==decode_return_reg) ? wr2:(w_forward1 && wrd1==decode_return_reg) ? wr1:
        (w_forward && wrd==decode_return_reg) ? wr:decode_follow_word[17] ? rf_rdata[4]:rf_rdata[5];
    wire [4:0] saved_return_reg=x_follow_inst[17] ? 5'd5:5'd1;
    wire [31:0] return_ra=(w_forward2 && wrd2==saved_return_reg) ? wr2:(w_forward1 && wrd1==saved_return_reg) ? wr1:
        (w_forward && wrd==saved_return_reg) ? wr:x_follow_ra;
    wire [31:0] result1=jump_second ? xp+8:(xcount>=3 && !branch_third) ? (x_a[0] ? x1_a:32'b0):simple_alu(xi1,xpc1,x1_a,x1_b);
    wire [31:0] branch_pc=xbranch_pc;
    wire [31:0] branch_inst=branch_third ? xi2:(branch_second || jump_second) ? xi1:xi;
    wire [31:0] branch_imm={{19{branch_inst[31]}},branch_inst[31],branch_inst[7],branch_inst[30:25],branch_inst[11:8],1'b0};
    wire [31:0] packet_prediction=xcount>1 ? xn_last:xn;

    wire [31:0] first_control_target=op==7'h67 ? (jump_base+imm_i)&32'hfffffffe:xbranch_target;
    wire first_control_wrong=op==7'h63 ? (taken ? xtaken_wrong:xfall_wrong):
        op==7'h6f ? xtaken_wrong:first_control_target!=xn;
    reg [31:0] branch_destination;
    // Conditional/JAL and paired JALR targets are already registered in ID.
    // Their low bits must not depend on the late load-driven taken mux.
    // Single/first JALR clears bit zero. All other control transfers use
    // the registered immediate or paired target, including a second branch.
    wire control_target_misaligned=(branch_second || jump_second || op!=7'h67) ?
        |xbranch_target[1:0]:first_control_target[1];
    reg [31:0] result, address, store_data, actual_next, fault_cause, fault_value, csr_new;
    reg [3:0] strobe;
    reg regwrite, memop, storeop, fault, returnop, serialop, csrwrite, branchop, taken;
    reg pre_alignment_fault;
    reg [31:0] operand2;
    always @* begin
        result=0; address=0; store_data=0; strobe=0;
        branch_destination=0;actual_next=xp+4; regwrite=0; memop=0; storeop=0;
        fault=xe; fault_cause=1; fault_value=xp;
        returnop=0; serialop=0; csrwrite=0; csr_new=0; branchop=0; taken=0;
        operand2=(op==7'h13) ? imm_i:x_b;
        case(op)
          7'h37:begin result={xi[31:12],12'b0}; regwrite=1; end
          7'h17:begin result=xp+{xi[31:12],12'b0}; regwrite=1; end
          7'h6f:begin result=xp+4; regwrite=1; actual_next=xbranch_target; branchop=1; taken=1; end
          7'h67:begin
              result=xp+4; regwrite=1; actual_next=(jump_base+imm_i)&32'hfffffffe; branchop=1; taken=1;
              if(funct!=0)begin fault=1; fault_cause=2; fault_value=xi; end
          end
          7'h63:begin
              branchop=1;
              case(funct)
                0:taken=branch_equal; 1:taken=!branch_equal;
                4:taken=$signed(relation_a)<$signed(relation_b); 5:taken=$signed(relation_a)>=$signed(relation_b);
                6:taken=relation_a<relation_b; 7:taken=relation_a>=relation_b;
                default:begin fault=1; fault_cause=2; fault_value=xi; end
              endcase
              if(taken)actual_next=xbranch_target;
          end
          7'h13,7'h33:begin
              regwrite=1;
              case(funct)
                0:result=(op==7'h33 && f7==7'h20) ? x_a-x_b:x_a+operand2;
                1:result=x_a<<operand2[4:0];
                2:result={31'b0,$signed(x_a)<$signed(operand2)};
                3:result={31'b0,x_a<operand2};
                4:result=x_a^operand2;
                5:begin
                    // A mixed signed/unsigned ternary makes >>> unsigned.
                    if(xi[30])result=$signed(x_a)>>>operand2[4:0];
                    else result=x_a>>operand2[4:0];
                end
                6:result=x_a|operand2; 7:result=x_a&operand2;
              endcase
              if((op==7'h33 && !(f7==0 || (f7==7'h20 && (funct==0 || funct==5)))) ||
                 (op==7'h13 && ((funct==1 && f7!=0) || (funct==5 && f7!=0 && f7!=7'h20))))
                begin fault=1; fault_cause=2; fault_value=xi; end
          end
          7'h03,7'h23:begin
              memop=1; storeop=op==7'h23; regwrite=op==7'h03;
              address=x_a+(storeop ? imm_s:imm_i);
              store_data=x_b << {address[1:0],3'b0};
              case(funct)
                0,4:strobe=4'b0001<<address[1:0];
                1,5:strobe=4'b0011<<address[1:0];
                2:strobe=15;
                default:strobe=0;
              endcase
              if((storeop && funct>2) || (!storeop && !(funct==0 || funct==1 || funct==2 || funct==4 || funct==5)))
                begin fault=1; fault_cause=2; fault_value=xi; end
              else if(((funct==1 || funct==5) && address[0]) || (funct==2 && |address[1:0]))
                begin fault=1; fault_cause=storeop ? 6:4; fault_value=address; end
          end
          7'h0f:begin // FENCE is ordered by the single outstanding LSU.
              serialop=1;
              if(funct!=0)begin fault=1; fault_cause=2; fault_value=xi; end
          end
          7'h73:begin
              serialop=1;
              if(funct==0)begin
                  case(xi)
                    32'h00000073:begin fault=1; fault_cause=11; fault_value=0; end
                    32'h00100073:begin fault=1; fault_cause=3; fault_value=xp; end
                    32'h30200073:begin returnop=1; actual_next=csr_epc; end
                    32'h10500073:begin end // WFI may legally behave as a NOP.
                    default:begin fault=1; fault_cause=2; fault_value=xi; end
                  endcase
              end else if(funct==4)begin fault=1; fault_cause=2; fault_value=xi; end
              else begin
                  regwrite=1; result=csr_read;
                  csrwrite=(funct[1:0]==1) || xi[19:15]!=0;
                  case(funct[1:0])
                    1:csr_new=csr_operand; 2:csr_new=csr_read|csr_operand; 3:csr_new=csr_read&~csr_operand;
                    default:csr_new=csr_read;
                  endcase
                  if(!csr_exists || (csrwrite && csr_readonly))begin fault=1; fault_cause=2; fault_value=xi; end
              end
          end
          default:begin fault=1; fault_cause=2; fault_value=xi; end
        endcase
        branch_destination=actual_next;
        if(branch_third)begin
            branchop=1;taken=xi2[12] ? x1_relation_b!=0:x1_relation_b==0;
            actual_next=taken ? xbranch_target:xp+12;branch_destination=actual_next;
        end
        else if(xcount>=3)actual_next=xp+(xcount==4 ? 16:12);
        else if(xcount==2)begin
            if(control_first)actual_next=first_control_wrong ? branch_destination:xpc1+4;
            else actual_next=xp+8;
            if(jump_second)begin branchop=1;taken=1;actual_next=xbranch_target;branch_destination=xbranch_target;end
            if(branch_second)begin
                branchop=1;
                case(xi1[14:12])
                  0:taken=second_equal;1:taken=!second_equal;
                  4:taken=$signed(x1_relation_a)<$signed(x1_relation_b);5:taken=$signed(x1_relation_a)>=$signed(x1_relation_b);
                  6:taken=x1_relation_a<x1_relation_b;7:taken=x1_relation_a>=x1_relation_b;
                  default:taken=0;
                endcase
                if(taken)begin actual_next=xbranch_target;branch_destination=xbranch_target;end
            end
        end
        pre_alignment_fault=fault || xe;
        if(branchop && taken && control_target_misaligned)begin fault=1; fault_cause=0; fault_value=branch_destination; end
        if(xe)begin fault=1; fault_cause=1; fault_value=xp; end
        // ID already selected the correct packet successor for each direction,
        // including a predicted control followed by a younger ALU. Keep the
        // late load comparison out of first_control_wrong -> wide PC muxes.
        // branch_destination and precise fault calculation above are unchanged.
        if(branch_inst[6:0]==7'h63)
            actual_next=taken ? xpacket_taken_pc:xpacket_fall_pc;
    end

    wire mem_complete=mv && (!mmem || mfault || fast_hit_confirm || (msent && d_rvalid));
    wire m_accept /* synthesis syn_maxfan = 16 */=!mv || mem_complete;
    wire x_fire /* synthesis syn_maxfan = 16 */=xv && m_accept && !load_dependency && !wb_redirect;
    // Compare both conditional-branch successors before operands resolve.
    // The late taken decision selects a single bit, avoiding a PC mux followed
    // by another 32-bit comparison on the load -> branch -> fetch-ready path.
    wire branch_taken_wrong=xtaken_wrong;
    wire branch_fallthrough_wrong=xfall_wrong;
    // Keep the conditional taken result out of the generic next-PC comparator.
    wire [31:0] nonconditional_next=jump_second ? xbranch_target:xcount>=3 ? xp+(xcount==4 ? 16:12):xcount==2 ? xp+8:
        op==7'h6f ? xbranch_target:op==7'h67 ? (jump_base+imm_i)&32'hfffffffe:xp+4;
    // Sequential and PC-relative call successors are known in ID. Carry only
    // their comparison bits through ID/EX, avoiding EX PC add -> PC mux ->
    // 32-bit compare -> redirect fanout. Register-dependent JALR stays in EX.
    wire nonconditional_wrong=jump_second ? xcall_wrong:xcount>1 ? xsequential_wrong:
        op==7'h6f ? xtaken_wrong:op==7'h67 ? first_control_target!=xn:xsequential_wrong;
    // Packet successor comparisons are complete in ID. The late branch
    // result selects one bit directly, including a control-first group.
    // The original first-instruction flags remain for partial group squash.
    wire next_wrong=branch_inst[6:0]==7'h63 ? (taken ? xpacket_taken_wrong:xpacket_fall_wrong):
        control_first ? (first_control_wrong || xsecond_wrong):nonconditional_wrong;
    wire branch_redirect /* synthesis syn_maxfan=8 */=x_fire && !fault && !returnop && next_wrong;
    // Statistics consume a registered event, not the late redirect fanout.
    reg mispredict_event_q;
    // Only a legal JAL/JALR can change the RAS. A paired JALR follows a
    // decode-validated AUIPC; single/first JALR must have funct3 == 0.
    // These conditions exactly cover the faults possible for those groups,
    // keeping conditional-load comparison out of the RAS clock enable.
    wire ras_update=x_fire && !xe && !control_target_misaligned &&
        (op==7'h6f || (op==7'h67 && funct==0) || jump_second);
    // Only a successfully fetched sequential word is reused. It is injected
    // into ID, executes normally, and has no early architectural side effect.
    // For a not-taken conditional branch, target alignment cannot fault.
    // Decode, earlier payload faults and the fallthrough prediction are early.
    wire recovery_candidate_available=!BANKED_RECOVERY || x_recovery_valid;
    wire fallthrough_salvage=WIDE_FRONT && FALLTHROUGH_REUSE && recovery_candidate_available && x_fire &&
        !pre_alignment_fault && !returnop && branch_inst[6:0]==7'h63 &&
        !taken && xpacket_fall_wrong && x_follow_valid && (!control_first || xfall_wrong);
    // Banked mode reinserts the return through ordinary ID/EX. Direct EX
    // injection remains a legacy-only option until its payload is decoupled.
    wire fast_return /* synthesis syn_maxfan=8 */=!BANKED_RECOVERY && RETURN_BYPASS && fallthrough_salvage && !irq_wait && x_follow_return;
    wire return_replay /* synthesis syn_maxfan=8 */=RETURN_TARGET_BUFFER && fallthrough_salvage && !irq_wait && x_follow_return && x_replay_hit;
    wire train_predict_taken=bank_train_prediction[train_pc[BTB_BANK_BITS+1:2]];
    wire [31:0] train_prediction=train_predict_taken ? train_target:train_pc+4;
    wire replay_two=x_replay_two;
    // These alternatives depend only on registered group metadata and early
    // control inputs. The cache comparison selects one PC at the end.
    wire conditional_fall_reuse=WIDE_FRONT && FALLTHROUGH_REUSE && recovery_candidate_available && x_follow_valid &&
        (!control_first || xfall_wrong);
    wire conditional_fall_replay=RETURN_TARGET_BUFFER && conditional_fall_reuse &&
        !irq_wait && x_follow_return && x_replay_hit;
    wire [31:0] conditional_fall_start /* synthesis syn_keep=1 */=conditional_fall_replay ?
        (replay_two ? x_replay_next1:x_replay_next0):conditional_fall_reuse ? x_follow_next:xpacket_fall_pc;
    // Keep the unselected nonconditional input physically free of taken.
    // Reusing redirect_pc here would retain its cache-dependent STA path.
    wire unconditional_first_wrong=op==7'h6f ? xtaken_wrong:first_control_target!=xn;
    wire [31:0] unconditional_group_next=control_first ?
        (unconditional_first_wrong ? first_control_target:xpc1+4):nonconditional_next;
    wire [31:0] unconditional_recovery /* synthesis syn_keep=1 */=wb_redirect ?
        (wret && !wfault ? csr_epc:csr_vec):irq_take ? csr_vec:unconditional_group_next;
    // recovery_start is consumed only on redirect. For a conditional EX
    // redirect the branch is valid, not faulting and not a WB/IRQ redirect.
    wire [31:0] recovery_start=(wb_redirect || irq_take || branch_inst[6:0]!=7'h63) ?
        unconditional_recovery:taken ? xpacket_taken_pc:conditional_fall_start;
    wire redirect /* synthesis syn_maxfan=8 */=wb_redirect || irq_take || branch_redirect;
    wire [31:0] redirect_pc=wb_redirect ? (wret && !wfault ? csr_epc:csr_vec):irq_take ? csr_vec:actual_next;
    wire [4:0] drs1=di[19:15], drs2=di[24:20];
    wire csr_busy=(xv && (op==7'h73 || op==7'h0f)) || (mv && mserial) || (wv && wserial);
    wire decode_serial=di[6:0]==7'h73 || di[6:0]==7'h0f;
    wire decode_capture /* synthesis syn_maxfan = 16 */=dv && !wait_fusion && (!xv || x_fire) && !csr_busy &&
                !(decode_serial && (xv || mv || wv)) && !irq_wait;
    wire d_fire=decode_capture && !redirect;
    wire [31:0] rval1=drs1==0 ? 0:(w_forward2 && wrd2==drs1) ? wr2:(w_forward1 && wrd1==drs1) ? wr1:(w_forward && wrd==drs1) ? wr:rf_rdata[0];
    wire [31:0] rval2=drs2==0 ? 0:(w_forward2 && wrd2==drs2) ? wr2:(w_forward1 && wrd1==drs2) ? wr1:(w_forward && wrd==drs2) ? wr:rf_rdata[1];
    // Loop packets use the same ordered request FIFO and killed-response
    // machinery as external fetches. Snapshot data at admission, so later
    // training/replacement cannot alter an outstanding response.
    wire lb_hit;wire [2:0] lb_words;wire [127:0] lb_data;
    wire lb_exit_valid;wire [31:0] lb_exit_inst,lb_exit_pc;
    reg [3:0] fetch_exit_valid_q;
    reg [31:0] fetch_exit_inst_q[0:3],fetch_exit_next_q[0:3];
    wire lb_exit_return=lb_exit_inst[6:0]==7'h67 && lb_exit_inst[14:12]==0 && lb_exit_inst[11:7]==0 &&
        lb_exit_inst[31:20]==0 && (lb_exit_inst[19:15]==1 || lb_exit_inst[19:15]==5);
    // Prediction only: the normal JALR path still checks the architectural RA.
    wire [31:0] lb_exit_prediction=ras_count!=0 ? ras_top:lb_exit_pc+4;
    wire [31:0] lb_next[0:3];wire [3:0] lb_linear;
    reg bus_hold;
    reg [3:0] fetch_loop_q;
    reg [127:0] fetch_loop_data_q[0:3];
    wire loop_select=LOOP_BUFFER && WIDE_FRONT && FETCH_WORDS==4 && lb_hit && !bus_hold && !fetch_killed;
    wire [31:0] wb_last_pc=wcount==4 ? wp+12:wcount==3 ? wp+8:wcount==2 ? wpc1:wp;
    wire [31:0] wb_last_inst=wcount==4 ? wi3:wcount==3 ? wi2:wcount==2 ? wi1:wi;
    rv_loop_fetch u_loop(.clk(clk),.resetn(resetn),
        .clear(wb_redirect || irq_take || (wv && !wfault && wserial)),
        .commit(LOOP_BUFFER && wv && !wfault),.count(wcount),
        .pc0(wp),.pc1(wpc1),.pc2(wp+8),.pc3(wp+12),
        .inst0(wi),.inst1(wi1),.inst2(wi2),.inst3(wi3),
        .last_pc(wb_last_pc),.last_inst(wb_last_inst),.actual_next(wn),
        .observe(fetch_pop && !fetch_loop_q[fetch_head] && !i_error),
        .observe_base({fetch_pc_q[fetch_head][31:4],4'b0}),.observe_data({i_rdata3,i_rdata2,i_rdata_hi,i_rdata}),
        .exit_valid(lb_exit_valid),.exit_inst(lb_exit_inst),.exit_pc(lb_exit_pc),
        .query_pc(fetch_addr),.hit(lb_hit),.words(lb_words),.data(lb_data),
        .next0(lb_next[0]),.next1(lb_next[1]),.next2(lb_next[2]),.next3(lb_next[3]),.linear(lb_linear));
    always @(posedge clk)begin
        if(!resetn)begin bus_hold<=0;fetch_loop_q<=0;fetch_exit_valid_q<=0;end
        else begin
            if(i_valid)bus_hold<=!i_ready;
            if(fetch_push)begin
                fetch_loop_q[fetch_tail]<=loop_select;fetch_loop_data_q[fetch_tail]<=lb_data;
                fetch_exit_valid_q[fetch_tail]<=loop_select && lb_exit_valid && lb_exit_return && fetch_addr+{27'b0,lb_words,2'b0}==lb_exit_pc;
                fetch_exit_inst_q[fetch_tail]<=lb_exit_inst;fetch_exit_next_q[fetch_tail]<=lb_exit_prediction;
            end
        end
    end
    assign i_valid=resetn && fetch_valid && !loop_select;
    assign i_addr=WIDE_FRONT ? (FETCH_WORDS==4 ? {fetch_addr[31:4],4'b0}:{fetch_addr[31:3],3'b0}):fetch_addr;
    wire fetch_response_ready=resetn && fetch_count!=0 && (fetch_kill_q[fetch_head] || (WIDE_FRONT ? iq_count+fetch_words_q[fetch_head]<=16:(!dv || d_fire)));
    assign i_rready=fetch_response_ready && !fetch_loop_q[fetch_head];
    wire fetch_push=resetn && fetch_valid && (loop_select || i_ready);
    wire fetch_pop=fetch_response_ready && (fetch_loop_q[fetch_head] || i_rvalid);
    wire fetch_error=fetch_loop_q[fetch_head] ? 1'b0:i_error;
    wire [31:0] response_word_offset=fetch_loop_q[fetch_head] ? 0:
        FETCH_WORDS==4 ? {30'b0,fetch_pc_q[fetch_head][3:2]}:{31'b0,fetch_pc_q[fetch_head][2]};
    // First recovery-line prediction reads its registered PC. A separate
    // lookup predicts the next sequential line in parallel. A predicted-taken
    // instruction inserts one setup cycle for the new target, avoiding two
    // cascaded BTB lookups in a clock period.
    // Query all physical words with constant bank-index low bits, then
    // rotate to the logical start. A valid packet never crosses this line.
    wire [31:0] resume_bank_next[0:3],query_bank_next[0:3];
    wire [31:0] resume_word_next[0:3],query_word_next[0:3];
    wire [3:0] resume_bank_linear,query_bank_linear;
    wire [3:0] resume_word_linear,query_word_linear;
    wire [31:0] request_next=loop_select ? lb_next[0]:fetch_resume ? resume_word_next[0]:fetch_next;
    wire [31:0] request_pred1=loop_select ? lb_next[1]:fetch_resume ? resume_word_next[1]:fetch_pred1;
    wire [31:0] request_pred2=loop_select ? lb_next[2]:fetch_resume ? resume_word_next[2]:fetch_pred2;
    wire [31:0] request_pred3=loop_select ? lb_next[3]:fetch_resume ? resume_word_next[3]:fetch_pred3;
    wire [3:0] request_linear=loop_select ? lb_linear:fetch_resume ? resume_word_linear:fetch_linear;
    wire resume_linear=FETCH_WORDS==4 ?
        (fetch_addr[3:2]==0 ? &request_linear:fetch_addr[3:2]==1 ? &request_linear[2:0]:
         fetch_addr[3:2]==2 ? &request_linear[1:0]:request_linear[0]):
        (fetch_addr[2] ? request_linear[0]:&request_linear[1:0]);
    wire normal_two=(FETCH_WORDS==4 ? fetch_addr[3:2]!=3:!fetch_addr[2]) && fetch_linear[0];
    wire normal_three=FETCH_WORDS==4 && fetch_addr[3:2]<2 && normal_two && fetch_linear[1];
    wire normal_four=FETCH_WORDS==4 && fetch_addr[3:2]==0 && normal_three && fetch_linear[2];
    wire [31:0] normal_end=normal_four ? fetch_pred3:normal_three ? fetch_pred2:normal_two ? fetch_pred1:fetch_next;
    wire [31:0] sequential_line=FETCH_WORDS==4 ? {fetch_addr[31:4],4'b0}+16:{fetch_addr[31:3],3'b0}+8;
    // No current prediction result feeds query_pc: these paths are physically
    // separate, including when synthesis ignores mutually exclusive modes.
    wire [31:0] query_pc /* synthesis syn_maxfan=64 */=recovering ? recover_pc:fetch_repredict ? fetch_addr:fetch_resume ? sequential_line:normal_end;
    // Pure address arithmetic: no predictor state is hidden in a function.
    function [31:0] after_line(input [31:0] pc);
        reg [27:0] next_line;
        begin next_line=pc[31:4]+28'd1;after_line={next_line,2'b00,pc[1:0]};end
    endfunction
    // Keep addition before the selection of predicted target/fallthrough.
    // Every candidate is derived directly from registered PCs in parallel.
    wire [31:0] resume_line_end /* synthesis syn_keep=1 */=after_line(fetch_addr);
    wire [31:0] recover_line_end /* synthesis syn_keep=1 */=after_line(recover_pc);
    wire [31:0] next_line_end /* synthesis syn_keep=1 */=after_line(fetch_next);
    wire [31:0] pred1_line_end /* synthesis syn_keep=1 */=after_line(fetch_pred1);
    wire [31:0] pred2_line_end /* synthesis syn_keep=1 */=after_line(fetch_pred2);
    wire [31:0] pred3_line_end /* synthesis syn_keep=1 */=after_line(fetch_pred3);
    wire [27:0] sequential_after_index=fetch_addr[31:4]+28'd2;
    wire [31:0] sequential_line_end /* synthesis syn_keep=1 */=FETCH_WORDS==4 ?
        {sequential_after_index,4'b0}:after_line(sequential_line);
    wire [31:0] query_line_end /* synthesis syn_keep=1 */=recovering ? recover_line_end:
        fetch_repredict ? resume_line_end:fetch_resume ? sequential_line_end:
        normal_four ? pred3_line_end:normal_three ? pred2_line_end:normal_two ? pred1_line_end:next_line_end;
    genvar predict_bank;
    generate for(predict_bank=0;predict_bank<4;predict_bank=predict_bank+1)begin:g_line_predict
        localparam [1:0] BANK=predict_bank;
        localparam [2:0] WORD=predict_bank;
        wire [31:0] resume_pc={fetch_addr[31:4],BANK,fetch_addr[1:0]};
        wire [31:0] bank_pc={query_pc[31:4],BANK,query_pc[1:0]};
        localparam [1:0] NEXT_BANK=predict_bank+1;
        wire [31:0] resume_linear_pc /* synthesis syn_keep=1 */=predict_bank==3 ? resume_line_end:
            {fetch_addr[31:4],NEXT_BANK,fetch_addr[1:0]};
        wire [31:0] query_linear_pc /* synthesis syn_keep=1 syn_maxfan=64 */=predict_bank==3 ? query_line_end:
            {query_pc[31:4],NEXT_BANK,query_pc[1:0]};
        wire [2:0] resume_index={1'b0,fetch_addr[3:2]}+WORD;
        wire [2:0] query_index={1'b0,query_pc[3:2]}+WORD;
        // Explicit table/RAS dependencies are essential: a held line address
        // must still observe training writes and return-stack changes.
        wire [BP_BITS-1:0] resume_row=resume_pc[BP_BITS+1:2];
        wire [BP_BITS-1:0] query_row=bank_pc[BP_BITS+1:2];
        localparam LOCAL_BANK=predict_bank % BTB_BANKS;
        wire [BTB_ROW_BITS-1:0] resume_local_row=(resume_pc>>(BTB_BANK_BITS+2)) & (BTB_ROWS-1);
        wire [BTB_ROW_BITS-1:0] query_local_row=(bank_pc>>(BTB_BANK_BITS+2)) & (BTB_ROWS-1);
        wire resume_taken=PREDICT && g_btb_bank[LOCAL_BANK].valid_bits[resume_local_row] &&
            g_btb_bank[LOCAL_BANK].tag[resume_local_row]==resume_pc[31:BP_BITS+2] && g_btb_bank[LOCAL_BANK].counter[resume_local_row][1];
        wire query_taken=PREDICT && g_btb_bank[LOCAL_BANK].valid_bits[query_local_row] &&
            g_btb_bank[LOCAL_BANK].tag[query_local_row]==bank_pc[31:BP_BITS+2] && g_btb_bank[LOCAL_BANK].counter[query_local_row][1];
        assign resume_bank_next[predict_bank]=resume_taken ?
            (g_btb_bank[LOCAL_BANK].return_bits[resume_local_row] && ras_count!=0 ? ras_top:g_btb_bank[LOCAL_BANK].target[resume_local_row]):resume_linear_pc;
        assign query_bank_next[predict_bank]=query_taken ?
            (g_btb_bank[LOCAL_BANK].return_bits[query_local_row] && ras_count!=0 ? ras_top:g_btb_bank[LOCAL_BANK].target[query_local_row]):query_linear_pc;
        assign resume_bank_linear[predict_bank]=!resume_taken;
        assign query_bank_linear[predict_bank]=!query_taken;
        // Clear unused cross-line suffixes. Only the prefix limited by
        // wide_count may enter IQ or contribute a packet successor.
        assign resume_word_next[predict_bank]=resume_index<4 ? resume_bank_next[resume_index[1:0]]:32'b0;
        assign query_word_next[predict_bank]=query_index<4 ? query_bank_next[query_index[1:0]]:32'b0;
        assign resume_word_linear[predict_bank]=resume_index<4 && resume_bank_linear[resume_index[1:0]];
        assign query_word_linear[predict_bank]=query_index<4 && query_bank_linear[query_index[1:0]];
    end endgenerate
    wire [31:0] query_next=query_word_next[0],query_pred1=query_word_next[1];
    wire [31:0] query_pred2=query_word_next[2],query_pred3=query_word_next[3];
    wire [3:0] query_linear=query_word_linear;
    wire wide_two=(FETCH_WORDS==4 ? fetch_addr[3:2]!=3:!fetch_addr[2]) && request_linear[0];
    wire wide_three=FETCH_WORDS==4 && fetch_addr[3:2]<2 && wide_two && request_linear[1];
    wire wide_four=FETCH_WORDS==4 && fetch_addr[3:2]==0 && wide_three && request_linear[2];
    wire [2:0] wide_count=loop_select ? lb_words:wide_four ? 4:wide_three ? 3:wide_two ? 2:1;
    wire [31:0] wide_end=wide_count==4 ? request_pred3:wide_count==3 ? request_pred2:wide_count==2 ? request_pred1:request_next;
    wire [127:0] fetch_response=fetch_loop_q[fetch_head] ? fetch_loop_data_q[fetch_head]:{i_rdata3,i_rdata2,i_rdata_hi,i_rdata};
    // A redirect resets queue pointers/count below. A same-edge write to
    // discarded payload is harmless, and has no late EX fault/branch fanout.
    wire enqueue=fetch_pop && !fetch_kill_q[fetch_head];
    wire [2:0] enqueue_count=enqueue ? fetch_words_q[fetch_head]:0;
    // Every valid lane belongs to the same fetched line (wide_count stops at
    // its boundary). Keep PC[31:4] out of a response-side carry chain. Preserve
    // the low two bits, including an address carried by a faulting request.
    wire [31:0] response_pc=fetch_pc_q[fetch_head];
    wire [31:0] response_lane_pc[0:3];
    genvar pc_lane;
    generate for(pc_lane=0;pc_lane<4;pc_lane=pc_lane+1)begin:g_response_pc
        localparam [1:0] LANE=pc_lane;
        wire [1:0] word_offset=response_pc[3:2]+LANE;
        assign response_lane_pc[pc_lane]=fetch_loop_q[fetch_head] ? response_pc+4*pc_lane:{response_pc[31:4],word_offset,response_pc[1:0]};
    end endgenerate
    // A sequential write packet reaches each index-modulo-four bank at most
    // once. Give each bank a fixed low index and a local two-bit row decoder.
    wire [1:0] enqueue_lane[0:3];
    wire [3:0] enqueue_slot[0:3];
    genvar iq_bank;
    generate for(iq_bank=0;iq_bank<4;iq_bank=iq_bank+1)begin:g_iq_write_bank
        localparam [1:0] BANK=iq_bank;
        wire [1:0] row=iq_tail[3:2]+{1'b0,(BANK<iq_tail[1:0])};
        assign enqueue_lane[iq_bank]=BANK-iq_tail[1:0];
        assign enqueue_slot[iq_bank]={row,BANK};
    end endgenerate

    // Four banks, one write and one read per bank. Consecutive packet slots
    // have distinct low two index bits, including circular queue wraparound.
    wire [159:0] iq_bank_read[0:3];
    wire [31:0] iq_lane_pc[0:3],iq_lane_inst[0:3],iq_lane_next[0:3];
    wire [31:0] iq_lane_follow_inst[0:3],iq_lane_follow_next[0:3];
    genvar payload_bank,payload_row,payload_lane;
    generate for(payload_bank=0;payload_bank<4;payload_bank=payload_bank+1)begin:g_iq_payload
        localparam [1:0] BANK=payload_bank;
        reg [159:0] payload[0:3] /* synthesis syn_ramstyle="lut_ram" */;
        wire [1:0] read_row=iq_head[3:2]+{1'b0,(BANK<iq_head[1:0])};
        wire [1:0] write_row=enqueue_slot[payload_bank][3:2];
        wire [1:0] which=enqueue_lane[payload_bank];
        wire [31:0] next_pc=which==0 ? fetch_next_q[fetch_head]:which==1 ? fetch_pred1_q[fetch_head]:
                                    which==2 ? fetch_pred2_q[fetch_head]:fetch_pred3_q[fetch_head];
        wire exit_word=fetch_loop_q[fetch_head] && which+1==enqueue_count && fetch_exit_valid_q[fetch_head];
        wire [31:0] follow_inst=exit_word ? fetch_exit_inst_q[fetch_head]:fetch_response[32*(response_word_offset+which+1)+:32];
        wire [31:0] follow_pc=exit_word ? fetch_exit_next_q[fetch_head]:
            which==0 ? fetch_pred1_q[fetch_head]:which==1 ? fetch_pred2_q[fetch_head]:which==2 ? fetch_pred3_q[fetch_head]:0;
        assign iq_bank_read[payload_bank]=payload[read_row];
        always @(posedge clk)if(resetn && WIDE_FRONT && enqueue && which<enqueue_count)
            payload[write_row]<={follow_pc,follow_inst,next_pc,fetch_response[32*(response_word_offset+which)+:32],response_lane_pc[which]};
        for(payload_row=0;payload_row<4;payload_row=payload_row+1)begin:g_debug_view
            assign iq_pc_storage[4*payload_row+payload_bank]=payload[payload_row][31:0];
            assign iq_inst_storage[4*payload_row+payload_bank]=payload[payload_row][63:32];
            assign iq_next_storage[4*payload_row+payload_bank]=payload[payload_row][95:64];
            assign iq_follow_inst[4*payload_row+payload_bank]=payload[payload_row][127:96];
            assign iq_follow_next[4*payload_row+payload_bank]=payload[payload_row][159:128];
        end
    end endgenerate
    generate for(payload_lane=0;payload_lane<4;payload_lane=payload_lane+1)begin:g_iq_lane
        wire [3:0] slot=iq_head+payload_lane;
        wire [159:0] data=iq_bank_read[slot[1:0]];
        wire selected=slot<3 && recovery_slot_mask[slot[1:0]];
        assign iq_lane_pc[payload_lane]=selected ? recovery_pc_bank[recovery_active_bank][32*slot[1:0]+:32]:data[31:0];
        assign iq_lane_inst[payload_lane]=selected ? recovery_inst_bank[recovery_active_bank][32*slot[1:0]+:32]:data[63:32];
        assign iq_lane_next[payload_lane]=selected ? recovery_next_bank[recovery_active_bank][32*slot[1:0]+:32]:data[95:64];
        assign iq_lane_follow_inst[payload_lane]=data[127:96];
        assign iq_lane_follow_next[payload_lane]=data[159:128];
    end endgenerate
`ifdef RTL_SIM
    initial if(!BANKED_RECOVERY)$fatal(1,"Area banked IQ requires BANKED_RECOVERY=1");
    genvar audit_lane;
    generate for(audit_lane=0;audit_lane<4;audit_lane=audit_lane+1)begin:g_iq_bank_audit
        wire [3:0] slot=iq_head+audit_lane;
        always @(negedge clk)if(resetn && WIDE_FRONT && iq_count>audit_lane)begin
            if(iq_lane_pc[audit_lane]!==iq_pc[slot] || iq_lane_inst[audit_lane]!==iq_inst[slot] ||
               iq_lane_next[audit_lane]!==iq_next[slot] || iq_lane_follow_inst[audit_lane]!==iq_follow_inst[slot] ||
               iq_lane_follow_next[audit_lane]!==iq_follow_next[slot])$fatal(1,"IQ_BANK_VIEW_MISMATCH");
        end
    end endgenerate
`endif

    wire [2:0] dequeue_count=d_fire ? decode_count:0;
    assign d_valid=resetn && mv && mmem && !mfault && !msent && !fast_hit_confirm && !wb_redirect;
    assign d_addr={ma[31:2],2'b0}; assign d_write=mstore;
    assign d_wdata=ms; assign d_wstrb=mstrb;
    assign d_rready=resetn && mv && mmem && msent && !wb_redirect;
    assign stage_valid={wv,mv,xv,dv,(fetch_valid || fetch_count!=0)};
    // Alignment is checked before issuing the request. Select only the
    // byte/halfword lanes needed instead of a full 32-bit variable shift.
    wire [15:0] load_half=ma[1] ? memory_load_data[31:16]:memory_load_data[15:0];
    wire [7:0] load_byte=ma[0] ? load_half[15:8]:load_half[7:0];
    reg [31:0] load_result;
    always @* case(mfun)
        0:load_result={{24{load_byte[7]}},load_byte};
        1:load_result={{16{load_half[15]}},load_half};
        4:load_result={24'b0,load_byte};
        5:load_result={16'b0,load_half};
        default:load_result=memory_load_data;
    endcase
    wire [15:0] probe_half=ma[1] ? d_probe_data[31:16]:d_probe_data[15:0];
    wire [7:0] probe_byte=ma[0] ? probe_half[15:8]:probe_half[7:0];
    reg [31:0] probe_load_result;
    always @* case(mfun)
      0:probe_load_result={{24{probe_byte[7]}},probe_byte};
      1:probe_load_result={{16{probe_half[15]}},probe_half};
      4:probe_load_result={24'b0,probe_byte};
      5:probe_load_result={16'b0,probe_half};
      default:probe_load_result=d_probe_data;
    endcase
    wire [31:0] decode_target0=dp+(di[6:0]==7'h6f ? {{11{di[31]}},di[31],di[19:12],di[20],di[30:21],1'b0}:{{19{di[31]}},di[31],di[7],di[30:25],di[11:8],1'b0});
    // A bank stays reserved while its candidate belongs to the current EX
    // group or any live IQ overlay slot. Lack of a free bank only disables
    // salvage for the new group; normal execution/fetch remains available.
    wire recovery_iq_live=|recovery_slot_mask;
    wire recovery_busy0=(recovery_iq_live && !recovery_active_bank) ||
        (xv && x_recovery_valid && !x_recovery_bank);
    wire recovery_busy1=(recovery_iq_live && recovery_active_bank) ||
        (xv && x_recovery_valid && x_recovery_bank);
    wire recovery_capture_bank=recovery_busy0;
    wire decode_recovery_follow_valid=triple_branch_decode ? iq_follow_valid[iq_h2]:
        decode_branch_second ? iq_follow_valid[iq_h1]:iq_follow_valid[iq_head];
    wire decode_recovery_follow_linear=triple_branch_decode ? iq_follow_linear[iq_h2]:
        decode_branch_second ? iq_follow_linear[iq_h1]:iq_follow_linear[iq_head];
    wire [31:0] decode_recovery_branch_pc=triple_branch_decode ? dp+8:decode_branch_second ? dp+4:dp;
    wire recovery_capture=BANKED_RECOVERY && WIDE_FRONT && FALLTHROUGH_REUSE && decode_capture &&
        decode_recovery_follow_valid && (triple_branch_decode || decode_branch_second || di[6:0]==7'h63) &&
        !(recovery_busy0 && recovery_busy1);
    // Normal-path retirement/overwrite candidates are early. A redirect
    // replaces this entire mask, so decode_capture may be used before the
    // late !redirect term in d_fire without consuming a live wrong-path slot.
    wire [2:0] recovery_consumed_mask,recovery_overwritten_mask;
    genvar recovery_entry;
    generate for(recovery_entry=0;recovery_entry<3;recovery_entry=recovery_entry+1)begin:g_recovery_consume
        localparam [3:0] SLOT=recovery_entry;
        assign recovery_consumed_mask[recovery_entry]=decode_capture &&
            (iq_head==SLOT || (decode_ge2 && iq_h1==SLOT) ||
             (decode_ge3 && iq_h2==SLOT) || (four_decode && iq_h3==SLOT));
        // Each physical enqueue bank can overwrite only its own low-bit slot.
        assign recovery_overwritten_mask[recovery_entry]=enqueue &&
            enqueue_lane[recovery_entry]<enqueue_count && enqueue_slot[recovery_entry]==SLOT;
    end endgenerate
    // Prepare both conditional outcomes before the late RAM comparison.
    // No next_wrong -> branch_redirect -> reset/set priority chain follows
    // taken here. All marker bits have one explicit next-state assignment.
    wire [2:0] recovery_keep_mask=WIDE_FRONT ?
        recovery_slot_mask & ~recovery_consumed_mask & ~recovery_overwritten_mask:recovery_slot_mask;
    wire [2:0] recovery_fall_insert=(BANKED_RECOVERY && WIDE_FRONT && conditional_fall_reuse) ?
        (conditional_fall_replay ? {replay_two,2'b11}:3'b001):3'b000;
    wire [2:0] recovery_taken_mask=(!control_target_misaligned && xpacket_taken_wrong) ? 3'b000:recovery_keep_mask;
    wire [2:0] recovery_fall_mask=xpacket_fall_wrong ? recovery_fall_insert:recovery_keep_mask;
    wire recovery_conditional=branch_inst[6:0]==7'h63;
    wire recovery_conditional_ready=x_fire && !pre_alignment_fault && !returnop;
    // Nonconditional alternatives are physically independent of taken, even
    // though their results are ignored when a conditional branch is selected.
    wire recovery_unconditional_wrong=control_first ?
        (unconditional_first_wrong || xsecond_wrong):nonconditional_wrong;
    wire recovery_unconditional_fault=pre_alignment_fault ||
        ((op==7'h6f || op==7'h67 || jump_second) && control_target_misaligned);
    wire recovery_unconditional_flush=!recovery_conditional && x_fire &&
        !recovery_unconditional_fault && !returnop && recovery_unconditional_wrong;
    wire [2:0] recovery_slot_next=(wb_redirect || irq_take) ? 3'b000:
        (recovery_conditional && recovery_conditional_ready) ?
            (taken ? recovery_taken_mask:recovery_fall_mask):
        recovery_unconditional_flush ? 3'b000:recovery_keep_mask;
    // One procedural writer per candidate array, including both banks.
    // No redirect, taken, fault or d_fire in this wide payload enable.
    // Wrong-path samples are harmless: EX ownership is separately valid.
    always @(posedge clk)if(resetn && recovery_capture)begin:g_recovery_capture
        recovery_pc_bank[recovery_capture_bank]<={decode_follow_next+32'd4,decode_follow_next,decode_recovery_branch_pc+32'd4};
        recovery_inst_bank[recovery_capture_bank]<={rtb_inst1[decode_replay_index],rtb_inst0[decode_replay_index],decode_follow_word};
        recovery_next_bank[recovery_capture_bank]<={rtb_next1[decode_replay_index],rtb_next0[decode_replay_index],decode_follow_next};
        recovery_linear_bank[recovery_capture_bank]<={rtb_linear1[decode_replay_index],rtb_linear0[decode_replay_index],decode_recovery_follow_linear};
    end
    integer n,fq,lane,rb;
    always @(posedge clk) begin
        if(!resetn)begin
            fetch_valid<=0;fetch_killed<=0;recovering<=1;recover_pc<=0;fetch_resume<=0;fetch_repredict<=0;
            fetch_addr<=0;fetch_next<=4;fetch_count<=0;fetch_reserved<=0;fetch_head<=0;fetch_tail<=0;fetch_kill_q<=0;
            legacy_dv<=0; xv<=0; mv<=0; wv<=0;
            m_write_rd<=0;
            p1_zero<=0;p1_m0<=0;p1_m1<=0;p1_w0<=0;p1_w1<=0;
            p2_zero<=0;p2_m0<=0;p2_m1<=0;p2_w0<=0;p2_w1<=0;
            s1_zero<=0;s1_m0<=0;s1_m1<=0;s1_w0<=0;s1_w1<=0;
            s2_zero<=0;s2_m0<=0;s2_m1<=0;s2_w0<=0;s2_w1<=0;
            s1_constant_alias<=0;s2_constant_alias<=0;
            xpacket_taken_wrong<=0;xpacket_fall_wrong<=0;xpacket_taken_pc<=0;xpacket_fall_pc<=0;
            xsequential_wrong<=0;xcall_wrong<=0;
            x_follow_return<=0;x_replay_hit<=0;x_replay_two<=0;x_replay_linear0<=0;x_replay_linear1<=0;
            x_replay_inst0<=0;x_replay_inst1<=0;x_replay_next0<=0;x_replay_next1<=0;
            rtb_valid<=0;rtb_two<=0;rtb_linear0<=0;rtb_linear1<=0;last_return_valid<=0;
            observe_valid<=0;observe_two<=0;observe_linear0<=0;observe_linear1<=0;
            last_return_pc<=0;observe_pc<=0;observe_inst0<=0;observe_inst1<=0;observe_next0<=0;observe_next1<=0;
            for(rb=0;rb<4;rb=rb+1)begin rtb_tag[rb]<=0;rtb_inst0[rb]<=0;rtb_inst1[rb]<=0;rtb_next0[rb]<=0;rtb_next1[rb]<=0;end
            iq_head<=0;iq_tail<=0;iq_count<=0;iq_error_storage<=0;iq_linear_storage<=0;iq_follow_valid_storage<=0;iq_follow_linear<=0;
            recovery_slot_mask<=0;recovery_active_bank<=0;x_recovery_bank<=0;x_recovery_valid<=0;
            x_follow_valid<=0;x_follow_ra<=0;x_follow_inst<=0;x_follow_next<=0;x_follow_linear<=0;
            fetch_linear0_q<=0;fetch_linear1_q<=0;
            xbranch_pc<=0;xbranch_target<=0;xpc1<=0;mpc1<=0;wpc1<=0;xsecond_wrong<=0;xtaken_wrong<=0;xfall_wrong<=0;fetch_linear<=4'b1111;fetch_pred2<=12;fetch_pred3<=16;fetch_linear2_q<=0;fetch_linear3_q<=0;
            for(fq=0;fq<4;fq=fq+1)begin fetch_words_q[fq]<=0;fetch_pred2_q[fq]<=0;fetch_pred3_q[fq]<=0;end
            fetch_pred1<=8;
            x_alu_branch3<=0;m_alu_branch3<=0;w_alu_branch3<=0;xi3<=0;mi3<=0;wi3<=0;mr2<=0;wr2<=0;mrd2<=0;wrd2<=0;mwe2<=0;wwe2<=0;
            retire_valid3<=0;retire_we3<=0;retire_pc3<=0;retire_inst3<=0;retire_data3<=0;retire_rd3<=0;
            xcount<=1;mcount<=1;wcount<=1;x_constant<=0;x_constant_value<=0;mwe1<=0;wwe1<=0;xother<=0;
            xi1<=0;xi2<=0;xn_last<=0;x1a<=0;x1b<=0;mi1<=0;mi2<=0;mr1<=0;mmiddle<=0;
            wi1<=0;wi2<=0;wr1<=0;wmiddle<=0;mrd1<=0;wrd1<=0;
            retire_valid1<=0;retire_valid2<=0;retire_count<=0;retire_we1<=0;retire_we2<=0; msent<=0; train_valid<=0;train_taken<=0;train_return<=0;train_pc<=0;train_target<=0;ras_count<=0;ras_sp<=0;ras_top<=0;
            csr_status<=32'h1800; csr_ie<=0; csr_vec<=0; csr_epc<=0; csr_cause<=0; csr_tval<=0; csr_scratch<=0;
            committed_next<=0; cycles<=0; retired<=0; retire_valid<=0; retire_we<=0;
            branch_count<=0; mispredict_count<=0; mispredict_event_q<=0; hazard_cycles<=0; memory_cycles<=0;
            
        end else begin
            recovery_slot_mask<=recovery_slot_next;
            // Delay response observation one edge so a concurrently resolved
            // return is already registered. Payload capture has no EX enable.
            observe_valid<=RETURN_TARGET_BUFFER && WIDE_FRONT && fetch_pop && !fetch_kill_q[fetch_head] && !fetch_error && fetch_pc_q[fetch_head][31:16]==0;
            if(fetch_pop)begin
                observe_pc<=fetch_pc_q[fetch_head];
                observe_inst0<=fetch_response[32*response_word_offset+:32];
                observe_inst1<=fetch_response[32*(response_word_offset+1)+:32];
                observe_next0<=fetch_next_q[fetch_head];observe_next1<=fetch_pred1_q[fetch_head];
                observe_linear0<=fetch_linear0_q[fetch_head];observe_linear1<=fetch_linear1_q[fetch_head];
                observe_two<=fetch_linear0_q[fetch_head] && (fetch_loop_q[fetch_head] ? fetch_words_q[fetch_head]>1:(FETCH_WORDS==4 ? fetch_pc_q[fetch_head][3:2]!=3:!fetch_pc_q[fetch_head][2]));
            end
            if(x_fire && !fault && branch_inst[6:0]==7'h67 && branch_inst[11:7]==0 && branch_inst[31:20]==0 &&
               (branch_inst[19:15]==1 || branch_inst[19:15]==5))begin
                last_return_valid<=1;last_return_pc<=branch_destination;
            end
            if(observe_valid && last_return_valid)begin
                if(observe_pc==last_return_pc)begin
                    rtb_valid[return_write_index]<=1;rtb_tag[return_write_index]<=last_return_pc;
                    rtb_inst0[return_write_index]<=observe_inst0;rtb_inst1[return_write_index]<=observe_inst1;
                    rtb_next0[return_write_index]<=observe_next0;rtb_next1[return_write_index]<=observe_next1;
                    rtb_linear0[return_write_index]<=observe_linear0;rtb_linear1[return_write_index]<=observe_linear1;
                    rtb_two[return_write_index]<=observe_two;
                end else if(observe_pc==last_return_pc+4 && rtb_valid[return_write_index] &&
                    rtb_tag[return_write_index]==last_return_pc && !rtb_two[return_write_index] && rtb_linear0[return_write_index])begin
                    rtb_inst1[return_write_index]<=observe_inst0;rtb_next1[return_write_index]<=observe_next0;
                    rtb_linear1[return_write_index]<=observe_linear0;rtb_two[return_write_index]<=1;
                end
            end
            if(fast_return)begin
                p1_zero<=0;
                p1_m0<=saved_return_reg==xi[11:7];
                p1_m1<=saved_return_reg==xi1[11:7];
                p1_w0<=saved_return_reg==mrd;
                p1_w1<=saved_return_reg==mrd1;
                p2_zero<=1;
                p2_m0<=1'b0;
                p2_m1<=1'b0;
                p2_w0<=1'b0;
                p2_w1<=1'b0;
            end else if(decode_capture)begin
                p1_zero<=drs1==0;
                p1_m0<=x_fire ? drs1==xi[11:7]:drs1==mrd;
                p1_m1<=x_fire ? drs1==xi1[11:7]:drs1==mrd1;
                p1_w0<=drs1==mrd;p1_w1<=drs1==mrd1;
                p2_zero<=drs2==0;
                p2_m0<=x_fire ? drs2==xi[11:7]:drs2==mrd;
                p2_m1<=x_fire ? drs2==xi1[11:7]:drs2==mrd1;
                p2_w0<=drs2==mrd;p2_w1<=drs2==mrd1;
                s1_zero<=di1[19:15]==0;
                s1_m0<=x_fire ? di1[19:15]==xi[11:7]:di1[19:15]==mrd;
                s1_m1<=x_fire ? di1[19:15]==xi1[11:7]:di1[19:15]==mrd1;
                s1_w0<=di1[19:15]==mrd;s1_w1<=di1[19:15]==mrd1;
                s2_zero<=decode_r2==0;
                s2_m0<=x_fire ? decode_r2==xi[11:7]:decode_r2==mrd;
                s2_m1<=x_fire ? decode_r2==xi1[11:7]:decode_r2==mrd1;
                s2_w0<=decode_r2==mrd;s2_w1<=decode_r2==mrd1;
                s1_constant_alias<=di1[19:15]==di[11:7];s2_constant_alias<=decode_r2==di[11:7];
            end else begin
                p1_w0<=p1_m0;p1_w1<=p1_m1;
                p2_w0<=p2_m0;p2_w1<=p2_m1;
                s1_w0<=s1_m0;s1_w1<=s1_m1;
                s2_w0<=s2_m0;s2_w1<=s2_m1;
            end
            cycles<=cycles+1'b1; retire_valid<=0; retire_we<=0;retire_valid3<=0;retire_we3<=0;
            retire_valid1<=0;retire_valid2<=0;retire_count<=0;retire_we1<=0;retire_we2<=0;
            if(xv && load_dependency)hazard_cycles<=hazard_cycles+1'b1;
            if(mv && mmem && !mem_complete)memory_cycles<=memory_cycles+1'b1;
            if(wv && !wfault)begin
                retired<=retired+wcount; committed_next<=wn;
                retire_count<=wcount;
                if(wcount>1)begin
                    retire_valid1<=1;retire_pc1<=wpc1;retire_inst1<=wi1;
                    retire_rd1<=wi1[11:7];retire_we1<=(wcount>=3 && !w_alu_branch3) ? 1'b1:wwe1 && wrd1!=0;
                    retire_data1<=(wcount>=3 && !w_alu_branch3) ? wmiddle:wr1;
                    
                end
                if(wcount>=3)begin
                    retire_valid2<=1;retire_pc2<=wp+8;retire_inst2<=wi2;
                    retire_rd2<=wi2[11:7];retire_we2<=!w_alu_branch3;retire_data2<=w_alu_branch3 ? 0:wr1;
                end
                if(wcount==4)begin
                    retire_valid3<=1;retire_pc3<=wp+12;retire_inst3<=wi3;
                    retire_rd3<=wrd2;retire_we3<=wwe2;retire_data3<=wr2;
                    
                end
                retire_valid<=1; retire_pc<=wp; retire_inst<=wi; retire_rd<=wrd;
                retire_we<=wwe && wrd!=0; retire_data<=wr;
                // A packet may overwrite its AUIPC destination with the JALR link.
                // Both retirement events remain visible; only the final value
                // is written to that physical architectural register.
                
                if(wcsrwe)case(wcsr)
                    12'h300:csr_status<=(wcsrdata&32'h88)|32'h1800;
                    12'h304:csr_ie<=wcsrdata&32'h888;
                    12'h305:csr_vec<={wcsrdata[31:2],2'b0};
                    12'h340:csr_scratch<=wcsrdata;
                    12'h341:csr_epc<={wcsrdata[31:2],2'b0};
                    12'h342:csr_cause<=wcsrdata;
                    12'h343:csr_tval<=wcsrdata;
                endcase
            end
            if(wb_redirect || irq_take)begin
                if(wv && wret && !wfault)begin csr_status[3]<=csr_status[7]; csr_status[7]<=1; end
                else begin
                    csr_epc<=irq_take ? committed_next:wp;
                    csr_cause<=irq_take ? irq_cause:wcause;
                    csr_tval<=irq_take ? 0:wtval;
                    csr_status[7]<=csr_status[3]; csr_status[3]<=0;
                end
            end
            wv<=mem_complete && !wb_redirect;
            if(mem_complete)begin
                wp<=mp; wi<=mi; wn<=mn; wrd<=mrd; wwe<=mwe;
                w_alu_branch3<=m_alu_branch3;wi3<=mi3;wr2<=mr2;wrd2<=mrd2;wwe2<=mwe2;
                wcount<=mcount;wpc1<=mpc1;wi1<=mi1;wi2<=mi2;wr1<=mr1;wmiddle<=mmiddle;wrd1<=mrd1;wwe1<=mwe1;
                wr<=(mmem && !mstore) ? load_result:mr;
                wfault<=mfault || (mmem && msent && d_rvalid && d_error);
                wcause<=mfault ? mcause:(mstore ? 7:5); wtval<=mfault ? mtval:ma;
                wret<=mret; wserial<=mserial; wcsr<=mcsr; wcsrdata<=mcsrdata; wcsrwe<=mcsrwe;
            end
            if(d_valid && d_ready)msent<=1;
            if(m_accept)begin
                mv<=x_fire; msent<=0;
                if(x_fire)begin
                    mp<=xp; mi<=xi; mn<=actual_next; mr<=result; ma<=address; ms<=store_data;
                    m_alu_branch3<=x_alu_branch3;mi3<=xi3;mr2<=x_a>>xi3[24:20];mrd2<=xi3[11:7];mwe2<=xcount==4;
                    mcount<=(control_first && first_control_wrong) ? 1:xcount;mpc1<=xpc1;mi1<=xi1;mi2<=xi2;mr1<=result1;mmiddle<={32{x_a[0]}};
                    mrd1<=(xcount>=3 && !branch_third) ? xi2[11:7]:xi1[11:7];mwe1<=xcount>1 && !branch_second && !(control_first && first_control_wrong) && ((xcount>=3 && !branch_third) ? xi2[11:7]!=0:xi1[11:7]!=0);
                    mrd<=xi[11:7]; mwe<=regwrite; mmem<=memop; mstore<=storeop; mfun<=funct; mstrb<=strobe;
                    m_write_rd<=regwrite && (xi[11:7]!=0);
                    mfault<=fault; mcause<=fault_cause; mtval<=fault_value; mret<=returnop;
                    mserial<=serialop; mcsr<=xi[31:20]; mcsrdata<=csr_new; mcsrwe<=csrwrite;
                end
            end
            if(!xv || x_fire)begin
                xv<=d_fire;
                x_recovery_valid<=d_fire && recovery_capture;
                if(recovery_capture)x_recovery_bank<=recovery_capture_bank;
                // Redirect kills xv below; discarded payload may still sample.
                if(decode_capture)begin
                    x_constant<=decode_constant;x_constant_value<=decode_constant_value;
                    xp<=dp;xi<=di;xn<=dn;xa<=rval1;xb<=rval2;xe<=de;
                    x_alu_branch3<=triple_branch_decode;
                    xcount<=WIDE_FRONT ? decode_count:1;xpc1<=iq_lane_pc[1];xsecond_wrong<=iq_lane_pc[1]+4!=iq_lane_next[1];xi1<=di1;xi2<=di2;xi3<=di3;
                    // Compare alternatives in parallel, then select one bit.
                    // Held EX packets retain these flags like xp/xcount/xn.
                    xsequential_wrong<=!WIDE_FRONT ? dp+32'd4!=dn:
                        four_decode ? dp+32'd16!=iq_lane_next[3]:
                        decode_ge3 ? dp+32'd12!=iq_lane_next[2]:
                        paired_decode ? dp+32'd8!=iq_lane_next[1]:dp+32'd4!=dn;
                    xcall_wrong<=call_target!=iq_lane_next[1];
                    x_follow_ra<=decode_return_ra;
                    x_follow_return<=decode_follow_return;
                    x_replay_hit<=rtb_valid[decode_replay_index] && rtb_tag[decode_replay_index]==decode_follow_next;
                    x_replay_two<=rtb_two[decode_replay_index] && rtb_linear0[decode_replay_index];
                    x_replay_inst0<=rtb_inst0[decode_replay_index];x_replay_inst1<=rtb_inst1[decode_replay_index];
                    x_replay_next0<=rtb_next0[decode_replay_index];x_replay_next1<=rtb_next1[decode_replay_index];
                    x_replay_linear0<=rtb_linear0[decode_replay_index];x_replay_linear1<=rtb_linear1[decode_replay_index];
                    x_follow_valid<=triple_branch_decode ? iq_follow_valid[iq_h2]:decode_branch_second ? iq_follow_valid[iq_h1]:iq_follow_valid[iq_head];
                    x_follow_inst<=triple_branch_decode ? iq_lane_follow_inst[2]:decode_branch_second ? iq_lane_follow_inst[1]:iq_lane_follow_inst[0];
                    x_follow_next<=triple_branch_decode ? iq_lane_follow_next[2]:decode_branch_second ? iq_lane_follow_next[1]:iq_lane_follow_next[0];
                    x_follow_linear<=triple_branch_decode ? iq_follow_linear[iq_h2]:decode_branch_second ? iq_follow_linear[iq_h1]:iq_follow_linear[iq_head];
                    xbranch_pc<=triple_branch_decode ? dp+8:(decode_branch_second || decode_jump_second) ? dp+4:dp;
                    xbranch_target<=triple_branch_decode ? third_target:decode_jump_second ? call_target:decode_branch_second ? di1_target:decode_target0;
                    xtaken_wrong<=triple_branch_decode ? third_target!=iq_lane_next[2]:decode_branch_second ? di1_target!=iq_lane_next[1]:decode_target0!=dn;
                    xpacket_taken_pc<=triple_branch_decode ? third_target:(decode_branch_first_pair && decode_target0==dn) ?
                        iq_lane_pc[1]+4:decode_branch_second ? di1_target:decode_target0;
                    xpacket_fall_pc<=triple_branch_decode ? dp+12:(decode_branch_first_pair && dp+4==dn) ?
                        iq_lane_pc[1]+4:decode_branch_second ? dp+8:dp+4;
                    xpacket_taken_wrong<=triple_branch_decode ? third_target!=iq_lane_next[2]:(decode_branch_second ? di1_target!=iq_lane_next[1]:decode_target0!=dn) ||
                        (decode_branch_first_pair && iq_lane_pc[1]+4!=iq_lane_next[1]);
                    xpacket_fall_wrong<=triple_branch_decode ? dp+12!=iq_lane_next[2]:(decode_branch_second ? dp+8!=iq_lane_next[1]:dp+4!=dn) ||
                        (decode_branch_first_pair && iq_lane_pc[1]+4!=iq_lane_next[1]);
                    xfall_wrong<=triple_branch_decode ? dp+12!=iq_lane_next[2]:decode_branch_second ? dp+8!=iq_lane_next[1]:dp+4!=dn;
                    xn_last<=four_decode ? iq_lane_next[3]:(fused_decode || triple_branch_decode) ? iq_lane_next[2]:iq_lane_next[1];
                    x1a<=rval_extra1;x1b<=rval_extra2;xother<=decode_r1;
                end
            end else begin
                // A WB producer may disappear during an unrelated memory stall.
                // Preserve forwarded operands for the held EX instruction.
                xa<=x_a; xb<=x_b;x1a<=x1_a;x1b<=x1_b;x_follow_ra<=return_ra;
            end
            if(WIDE_FRONT)begin
                fetch_reserved<=fetch_reserved+(fetch_push ? wide_count:0)-(fetch_pop ? fetch_words_q[fetch_head]:0);
                iq_count<=iq_count+enqueue_count-dequeue_count;
                if(d_fire)iq_head<=iq_head+decode_count;
                if(enqueue)begin
                    for(lane=0;lane<4;lane=lane+1)if(enqueue_lane[lane]<enqueue_count)begin
                        
                        
                        iq_error_storage[enqueue_slot[lane]]<=fetch_error;
                        iq_follow_valid_storage[enqueue_slot[lane]]<=!fetch_error &&
                            (fetch_loop_q[fetch_head] ? (enqueue_lane[lane]+1<enqueue_count || fetch_exit_valid_q[fetch_head]) :
                            response_word_offset+enqueue_lane[lane]<FETCH_WORDS-1);
                        
                        case(enqueue_lane[lane])
                          0:begin iq_follow_linear[enqueue_slot[lane]]<=fetch_linear1_q[fetch_head];end
                          1:begin iq_follow_linear[enqueue_slot[lane]]<=fetch_linear2_q[fetch_head];end
                          2:begin iq_follow_linear[enqueue_slot[lane]]<=fetch_linear3_q[fetch_head];end
                          default:begin iq_follow_linear[enqueue_slot[lane]]<=0;end
                        endcase
                        // A separately observed successful ROM word is safe
                        // to salvage on loop exit, even across a line boundary.
                        if(fetch_loop_q[fetch_head] && enqueue_lane[lane]+1==enqueue_count && fetch_exit_valid_q[fetch_head])begin
                            
                            
                            iq_follow_linear[enqueue_slot[lane]]<=0;
                        end
                        case(enqueue_lane[lane])
                          0:begin iq_linear_storage[enqueue_slot[lane]]<=fetch_linear0_q[fetch_head];end
                          1:begin iq_linear_storage[enqueue_slot[lane]]<=fetch_linear1_q[fetch_head];end
                          2:begin iq_linear_storage[enqueue_slot[lane]]<=fetch_linear2_q[fetch_head];end
                          3:begin iq_linear_storage[enqueue_slot[lane]]<=fetch_linear3_q[fetch_head];end
                        endcase
                    end
                    iq_tail<=iq_tail+enqueue_count;
                end
                case({fetch_push,fetch_pop})
                  2'b10:fetch_count<=fetch_count+1'b1;
                  2'b01:fetch_count<=fetch_count-1'b1;
                  default:begin end
                endcase
                if(fetch_pop)fetch_head<=fetch_head+1'b1;
                if(fetch_push)begin
                    fetch_pc_q[fetch_tail]<=fetch_addr;fetch_next_q[fetch_tail]<=WIDE_FRONT ? request_next:fetch_next;
                    fetch_pred1_q[fetch_tail]<=request_pred1;fetch_words_q[fetch_tail]<=wide_count;
                    fetch_pred2_q[fetch_tail]<=request_pred2;fetch_pred3_q[fetch_tail]<=request_pred3;
                    fetch_linear2_q[fetch_tail]<=request_linear[2];
                    fetch_linear3_q[fetch_tail]<=request_linear[3];
                    fetch_linear0_q[fetch_tail]<=request_linear[0];
                    fetch_linear1_q[fetch_tail]<=request_linear[1];
                    fetch_kill_q[fetch_tail]<=fetch_killed;fetch_tail<=fetch_tail+1'b1;
                    fetch_valid<=0;fetch_resume<=0;
                    if(!fetch_killed && !recovering)begin
                        fetch_addr<=wide_end;fetch_next<=query_next;fetch_pred1<=query_pred1;fetch_pred2<=query_pred2;fetch_pred3<=query_pred3;
                        fetch_linear[0]<=query_linear[0];fetch_linear[1]<=query_linear[1];fetch_linear[2]<=query_linear[2];fetch_linear[3]<=query_linear[3];
                        if(fetch_count<3 && iq_count+fetch_reserved+wide_count<=16-FETCH_WORDS && !irq_wait)fetch_valid<=1;
                        if(!loop_select && fetch_resume && !resume_linear)begin fetch_valid<=0;fetch_repredict<=1;end
                    end
                end
                if(!fetch_valid && fetch_count<4 && iq_count+fetch_reserved+FETCH_WORDS<=16 && !irq_wait)begin
                    fetch_valid<=1;fetch_killed<=0;
                    if(fetch_repredict)begin
                        fetch_repredict<=0;fetch_resume<=0;
                        fetch_next<=query_next;fetch_pred1<=query_pred1;fetch_pred2<=query_pred2;fetch_pred3<=query_pred3;fetch_linear<=query_linear;
                    end
                    if(recovering)begin
                        fetch_repredict<=0;fetch_resume<=0;fetch_addr<=recover_pc;fetch_next<=query_next;fetch_pred1<=query_pred1;fetch_pred2<=query_pred2;fetch_pred3<=query_pred3;
                        fetch_linear[0]<=query_linear[0];fetch_linear[1]<=query_linear[1];fetch_linear[2]<=query_linear[2];fetch_linear[3]<=query_linear[3];
                        recovering<=0;
                    end
                end
            end else begin
            if(d_fire)legacy_dv<=0;
            case({fetch_push,fetch_pop})
                2'b10:fetch_count<=fetch_count+1'b1;
                2'b01:fetch_count<=fetch_count-1'b1;
                default:begin end
            endcase
            if(fetch_pop)begin
                fetch_head<=fetch_head+1'b1;
                if(!fetch_kill_q[fetch_head] && !redirect)begin
                    legacy_dp<=fetch_pc_q[fetch_head];legacy_di<=i_rdata;legacy_dn<=fetch_next_q[fetch_head];legacy_de<=i_error;legacy_dv<=1;
                end
            end
            if(fetch_push)begin
                fetch_pc_q[fetch_tail]<=fetch_addr;fetch_next_q[fetch_tail]<=WIDE_FRONT ? request_next:fetch_next;
                fetch_kill_q[fetch_tail]<=fetch_killed;fetch_tail<=fetch_tail+1'b1;
                fetch_valid<=0;
                if(!fetch_killed && !recovering)begin
                    fetch_addr<=fetch_next;
                    fetch_next<=chain_predicted ? chain_target:fetch_next+4;
                    // Reserve capacity for the next asserted request using only
                    // registered credit state, with no response->VALID feedback.
                    if(fetch_count<3 && !irq_wait)fetch_valid<=1;
                end
            end
            if(!fetch_valid && fetch_count<4 && !irq_wait)begin
                fetch_valid<=1;fetch_killed<=0;
                if(recovering)begin
                    fetch_addr<=recover_pc;fetch_next<=predicted ? recovery_target:recover_pc+4;
                    recovering<=0;
                end
            end
            end
            // Payload samples independently of the late valid decision. The
            // following edge trains the BTB; resolved RAS hints stay in EX.
            train_valid<=x_fire && !fault && branchop;
            train_pc<=branch_pc;
            train_target<=branch_inst[6:0]==7'h63 ? xbranch_target:branch_destination;
            train_taken<=taken;
            train_return<=branch_inst[6:0]==7'h67 && branch_inst[11:7]==0 &&
                (branch_inst[19:15]==1 || branch_inst[19:15]==5) && branch_inst[31:20]==0;
            if(ras_update)begin
                if(ras_push)begin
                    // Coroutine pop+push replaces the top; otherwise append.
                    if(ras_pop && ras_count!=0)ras[ras_previous]<=branch_pc+4;
                    else begin
                        ras[ras_sp]<=branch_pc+4;ras_sp<=ras_sp+1'b1;
                        if(ras_count<16)ras_count<=ras_count+1'b1;
                    end
                    ras_top<=branch_pc+4;
                end else if(ras_pop && ras_count!=0)begin
                    ras_sp<=ras_previous;ras_count<=ras_count-1'b1;
                    ras_top<=ras[ras_below];
                end
            end
            if(train_valid && RETURN_TARGET_BUFFER)begin
                // Refresh direction/target in existing immutable ROM entries
                // from resolved control flow, without adding BTB read ports.
                for(rb=0;rb<4;rb=rb+1)if(rtb_valid[rb])begin
                    if(train_pc==rtb_tag[rb])begin
                        rtb_next0[rb]<=train_prediction;rtb_linear0[rb]<=!train_predict_taken;
                    end
                    if(train_pc==rtb_tag[rb]+4)begin
                        rtb_next1[rb]<=train_prediction;rtb_linear1[rb]<=!train_predict_taken;
                    end
                end
            end
            if(train_valid)begin
                branch_count<=branch_count+1'b1;

            end
            mispredict_event_q<=branch_redirect;
            if(mispredict_event_q)mispredict_count<=mispredict_count+1'b1;
            if(redirect)begin
                // Flush prior IQ references and EX ownership. Bank contents
                // need no clearing; only this redirect's selected mask is live.
                x_recovery_valid<=0;
                recover_pc<=recovery_start;recovering<=1;fetch_repredict<=0;legacy_dv<=0;xv<=0;
                if(WIDE_FRONT)begin
                    iq_count<=0;iq_head<=0;iq_tail<=0;
                    if(fallthrough_salvage && !fast_return)begin
                        iq_count<=1;iq_tail<=1;
                        if(BANKED_RECOVERY)begin
                            // No wide IQ or EX payload write uses this late
                            // decision. The observed return executes normally;
                            // a changed real RA invalidates its younger replay.
                            recovery_active_bank<=x_recovery_bank;
                            if(return_replay)begin
                                iq_count<=replay_two ? 3:2;iq_tail<=replay_two ? 3:2;
                            end
                        end else begin
                            
                            iq_error_storage[0]<=0;iq_linear_storage[0]<=x_follow_linear;iq_follow_valid_storage[0]<=0;
                            if(return_replay)begin
                                iq_count<=replay_two ? 3:2;iq_tail<=replay_two ? 3:2;
                                
                                iq_error_storage[1]<=0;iq_linear_storage[1]<=x_replay_linear0;iq_follow_valid_storage[1]<=0;
                                if(replay_two)begin
                                    
                                    iq_error_storage[2]<=0;iq_linear_storage[2]<=x_replay_linear1;iq_follow_valid_storage[2]<=0;
                                end
                            end
                        end
                    end
                end
                if(fast_return)begin
                    // Its ID work was performed with the branch. The older
                    // group enters MEM while this return takes the free EX
                    // slot; ordinary EX forwarding, faults and retirement apply.
                    if(return_replay)begin
                        iq_count<=replay_two ? 2:1;iq_tail<=replay_two ? 2:1;
                        
                        iq_error_storage[0]<=0;iq_linear_storage[0]<=x_replay_linear0;iq_follow_valid_storage[0]<=0;
                        if(replay_two)begin
                            
                            iq_error_storage[1]<=0;iq_linear_storage[1]<=x_replay_linear1;iq_follow_valid_storage[1]<=0;
                        end
                    end
                    xv<=1;xp<=branch_pc+4;xi<=x_follow_inst;xn<=x_follow_next;
                    // The injected instruction is JALR x0,0(x1/x5), xcount=1.
                    // rs2, second/third instructions and direct-branch target
                    // are unused. Do not drive their wide clears from the
                    // late load-dependent fast_return decision.
                    xa<=return_ra;xe<=0;xcount<=1;x_alu_branch3<=0;x_constant<=0;
                    xbranch_pc<=branch_pc+4;
                    xtaken_wrong<=0;xfall_wrong<=0;xsecond_wrong<=0;x_follow_valid<=0;
                end
                fetch_kill_q<=4'b1111;
                if(fetch_valid && !fetch_push)fetch_killed<=1;
                else begin
                    fetch_valid<=0;fetch_killed<=0;fetch_resume<=0;
                    // recover_pc captures the resolved destination above.
                    // The normal recovering path issues it on the next edge;
                    // no late EX fault/redirect signal enables fetch_addr.
                end
                if(wb_redirect || irq_take)begin
                    mv<=0; wv<=0; msent<=0;
                end
            end
            // Highest-priority RAS invalidation is a WB/IRQ operation only.
            // Keep it outside if(redirect) to exclude next_wrong/taken from
            // the inferred reset and clock-enable qualification.
            if(wb_redirect || irq_take)begin ras_count<=0;ras_sp<=0;end
        end
    end
endmodule

// One dynamically discovered straight-line loop, at most 32 original words.
// Training observes ordered architectural commits. No PC-specific behavior.
module rv_loop_fetch(
    input wire clk,resetn,clear,commit,input wire [2:0] count,
    input wire [31:0] pc0,pc1,pc2,pc3,inst0,inst1,inst2,inst3,
    input wire [31:0] last_pc,last_inst,actual_next,query_pc,
    input wire observe,input wire [31:0] observe_base,input wire [127:0] observe_data,
    output reg exit_valid,output reg [31:0] exit_inst,output wire [31:0] exit_pc,
    output wire hit,output wire [2:0] words,output wire [127:0] data,
    output wire [31:0] next0,next1,next2,next3,output wire [3:0] linear);
    reg valid,collecting;
    reg [31:0] first_pc,end_pc,expected_pc;
    reg [31:0] instructions[0:31];
    // One-entry write pipeline. Metadata advances on retirement; payload
    // writes drain one edge later. A newly completed loop cannot be queried
    // until every pending lane is stored. Clear cancels all pending writes.
    reg [3:0] write_lane_q;
    reg [4:0] write_index_q[0:3];
    reg [31:0] write_data_q[0:3];
    assign exit_pc=end_pc+4;
    always @(posedge clk)begin
        if(!resetn || clear)begin exit_valid<=0;exit_inst<=0;end
        else if(first_n!=first_pc || end_n!=end_pc)exit_valid<=0;
        else if(observe && (valid || collecting) && observe_base=={exit_pc[31:4],4'b0})begin
            exit_valid<=1;exit_inst<=observe_data[32*exit_pc[3:2]+:32];
        end
    end
    wire [31:0] pcs[0:3],insts[0:3];
    assign pcs[0]=pc0;assign pcs[1]=pc1;assign pcs[2]=pc2;assign pcs[3]=pc3;
    assign insts[0]=inst0;assign insts[1]=inst1;assign insts[2]=inst2;assign insts[3]=inst3;
    wire [31:0] back_target=last_pc+{{19{last_inst[31]}},last_inst[31],last_inst[7],last_inst[30:25],last_inst[11:8],1'b0};
    wire back_branch=last_inst[6:0]==7'h63 && !last_inst[8] &&
        actual_next==back_target && back_target<last_pc &&
        last_pc-back_target<=124 && last_pc[31:16]==0 && back_target[31:16]==0;
    reg valid_n,collect_n;
    reg [31:0] first_n,end_n,expected_n;
    reg [3:0] write_lane;
    integer k;
    wire [4:0] write_index0=(pc0-first_pc)>>2;
    wire [4:0] write_index1=(pc1-first_pc)>>2;
    wire [4:0] write_index2=(pc2-first_pc)>>2;
    wire [4:0] write_index3=(pc3-first_pc)>>2;

    wire lane_ok0=count<=0 || (pc0==expected_pc+0 && ((pc0<end_pc && (inst0[6:0]==7'h13 || inst0[6:0]==7'h33 || inst0[6:0]==7'h37 || inst0[6:0]==7'h17)) || (pc0==end_pc && 0==count-1 && inst0[6:0]==7'h63 && back_target==first_pc)));
    wire lane_ok1=count<=1 || (pc1==expected_pc+4 && ((pc1<end_pc && (inst1[6:0]==7'h13 || inst1[6:0]==7'h33 || inst1[6:0]==7'h37 || inst1[6:0]==7'h17)) || (pc1==end_pc && 1==count-1 && inst1[6:0]==7'h63 && back_target==first_pc)));
    wire lane_ok2=count<=2 || (pc2==expected_pc+8 && ((pc2<end_pc && (inst2[6:0]==7'h13 || inst2[6:0]==7'h33 || inst2[6:0]==7'h37 || inst2[6:0]==7'h17)) || (pc2==end_pc && 2==count-1 && inst2[6:0]==7'h63 && back_target==first_pc)));
    wire lane_ok3=count<=3 || (pc3==expected_pc+12 && ((pc3<end_pc && (inst3[6:0]==7'h13 || inst3[6:0]==7'h33 || inst3[6:0]==7'h37 || inst3[6:0]==7'h17)) || (pc3==end_pc && 3==count-1 && inst3[6:0]==7'h63 && back_target==first_pc)));
    wire packet_ok=lane_ok0 && lane_ok1 && lane_ok2 && lane_ok3;
    wire completed=collecting && packet_ok && last_pc==end_pc;
    wire begin_collect=back_branch && (!collecting || !packet_ok || completed) &&
        (!(valid || completed) || first_pc!=back_target || end_pc!=last_pc);
    always @*begin
        valid_n=valid;collect_n=collecting;first_n=first_pc;end_n=end_pc;expected_n=expected_pc;
        write_lane=0;
        if(commit)begin
            if(collecting)begin
                if(packet_ok)begin
                    write_lane={count>3,count>2,count>1,count>0};
                    expected_n=expected_pc+{27'b0,count,2'b0};
                    if(completed)begin valid_n=1;collect_n=0;end
                end else collect_n=0;
            end
            if(begin_collect)begin
                valid_n=0;collect_n=1;first_n=back_target;end_n=last_pc;expected_n=back_target;
            end
        end
    end
    always @(posedge clk)begin
        if(!resetn || clear)begin
            valid<=0;collecting<=0;first_pc<=0;end_pc<=0;expected_pc<=0;write_lane_q<=0;
        end else begin
            valid<=valid_n;collecting<=collect_n;first_pc<=first_n;end_pc<=end_n;expected_pc<=expected_n;
            write_lane_q<=write_lane;
            // Payload registers sample independently of the late qualification.
            write_index_q[0]<=write_index0;write_index_q[1]<=write_index1;
            write_index_q[2]<=write_index2;write_index_q[3]<=write_index3;
            write_data_q[0]<=inst0;write_data_q[1]<=inst1;
            write_data_q[2]<=inst2;write_data_q[3]<=inst3;
            if(write_lane_q[0])instructions[write_index_q[0]]<=write_data_q[0];
            if(write_lane_q[1])instructions[write_index_q[1]]<=write_data_q[1];
            if(write_lane_q[2])instructions[write_index_q[2]]<=write_data_q[2];
            if(write_lane_q[3])instructions[write_index_q[3]]<=write_data_q[3];
            // On replacement, older pending writes finish before the first
            // new-candidate write. Every new word is overwritten before hit.
        end
    end
    wire [31:0] remain=(end_pc-query_pc+4)>>2;
    assign hit=valid && !(|write_lane_q) && query_pc[1:0]==0 && query_pc>=first_pc && query_pc<=end_pc;
    assign words=remain>=4 ? 4:remain[2:0];
    wire [4:0] index=(query_pc-first_pc)>>2;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1)begin:g_read
        wire [4:0] offset=index+lane;
        assign data[32*lane+:32]=instructions[offset];
        assign linear[lane]=query_pc+4*lane!=end_pc;
    end endgenerate
    assign next0=query_pc==end_pc ? first_pc:query_pc+4;
    assign next1=query_pc+4==end_pc ? first_pc:query_pc+8;
    assign next2=query_pc+8==end_pc ? first_pc:query_pc+12;
    assign next3=query_pc+12==end_pc ? first_pc:query_pc+16;
endmodule
