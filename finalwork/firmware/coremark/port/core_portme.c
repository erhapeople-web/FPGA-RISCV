/* AI_cpu platform glue. EEMBC benchmark kernels are not modified. */
#include "coremark.h"
#include "platform.h"
#include <stdarg.h>
volatile ee_s32 seed1_volatile=0;
volatile ee_s32 seed2_volatile=0;
volatile ee_s32 seed3_volatile=0x66;
volatile ee_s32 seed4_volatile=ITERATIONS;
volatile ee_s32 seed5_volatile=0;
ee_u32 default_num_contexts=1;
static uint64_t begin_tick,end_tick;
extern volatile uint32_t cm_nonce;
extern volatile char cm_mode;
void cm_run_identity(void);

static uint64_t read_ticks(void) {
    uint32_t a,b,c;
    do { a=MTIME_HI;b=MTIME_LO;c=MTIME_HI; }while(a!=c);
    return ((uint64_t)a<<32)|b;
}
void start_time(void) { begin_tick=read_ticks(); }
void stop_time(void) { end_tick=read_ticks(); }
CORE_TICKS get_time(void) { return end_tick-begin_tick; }
secs_ret time_in_secs(CORE_TICKS ticks) {
    uint32_t seconds=0,remainder=0;
    for(int bit=63;bit>=0;--bit) {
        remainder=(remainder<<1)|(uint32_t)((ticks>>bit)&1u);
        if(remainder>=CPU_HZ) { remainder-=CPU_HZ;if(bit<32)seconds|=1u<<bit; }
    }
    return seconds;
}
static void put(char ch) { while(!(UART_STATUS&1u)){} UART_TX=(uint8_t)ch; }
static void print_uint(uint32_t value,unsigned radix,unsigned width,char padding) {
    char buffer[32];unsigned length=0;
    do { unsigned digit=value%radix;buffer[length++]="0123456789abcdef"[digit];value/=radix; }while(value);
    while(width>length) { put(padding);width--; }
    while(length)put(buffer[--length]);
}
int ee_printf(const char *fmt,...) {
    va_list ap;va_start(ap,fmt);
    while(*fmt) {
        if(*fmt!='%') { put(*fmt++);continue; }
        ++fmt;unsigned width=0;char padding=' ';int longarg=0;
        if(*fmt=='0') { padding='0';fmt++; }
        while(*fmt>='0' && *fmt<='9') { width=width*10+(unsigned)(*fmt-'0');fmt++; }
        if(*fmt=='l') { longarg=1;fmt++; }
        char type=*fmt++;
        if(type=='s') { const char *s=va_arg(ap,const char *);while(*s)put(*s++); }
        else if(type=='c')put((char)va_arg(ap,int));
        else if(type=='%')put('%');
        else if(type=='d' || type=='i') {
            int32_t n=longarg ? (int32_t)va_arg(ap,long):va_arg(ap,int);
            uint32_t u=(uint32_t)n;if(n<0) { put('-');u=0u-u; }
            print_uint(u,10,width,padding);
        } else if(type=='u' || type=='x') {
            uint32_t n=longarg ? (uint32_t)va_arg(ap,unsigned long):va_arg(ap,unsigned int);
            print_uint(n,type=='x' ? 16:10,width,padding);
        }
    }
    va_end(ap);return 0;
}
void portable_init(core_portable *p,int *argc,char *argv[]) {
    (void)argc;(void)argv;p->portable_id=1;GPIO=0;
    cm_run_identity();
}
void portable_fini(core_portable *p) {
    uint64_t elapsed=get_time();p->portable_id=0;
    ee_printf("EXACT_CYCLES_HEX=%08x%08x CPU_HZ=%u ITERATIONS=%u SEQ=00000003 MODE=%c NONCE=%08x\n",(uint32_t)(elapsed>>32),(uint32_t)elapsed,CPU_HZ,ITERATIONS,cm_mode,cm_nonce);
    ee_printf("CACHE_COUNTERS IC_ACCESS=%08x IC_MISS=%08x DC_ACCESS=%08x DC_MISS=%08x\n",MMIO(0x20004020u),MMIO(0x20004024u),MMIO(0x20004028u),MMIO(0x2000402cu));
}
