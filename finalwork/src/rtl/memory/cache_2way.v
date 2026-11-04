// Two-way set associative cache, synchronous data arrays, 16-byte lines.
// Write-through / no-write-allocate. One request outstanding, blocking refill.
module cache_2way #(parameter SET_BITS=7, parameter INSTRUCTION=0, parameter ENABLE=1,
    parameter PRELOOKUP=0, parameter PRELOOKUP_REUSE=0, parameter WIDE_FETCH=0, parameter FETCH_WORDS=2)(
    input wire clk,resetn,
    input wire req_valid,output wire req_ready,input wire [31:0] req_addr,req_wdata,
    input wire req_write,input wire [3:0] req_wstrb,
    output wire rsp_valid,input wire rsp_ready,output wire [31:0] rsp_data,rsp_data_hi,rsp_data2,rsp_data3,output wire rsp_error,
    output wire cmd_valid,input wire cmd_ready,output wire [31:0] cmd_addr,cmd_wdata,
    output wire cmd_write,cmd_line,output wire [3:0] cmd_wstrb,
    input wire ret_valid,output wire ret_ready,input wire [31:0] ret_data,input wire ret_error,ret_last,
    input wire probe_valid, input wire [31:0] probe_addr, input wire probe_commit,
    output wire probe_ready, output reg probe_result_valid, output wire probe_hit,
    output wire [31:0] probe_data, output reg [31:0] probe_result_addr, input wire probe_take,
    output reg [31:0] accesses,misses
);
    // Only ROM 0x0000xxxx and data RAM 0x1000xxxx are cacheable.
    // Keep low-16-bit line tags and one ROM/RAM region bit on D-cache.
    // Full address qualification below remains mandatory before any hit.
    localparam SETS=1<<SET_BITS, TAG_BITS=(INSTRUCTION ? 12:13)-SET_BITS;
    localparam IDLE=0,LOOKUP=1,COMMAND=2,REFILL=3,REPLY=4;
    reg [2:0] state;
    reg [31:0] addr,wdata;
    wire [31:0] q0,q1,q0_hi,q1_hi;
    wire [31:0] q0_2,q1_2,q0_3,q1_3;
    reg [31:0] reply_data_hi,reply_data2,reply_data3;
    reg writeop,fill,chosen_way,hit_saved,acc_error;
    reg [3:0] strb;
    reg [31:0] reply_data;
    reg reply_error;
    reg [1:0] beat;
    
    // Clear metadata sequentially after reset so validity and replacement
    // bits can use RAM. Requests and bus commands wait for the clear sweep.
    reg valid0[0:SETS-1] /* synthesis syn_ramstyle="lut_ram" */;
    reg valid1[0:SETS-1] /* synthesis syn_ramstyle="lut_ram" */;
    reg lru[0:SETS-1] /* synthesis syn_ramstyle="lut_ram" */;
    reg metadata_ready;
    reg [SET_BITS-1:0] clear_index;
    wire cache_ready=!ENABLE || metadata_ready;
    wire metadata_fill=state==REFILL && fill;
    wire metadata_success=metadata_fill && ret_valid && ret_last && !acc_error && !ret_error && beat==3;
    wire metadata_hit=state==LOOKUP && !illegal && hit && !writeop;
    wire [SET_BITS-1:0] validity_index=metadata_ready ? index:clear_index;
    wire validity_data=metadata_ready && metadata_success;
    wire lru_write=!metadata_ready || metadata_success || metadata_hit || probe_consumed;
    wire [SET_BITS-1:0] lru_index=!metadata_ready ? clear_index:
        (metadata_success || metadata_hit) ? index:probe_result_addr[SET_BITS+3:4];
    wire lru_data=metadata_ready && (metadata_success ? !chosen_way:metadata_hit ? h0:probe_h0);
    always @(posedge clk)begin
        if(!resetn)begin metadata_ready<=0;clear_index<=0;end
        else if(!metadata_ready)begin
            clear_index<=clear_index+1'b1;
            if(&clear_index)metadata_ready<=1;
        end
        if(resetn && ENABLE)begin
            if(!metadata_ready || (metadata_fill && !chosen_way))valid0[validity_index]<=validity_data;
            if(!metadata_ready || (metadata_fill && chosen_way))valid1[validity_index]<=validity_data;
            if(lru_write)lru[lru_index]<=lru_data;
        end
    end

    reg [TAG_BITS-1:0] tag0[0:SETS-1],tag1[0:SETS-1];
    wire [SET_BITS-1:0] index=addr[SET_BITS+3:4];
    wire [TAG_BITS-1:0] tag=(INSTRUCTION ? addr[15:SET_BITS+4]:{addr[28],addr[15:SET_BITS+4]});
    wire is_rom=addr[31:16]==0;
    wire is_ram=addr[31:16]==16'h1000;
    wire cacheable=ENABLE && (is_rom || (!INSTRUCTION && is_ram));
    // Compare tags in parallel with the synchronous data-array read, and
    // register both hit bits at request acceptance. LOOKUP no longer chains
    // an asynchronous tag read/compare into CPU forwarding and branch logic.
    reg h0,h1;
    wire [SET_BITS-1:0] req_index=req_addr[SET_BITS+3:4];
    wire [TAG_BITS-1:0] req_tag=(INSTRUCTION ? req_addr[15:SET_BITS+4]:{req_addr[28],req_addr[15:SET_BITS+4]});
    wire req_cacheable=ENABLE && (req_addr[31:16]==0 || (!INSTRUCTION && req_addr[31:16]==16'h1000));
    wire hit=h0 || h1;
    wire illegal=(|addr[1:0]) || (INSTRUCTION && (!is_rom || writeop));
    // Read-only I-cache can replace a retiring lookup with the next request.
    // D-cache remains blocking to avoid store/read RAM-port collisions.
    assign req_ready=resetn && cache_ready && (state==IDLE ||
        (INSTRUCTION && rsp_valid && rsp_ready));
    // The synchronous RAM output is already registered. Return a hit directly
    // in LOOKUP; hold this state and its address until the consumer accepts it.
    wire lookup_reply=state==LOOKUP && (illegal || (hit && !writeop));
    // Single-beat completion can retire on the actual bus response. If the
    // CPU is stalled, capture it in REPLY; never acknowledge a write early.
    // Enabled I-cache accepts only ROM reads: illegal instruction accesses
    // terminate in LOOKUP, and every legal miss sets fill=1. Specialize this
    // unreachable single-beat path so AXI completion cannot drive I-side IQ
    // enables combinationally. D-cache and disabled-cache behavior are intact.
    wire return_reply=(!INSTRUCTION || !ENABLE) && state==REFILL && !fill && ret_valid && ret_last;
`ifdef RTL_SIM
    always @(posedge clk)if(resetn && INSTRUCTION && ENABLE && state==REFILL && !fill)
        $fatal(1,"ICACHE_REFILL_INVARIANT_FAILED");
`endif
    assign rsp_valid=resetn && (state==REPLY || lookup_reply || return_reply);
    assign rsp_data=lookup_reply ? (illegal ? 32'b0:h0 ? q0:q1):return_reply ? ret_data:reply_data;
    assign rsp_data_hi=lookup_reply ? (illegal ? 32'b0:h0 ? q0_hi:q1_hi):reply_data_hi;
    assign rsp_data2=lookup_reply ? (illegal ? 32'b0:h0 ? q0_2:q1_2):reply_data2;
    assign rsp_data3=lookup_reply ? (illegal ? 32'b0:h0 ? q0_3:q1_3):reply_data3;
    assign rsp_error=lookup_reply ? illegal:return_reply ? (acc_error|ret_error):reply_error;
    // An EX-stage hint may sample the synchronous read port without issuing a
    // request, changing replacement state, or starting a bus transaction.
    // The result is a one-cycle token; only its matching MEM-stage load may
    // consume it. A discarded/missed token automatically expires next edge.
    wire normal_accept=req_valid && req_ready;
    wire probe_read_retiring=PRELOOKUP_REUSE && !writeop && rsp_valid && rsp_ready &&
        (state==LOOKUP || state==REPLY || (state==REFILL && !fill));
    assign probe_ready=resetn && cache_ready && PRELOOKUP && ENABLE && !INSTRUCTION && !req_valid &&
        (state==IDLE || probe_read_retiring);
    // Deliberately exclude late EX commit from this bank-read enable. Commit
    // gates only the small result-valid register below.
    wire probe_read=probe_valid && probe_ready;
    wire bank_read=normal_accept || probe_read;
    wire [SET_BITS+1:0] read_index=normal_accept ? req_addr[SET_BITS+3:2]:probe_addr[SET_BITS+3:2];
    wire [SET_BITS-1:0] probe_index=probe_addr[SET_BITS+3:4];
    wire [TAG_BITS-1:0] probe_tag=(INSTRUCTION ? probe_addr[15:SET_BITS+4]:{probe_addr[28],probe_addr[15:SET_BITS+4]});
    wire probe_cacheable=(probe_addr[31:16]==0 || probe_addr[31:16]==16'h1000) &&
        !(|probe_addr[1:0]);
    reg probe_h0,probe_h1;
    assign probe_hit=probe_result_valid && (probe_h0 || probe_h1);
    assign probe_data=probe_h0 ? q0:q1;
    // Normal requests have port/accounting priority. The CPU normally makes
    // these mutually exclusive: fast_take suppresses its ordinary request.
    wire probe_consumed=probe_take && probe_hit && !normal_accept;
    // The request address is already registered at LOOKUP. Issue the bus
    // command here, retaining identical payload in COMMAND under backpressure.
    // Every legal Store goes to the bus regardless of a cache hit. Its
    // registered MEM-stage payload can start the command at acceptance;
    // tag state is captured in parallel and used only after the B response.
    wire early_write=cache_ready && !INSTRUCTION && state==IDLE && req_valid && req_write && !(|req_addr[1:0]);
    wire req_h0=req_cacheable && valid0[req_index] && tag0[req_index]==req_tag;
    wire req_h1=req_cacheable && valid1[req_index] && tag1[req_index]==req_tag;
    wire lookup_command=state==LOOKUP && !illegal && !(hit && !writeop);
    wire command_fill=state==LOOKUP ? cacheable && !writeop:fill;
    assign cmd_valid=resetn && cache_ready && (state==COMMAND || lookup_command || early_write);
    assign cmd_addr=early_write ? req_addr:command_fill ? {addr[31:4],4'b0}:addr;
    assign cmd_wdata=early_write ? req_wdata:wdata;
    assign cmd_write=early_write || writeop;
    assign cmd_wstrb=early_write ? req_wstrb:strb;assign cmd_line=!early_write && command_fill;
    assign ret_ready=resetn && state==REFILL;
    wire [SET_BITS+1:0] write_index=fill ? {index,beat}:addr[SET_BITS+3:2];
    wire [31:0] write_data=fill ? ret_data:wdata;
    // One write port per byte bank, shared by refills and byte stores.
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1)begin:byte_bank
        reg [7:0] bank0[0:4*SETS-1],bank1[0:4*SETS-1];
        reg [7:0] read0,read1;
        wire wen=ret_valid && ret_ready && (fill || (writeop && hit_saved && !ret_error && strb[lane]));
        assign q0[8*lane+:8]=read0;assign q1[8*lane+:8]=read1;
        if(INSTRUCTION && WIDE_FETCH)begin:wide_read
            reg [7:0] hi0,hi1;
            assign q0_hi[8*lane+:8]=hi0;assign q1_hi[8*lane+:8]=hi1;
            always @(posedge clk)if(bank_read)begin
                hi0<=bank0[FETCH_WORDS==4 ? {read_index[SET_BITS+1:2],2'b01}:{read_index[SET_BITS+1:1],1'b1}];
                hi1<=bank1[FETCH_WORDS==4 ? {read_index[SET_BITS+1:2],2'b01}:{read_index[SET_BITS+1:1],1'b1}];
            end
        end else begin:narrow_read
            assign q0_hi[8*lane+:8]=0;assign q1_hi[8*lane+:8]=0;
        end
        if(INSTRUCTION && WIDE_FETCH && FETCH_WORDS==4)begin:quad_read
            reg [7:0] r02,r12,r03,r13;
            assign q0_2[8*lane+:8]=r02;assign q1_2[8*lane+:8]=r12;
            assign q0_3[8*lane+:8]=r03;assign q1_3[8*lane+:8]=r13;
            always @(posedge clk)if(bank_read)begin
                r02<=bank0[{read_index[SET_BITS+1:2],2'b10}];r12<=bank1[{read_index[SET_BITS+1:2],2'b10}];
                r03<=bank0[{read_index[SET_BITS+1:2],2'b11}];r13<=bank1[{read_index[SET_BITS+1:2],2'b11}];
            end
        end else begin:no_quad_read
            assign q0_2[8*lane+:8]=0;assign q1_2[8*lane+:8]=0;
            assign q0_3[8*lane+:8]=0;assign q1_3[8*lane+:8]=0;
        end
        always @(posedge clk)begin
            if(bank_read)begin
                read0<=bank0[read_index];
                read1<=bank1[read_index];
            end
            if(wen && !chosen_way)bank0[write_index]<=write_data[8*lane+:8];
            if(wen && chosen_way)bank1[write_index]<=write_data[8*lane+:8];
        end
    end endgenerate
    always @(posedge clk)begin
        if(!resetn)begin
            state<=IDLE; accesses<=0; misses<=0;h0<=0;h1<=0;
            reply_data<=0;reply_data_hi<=0;reply_data2<=0;reply_data3<=0; reply_error<=0; beat<=0; acc_error<=0;
            addr<=0;wdata<=0;strb<=0;writeop<=0;fill<=0;chosen_way<=0;hit_saved<=0;
            probe_result_valid<=0;probe_result_addr<=0;probe_h0<=0;probe_h1<=0;
        end else begin
          probe_result_valid<=probe_read && probe_commit;
          if(probe_read)begin
              probe_result_addr<=probe_addr;
              probe_h0<=probe_cacheable && valid0[probe_index] && tag0[probe_index]==probe_tag;
              probe_h1<=probe_cacheable && valid1[probe_index] && tag1[probe_index]==probe_tag;
          end
          if(probe_consumed)begin
              accesses<=accesses+1'b1;
              
          end
          // The blocking refill owns the port. Invalidate its registered
          // victim before any replacement data can be observed. The final
          // successful beat below has priority and revalidates the new line.
          // No live valid/LRU selection drives the wide valid write enable.

          case(state)
            IDLE:begin end
            LOOKUP:begin
                reply_error<=illegal; reply_data<=0; acc_error<=0; beat<=0;
                if(illegal)begin if(rsp_ready)state<=IDLE; end
                else if(hit && !writeop)begin
                    // No later request can replace this lookup before its
                    // response is accepted. Repeating the same LRU update on
                    // a stall is harmless and removes READY from this fanout.
                    
                    if(rsp_ready)state<=IDLE;
                end else begin
                    fill<=cacheable && !writeop;
                    chosen_way<=hit ? h1:!valid0[index] ? 0:!valid1[index] ? 1:lru[index];
                    hit_saved<=hit;state<=cmd_ready ? REFILL:COMMAND;
                    if(cacheable && !writeop)begin
                        misses<=misses+1'b1;
                    end
                end
            end
            COMMAND:if(cmd_ready)state<=REFILL;
            REFILL:if(ret_valid)begin
                acc_error<=acc_error|ret_error;
                if(!fill || beat==addr[3:2])reply_data<=ret_data;
                if(INSTRUCTION && WIDE_FETCH && fill && beat==(FETCH_WORDS==4 ? 2'd1:{addr[3],1'b1}))reply_data_hi<=ret_data;
                    if(INSTRUCTION && WIDE_FETCH && FETCH_WORDS==4 && fill && beat==2)reply_data2<=ret_data;
                    if(INSTRUCTION && WIDE_FETCH && FETCH_WORDS==4 && fill && beat==3)reply_data3<=ret_data;
                beat<=beat+1'b1;
                if(ret_last)begin
                    reply_error<=acc_error|ret_error|(fill && beat!=3);
                    if(fill && !acc_error && !ret_error && beat==3)begin
                        if(chosen_way)begin tag1[index]<=tag;end
                        else begin tag0[index]<=tag;end
                        
                    end
                    state<=return_reply && rsp_ready ? IDLE:REPLY;
                end
            end
            REPLY:if(rsp_ready)state<=IDLE;
            default:state<=IDLE;
          endcase
          // Last assignment wins on simultaneous response/request transfer.
          if(normal_accept)begin
              addr<=req_addr;wdata<=req_wdata;strb<=req_wstrb;writeop<=req_write;
              h0<=req_cacheable && valid0[req_index] && tag0[req_index]==req_tag;
              h1<=req_cacheable && valid1[req_index] && tag1[req_index]==req_tag;
              accesses<=accesses+1'b1;state<=LOOKUP;
              if(early_write)begin
                  fill<=0;chosen_way<=req_h1;hit_saved<=req_h0 || req_h1;
                  acc_error<=0;beat<=0;reply_error<=0;
                  state<=cmd_ready ? REFILL:COMMAND;
              end
          end
        end
    end
endmodule
