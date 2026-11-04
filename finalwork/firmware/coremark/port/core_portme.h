#ifndef AI_CORE_PORT_H
#define AI_CORE_PORT_H
#include <stdint.h>
#include <stddef.h>
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define COMPILER_VERSION "GCC " __VERSION__
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "-march=rv32i -mabi=ilp32 -O2 -ffreestanding"
#endif
#define MEM_LOCATION "STATIC SRAM"
typedef int16_t ee_s16;
typedef uint16_t ee_u16;
typedef int32_t ee_s32;
typedef uint32_t ee_u32;
typedef uint8_t ee_u8;
typedef double ee_f32;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
typedef uint64_t CORE_TICKS;
#define CORETIMETYPE uint64_t
#define align_mem(x) ((void *)(((uintptr_t)(x)+3u)&~3u))
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#ifndef ITERATIONS
#define ITERATIONS 2000
#endif
#ifndef VALIDATION_RUN
#define VALIDATION_RUN 0
#endif
#define PERFORMANCE_RUN (!VALIDATION_RUN)
#define PROFILE_RUN 0
extern ee_u32 default_num_contexts;
typedef struct { ee_u8 portable_id; } core_portable;
void portable_init(core_portable *, int *, char *[]);
void portable_fini(core_portable *);
int ee_printf(const char *, ...);
#endif
