/* One invocation per reset; unchanged official kernels are called only here. */
#include "coremark.h"
#include "platform.h"
#include "command.h"
#include "identity.h"

extern volatile ee_s32 seed1_volatile,seed2_volatile,seed3_volatile,seed4_volatile,seed5_volatile;
extern int coremark_main_entry(void);
volatile uint32_t cm_nonce=0;
volatile char cm_mode=0;

static void halt(void) { for(;;)__asm__ volatile("nop"); }

void cm_run_identity(void) {
    ee_printf("CM5_SEEDS SEQ=00000002 MODE=%c NONCE=%08x SEED1=%08x SEED2=%08x SEED3=%08x SEED4=%08x SEED5=%08x CPU_HZ=%u ITERATIONS=%u\n",
              cm_mode,cm_nonce,(uint32_t)seed1_volatile,(uint32_t)seed2_volatile,
              (uint32_t)seed3_volatile,(uint32_t)seed4_volatile,(uint32_t)seed5_volatile,CPU_HZ,ITERATIONS);
}

int main(void) {
    uint8_t frame[CM_COMMAND_BYTES];uint32_t nonce;char mode;
    GPIO=0;
    ee_printf("J5_COREMARK_READY V=1 SEQ=00000000 SOURCE_ID=%s CPU_HZ=%u ITERATIONS=%u DATA_SIZE=2000 ISA=RV32I COMMAND_BYTES=32\n",
              CM_SOURCE_ID,CPU_HZ,ITERATIONS);
    for(unsigned i=0;i<CM_COMMAND_BYTES;i++) {
        uint32_t status;
        do {
            status=UART_STATUS;
            if(status&4u) { ee_printf("J5_COREMARK_REJECT RX_OVERRUN\n");GPIO=0xe1;halt(); }
        } while(!(status&2u));
        frame[i]=(uint8_t)UART_RX;
    }
    if(!cm_parse_command(frame,&nonce,&mode)) {
        ee_printf("J5_COREMARK_REJECT COMMAND_INVALID\n");GPIO=0xe2;halt();
    }
    cm_mode=mode;cm_nonce=nonce;
    seed1_volatile=mode=='P'?0:0x3415;
    seed2_volatile=seed1_volatile;
    seed3_volatile=0x66;seed4_volatile=5000;seed5_volatile=0;
    ee_printf("CM5_BEGIN SEQ=00000001 MODE=%c NONCE=%08x\n",cm_mode,cm_nonce);
    int returned=coremark_main_entry();
    ee_printf("AI_CPU_COREMARK_FINISHED SEQ=00000004 MODE=%c NONCE=%08x RETURN=%08x\n",cm_mode,cm_nonce,(uint32_t)returned);
    while(!(UART_STATUS&1u)){}
    GPIO=0xa5;halt();
    return 0;
}
