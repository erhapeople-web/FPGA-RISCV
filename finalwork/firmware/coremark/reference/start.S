.section .text.start,"ax",@progbits
.globl _start
_start:
    la sp, __stack_top
    la t0, __data_load
    la t1, __data_begin
    la t2, __data_end
copy_data:
    bgeu t1, t2, clear_bss_begin
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j copy_data
clear_bss_begin:
    la t1, __bss_begin
    la t2, __bss_end
clear_bss:
    bgeu t1, t2, start_main
    sw zero, 0(t1)
    addi t1, t1, 4
    j clear_bss
start_main:
    call main
stop:
    j stop
