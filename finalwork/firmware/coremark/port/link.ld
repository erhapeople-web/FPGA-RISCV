OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    ROM (rx) : ORIGIN = 0, LENGTH = 64K
    RAM (rw) : ORIGIN = 0x10000000, LENGTH = 64K
}
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > ROM
    .rodata : { *(.rodata .rodata.*) . = ALIGN(4); } > ROM
    .data : {
        __data_begin = .; *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4); __data_end = .;
    } > RAM AT > ROM
    __data_load = LOADADDR(.data);
    .bss (NOLOAD) : {
        . = ALIGN(4); __bss_begin = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(4); __bss_end = .;
    } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(__bss_end <= __stack_top - 8K, "BSS overlaps stack reservation")
    /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
