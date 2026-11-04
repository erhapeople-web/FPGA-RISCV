`timescale 1ns/1ps
// CPU-independent read-only ADC monitor on the already-buffered27MHz clock.
// Context is the latest coherent CDC snapshot at the40h read/timeout edge;
// neither the ADC conversion nor all eleven reads occur at the same instant.
module thermal_monitor #(
    parameter CLK_HZ=27000000, BAUD=115200,
    parameter SAMPLE_CYCLES=27000000, WARMUP_CYCLES=2700000,
    parameter ACCESS_TIMEOUT=270000
)(input wire clk27,resetn,input wire [31:0] context_data,
  output wire tx,ot_sync,output reg measurement_ok);
    wire [7:0] address;
    wire select,enable,ready,ot,conversion_done;
    wire [15:0] data;
    ADC #(.CREG_00H(16'h903f),.CREG_01H(16'hd01e),.CREG_02H(16'h0009),
        .CREG_03H(16'h0004),.CREG_05H(16'h0000),.CREG_07H(16'h0004),
        .CREG_2AH(16'h0cc2),.CREG_2BH(16'h0a5b))
    u_adc(.VAUX(32'b0),.clk(clk27),.PADDR(address),.PSEL(select),.PENABLE(enable),
        .PWRITE(1'b0),.CONVST(1'b0),.RST_N(resetn),.PREADY(ready),.PDATA(data),
        .OVER_TEMP(ot),.LOGIC_DONE_A(conversion_done),.LOGIC_DONE_B(),
        .ADC_CLK_OUT(),.DMODIFIED(),.ALARM());
    wire [175:0] registers;
    wire [10:0] read_mask;
    wire [31:0] context_at_T;
    wire sample_valid,report_ready,fresh,valid,error;
    thermal_reader #(.SAMPLE_CYCLES(SAMPLE_CYCLES),.WARMUP_CYCLES(WARMUP_CYCLES),
        .ACCESS_TIMEOUT(ACCESS_TIMEOUT)) u_reader(
        .clk(clk27),.resetn(resetn),.adc_ready(ready),.adc_data(data),.adc_ot(ot),
        .adc_conversion_done(conversion_done),.report_ready(report_ready),
        .context_data(context_data),.context_at_T(context_at_T),
        .address(address),.select(select),.enable(enable),.registers(registers),
        .read_mask(read_mask),.sample_valid(sample_valid),.fresh(fresh),.valid(valid),
        .error(error),.ot_sync(ot_sync));
    // Held report health with a conservative diagnostic stop at code2816
    // (about70.12C). This is a test policy, not the device's temperature rating.
    // V remains a conversion-valid flag even above this stop code. OT is not
    // masked or reprogrammed and clears health without waiting for the UART.
    always @(posedge clk27)begin
        if(!resetn)measurement_ok<=0;
        else if(ot_sync)measurement_ok<=0;
        else if(sample_valid && report_ready)
            measurement_ok<=valid && read_mask==11'h7ff && !error && !ot_sync && registers[15:4]<12'd2816;
    end
    thermal_report #(.DIVISOR(CLK_HZ/BAUD)) u_report(
        .clk(clk27),.resetn(resetn),.sample_valid(sample_valid),.report_ready(report_ready),
        .registers(registers),.read_mask(read_mask),.context_at_T(context_at_T),
        .fresh(fresh),.valid(valid),.error(error),.ot(ot_sync),.tx(tx));
endmodule

module thermal_reader #(
    parameter SAMPLE_CYCLES=27000000,WARMUP_CYCLES=2700000,ACCESS_TIMEOUT=270000
)(input wire clk,resetn,adc_ready,adc_ot,adc_conversion_done,report_ready,
  input wire [15:0] adc_data,input wire [31:0] context_data,output reg [31:0] context_at_T,
  output reg [7:0] address,
  output wire select,enable,output reg [175:0] registers,
  output reg [10:0] read_mask,output wire sample_valid,
  output reg fresh,valid,error,output wire ot_sync);
    reg ot_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ot_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg done_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg done_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg done_previous,conversion_seen,done_armed;
    reg [1:0] done_fill;
    // The two reset-initialized 0s are not observations of the ADC pin.
    // Fill both synchronizer stages, then require a real synchronized low
    // before accepting any rising edge as a new conversion indication.
    wire conversion_edge=done_armed && done_sync_q && !done_previous;
    reg [2:0] state;
    reg [3:0] register_index;
    reg [31:0] counter;
    localparam WARMUP=0,IDLE=1,SETUP_A=2,SETUP_B=3,ACCESS=4,GAP=5,REPORT=6;
    localparam WC=(WARMUP_CYCLES<1)?1:WARMUP_CYCLES;
    localparam SC=(SAMPLE_CYCLES<1)?1:SAMPLE_CYCLES;
    localparam AC=(ACCESS_TIMEOUT<1)?1:ACCESS_TIMEOUT;
    assign select=(state==SETUP_A || state==SETUP_B || state==ACCESS);
    assign enable=(state==ACCESS);
    assign sample_valid=(state==REPORT);
    assign ot_sync=ot_sync_q;
    // Keep two physical synchronizer FFs for each asynchronous ADC indication.
    // resetn is free_clk_rst_n: async assertion with local27MHz sync release.
    // An asynchronous reset also prevents replacement by a two-bit SRL cell.
    always @(posedge clk or negedge resetn)begin
        if(!resetn)begin
            ot_meta<=0;ot_sync_q<=0;done_meta<=0;done_sync_q<=0;
        end else begin
            ot_meta<=adc_ot;ot_sync_q<=ot_meta;
            done_meta<=adc_conversion_done;done_sync_q<=done_meta;
        end
    end
    always @* begin
        case(register_index)
          0:address=8'h40;1:address=8'h65;2:address=8'h6a;
          3:address=8'h00;4:address=8'h01;5:address=8'h02;
          6:address=8'h03;7:address=8'h05;8:address=8'h07;
          9:address=8'h2a;default:address=8'h2b;
        endcase
    end
    always @(posedge clk)begin
        if(!resetn)begin
            done_previous<=0;conversion_seen<=0;done_armed<=0;done_fill<=0;state<=WARMUP;
            register_index<=0;counter<=0;registers<=0;read_mask<=0;
            fresh<=0;valid<=0;error<=0;context_at_T<=0;
        end else begin
            done_previous<=done_sync_q;
            if(done_fill!=2)done_fill<=done_fill+1'b1;
            if(done_fill==2 && !done_sync_q)done_armed<=1;
            if(conversion_edge)conversion_seen<=1;
            case(state)
              WARMUP:if(counter>=WC-1 && report_ready)begin
                  state<=SETUP_A;counter<=0;register_index<=0;
                  registers<=0;read_mask<=0;fresh<=0;valid<=0;error<=0;
              end else if(counter<WC-1)counter<=counter+1'b1;
              IDLE:if(counter>=SC-1 && report_ready)begin
                  state<=SETUP_A;counter<=0;register_index<=0;
                  registers<=0;read_mask<=0;fresh<=0;valid<=0;error<=0;
              end else if(counter<SC-1)counter<=counter+1'b1;
              SETUP_A:state<=SETUP_B;
              SETUP_B:begin state<=ACCESS;counter<=0;end
              ACCESS:if(adc_ready)begin
                  registers[register_index*16 +: 16]<=adc_data;
                  read_mask[register_index]<=1;
                  if(register_index==0)begin
                      context_at_T<=context_data;
                      fresh<=conversion_seen || conversion_edge;
                      valid<=(conversion_seen || conversion_edge) &&
                             adc_data[15:4]!=0 && adc_data[15:4]!=12'hfff;
                      conversion_seen<=0;
                  end
                  state<=GAP;counter<=0;
              end else if(counter>=AC-1)begin
                  error<=1;
                  if(register_index==0)begin context_at_T<=context_data;fresh<=0;valid<=0;conversion_seen<=0;end
                  state<=GAP;counter<=0;
              end else counter<=counter+1'b1;
              // Drop SECEN/PSEL for a complete cycle after completion/timeout.
              GAP:if(register_index==10)state<=REPORT;
                  else begin register_index<=register_index+1'b1;state<=SETUP_A;end
              REPORT:if(report_ready)begin state<=IDLE;counter<=0;end
              default:begin state<=WARMUP;counter<=0;end
            endcase
        end
    end
endmodule

module thermal_report #(parameter DIVISOR=234)(
    input wire clk,resetn,sample_valid,input wire [175:0] registers,
    input wire [10:0] read_mask,input wire [31:0] context_at_T,input wire fresh,valid,error,ot,
    output wire report_ready,tx);
    localparam LINE_BYTES=135;
    reg active;
    reg [7:0] index;
    reg [175:0] captured;
    reg [31:0] captured_context;
    reg [10:0] captured_mask;
    reg captured_fresh,captured_valid,captured_error,captured_ot;
    reg [31:0] next_sequence,captured_sequence;
    wire tx_ready;
    assign report_ready=!active && tx_ready;
    function [7:0] hd;
        input [3:0] n;
        begin hd=(n<10)?8'h30+n:8'h61+n-10;end
    endfunction
    function [31:0] hx16;
        input [15:0] n;
        begin hx16={hd(n[15:12]),hd(n[11:8]),hd(n[7:4]),hd(n[3:0])};end
    endfunction
    function [63:0] hx32;
        input [31:0] n;
        begin hx32={hx16(n[31:16]),hx16(n[15:0])};end
    endfunction
    wire [LINE_BYTES*8-1:0] line={
        "TH3 N=",hx32(captured_sequence)," T=",hx16(captured[15:0]),
        " HI=",hx16(captured[31:16])," LO=",hx16(captured[47:32]),
        " C0=",hx16(captured[63:48])," C1=",hx16(captured[79:64]),
        " C2=",hx16(captured[95:80])," C3=",hx16(captured[111:96]),
        " C5=",hx16(captured[127:112])," C7=",hx16(captured[143:128]),
        " U=",hx16(captured[159:144])," L=",hx16(captured[175:160]),
        " M=",hx16({5'b0,captured_mask})," F=",(captured_fresh?8'h31:8'h30),
        " O=",(captured_ot?8'h31:8'h30)," V=",(captured_valid?8'h31:8'h30),
        " E=",(captured_error?8'h31:8'h30)," X=",hx32(captured_context),8'h0d,8'h0a};
    wire [7:0] character=line[(LINE_BYTES-1-index)*8 +:8];
    always @(posedge clk)begin
        if(!resetn)begin
            active<=0;index<=0;captured<=0;captured_mask<=0;captured_context<=0;
            captured_fresh<=0;captured_valid<=0;captured_error<=0;captured_ot<=0;
            next_sequence<=0;captured_sequence<=0;
        end else if(sample_valid && report_ready)begin
            captured<=registers;captured_mask<=read_mask;captured_context<=context_at_T;
            captured_fresh<=fresh;captured_valid<=valid;captured_error<=error;captured_ot<=ot;
            captured_sequence<=next_sequence;next_sequence<=next_sequence+1'b1;
            active<=1;index<=0;
        end else if(active && tx_ready)begin
            if(index==LINE_BYTES-1)active<=0;else index<=index+1'b1;
        end
    end
    thermal_uart #(.DIVISOR(DIVISOR)) u_tx(.clk(clk),.resetn(resetn),
        .valid(active),.data(character),.ready(tx_ready),.tx(tx));
endmodule

module thermal_uart #(parameter DIVISOR=234)(
    input wire clk,resetn,valid,input wire [7:0] data,output wire ready,tx);
    localparam DIV=(DIVISOR<2)?2:DIVISOR;
    reg busy;
    reg [9:0] bits;
    reg [3:0] count;
    reg [31:0] timer;
    assign ready=!busy;
    assign tx=busy?bits[0]:1'b1;
    always @(posedge clk)begin
        if(!resetn)begin busy<=0;bits<=10'h3ff;count<=0;timer<=0;end
        else if(!busy)begin
            if(valid)begin bits<={1'b1,data,1'b0};busy<=1;count<=0;timer<=DIV-1;end
        end else if(timer!=0)timer<=timer-1'b1;
        else if(count==9)busy<=0;
        else begin bits<={1'b1,bits[9:1]};count<=count+1'b1;timer<=DIV-1;end
    end
endmodule
