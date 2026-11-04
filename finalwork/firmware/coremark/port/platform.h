#ifndef AI_CPU_PLATFORM_H
#define AI_CPU_PLATFORM_H
#include <stdint.h>
#define CPU_HZ 100000000u
#define MMIO(a) (*(volatile uint32_t *)(a))
#define UART_TX MMIO(0x20000000u)
#define UART_STATUS MMIO(0x20000004u)
#define UART_RX MMIO(0x20000008u)
#define UART_IRQ_ENABLE MMIO(0x2000000cu)
#define GPIO MMIO(0x20001000u)
#define MTIME_LO MMIO(0x20002000u)
#define MTIME_HI MMIO(0x20002004u)
#define MTIMECMP_LO MMIO(0x20002008u)
#define MTIMECMP_HI MMIO(0x2000200cu)
#define MSIP MMIO(0x20002010u)
static inline void uart_puts(const char *s) {
    while (*s) { while (!(UART_STATUS & 1u)) {} UART_TX=(uint8_t)*s++; }
}
static inline void irq_disable(void) { __asm__ volatile("csrci mstatus, 8" ::: "memory"); }
#endif
