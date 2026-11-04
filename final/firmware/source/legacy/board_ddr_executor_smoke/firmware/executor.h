#ifndef EXECUTOR_H
#define EXECUTOR_H
#include <stdint.h>
/* ABI v0x10000: uint32 little-endian words, offsets are backend byte offsets.
   probe must be side-effect free; read/write return 0 on success. Backend must
   remain stable for one execute call. No concurrent writers or asynchronous IO.
   MAC callback submits exactly one beat; on last waits/returns checked result.
   Execution stops on IO/MAC failure; prior valid output writes may exist.
   Descriptor preflight failure guarantees zero output writes. */
typedef struct {
 void *ctx;
 int (*probe)(void *,uint32_t,uint32_t,int);
 int (*read)(void *,uint32_t,uint8_t *,uint32_t);
 int (*write)(void *,uint32_t,const uint8_t *,uint32_t);
 int (*mac)(void *,const uint8_t[8],const uint8_t[8],unsigned,unsigned,unsigned,int32_t,unsigned,int32_t,int32_t *);
} ai_backend;
enum {AI_OK=0,AI_DESCRIPTOR=1,AI_ADDRESS=2,AI_IO=3,AI_MAC=4,AI_NUMERIC=5};
int ai_execute(const uint32_t words[40],const ai_backend *backend);
#endif
