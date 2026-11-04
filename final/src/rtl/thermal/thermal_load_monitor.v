`timescale 1ns/1ps
// Exclusive JDRP ownership of the ADC: NO APB transactions in this image.
// ALARM0 supplies the independent ~70C stop; OT keeps its125C/50C settings.
module thermal_load_monitor #(
    parameter integer CLOCK_HZ=27000000,
    parameter integer WARMUP_CYCLES=2700000,
    parameter integer CONVERSION_TIMEOUT_CYCLES=27000000,
    parameter integer LIMIT_SECONDS=300
)(input wire clk27,resetn,
  output wire permit,armed,fault,ot_sync,alarm_sync,
  output wire [3:0] fault_reason);
    wire [15:0] unused_adc_data;
    wire adc_ready,adc_ot,adc_done;
    wire [4:0] adc_alarms;
    ADC #(.CREG_00H(16'h903f),.CREG_01H(16'hd01e),.CREG_02H(16'h0009),
        .CREG_03H(16'h0004),.CREG_05H(16'h0000),.CREG_07H(16'h0004),
        .CREG_20H(16'h0b00),.CREG_21H(16'h0a5b),
        .CREG_2AH(16'h0cc2),.CREG_2BH(16'h0a5b)) u_adc(
        .VAUX(32'b0),.clk(clk27),.PADDR(8'b0),.PSEL(1'b0),.PENABLE(1'b0),
        .PWRITE(1'b0),.CONVST(1'b0),.RST_N(resetn),.PREADY(adc_ready),.PDATA(unused_adc_data),
        .OVER_TEMP(adc_ot),.LOGIC_DONE_A(adc_done),.LOGIC_DONE_B(),
        .ADC_CLK_OUT(),.DMODIFIED(),.ALARM(adc_alarms));
    thermal_load_guard #(.CLOCK_HZ(CLOCK_HZ),.WARMUP_CYCLES(WARMUP_CYCLES),
        .CONVERSION_TIMEOUT_CYCLES(CONVERSION_TIMEOUT_CYCLES),.LIMIT_SECONDS(LIMIT_SECONDS)) u_guard(
        .clk(clk27),.resetn(resetn),.alarm_async(adc_alarms[0]),.ot_async(adc_ot),.done_async(adc_done),
        .permit(permit),.armed(armed),.fault(fault),.fault_reason(fault_reason),
        .ot_sync(ot_sync),.alarm_sync(alarm_sync));
endmodule
