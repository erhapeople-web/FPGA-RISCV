#ifndef EXECUTOR_H
#define EXECUTOR_H
#include <stdint.h>
/* ABI v0x10000: uint32 little-endian words, offsets are backend byte offsets.
   probe must be side-effect free; read/write return 0 on success. Backend must
   remain stable for one execute call. No concurrent writers or asynchronous IO.
   MAC callback submits exactly one beat; on last waits/returns checked result.
   Execution stops on IO/MAC failure; already-computed output bytes may remain,
   including a bytewise partial write if the backend reports a partial failure.
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
/* Conv dots up to1,152 bytes stage the input patches for at most two adjacent
   output pixels, then reuse those stable patches across output channels.
   Each channel's weights are read once per spatial tile. Input runs stay
   within a valid source row; padding is the descriptor's input zero point.
   Each complete IC/KY/KX-ordered MAC dot finishes before the next starts;
   only completed values are batched, in writes of at most four bytes.
   All staging uses automatic storage with no persistent cache or new BSS.
   Larger dots retain the general implementation. Prefetch and grouped writes
   may change callback order/counts and the valid output subset before an
   execution failure. No old failure prefix or atomic output is promised.
   Descriptor preflight and IO/MAC failure status codes remain unchanged.
   Unit-stride, unit-dilation 1x1 Conv without padding and with at most 512
   input channels per group stages eight adjacent pixels in 4096 bytes, then
   reuses them across output channels. Each pixel completes its IC-ordered
   MAC8 dot product before the next begins; completed outputs are batched in
   writes of at most 16 bytes. Read/write order and grouping may therefore
   differ from the general kernel. Failure stops immediately and may leave
   a reordered subset of valid, already-computed output bytes; no old failure
   prefix, atomic output element, or exact callback count is promised.
   Descriptor preflight failure still guarantees zero output writes. All
   staging is automatic storage, with no persistent state or new BSS.
   Budget the compiler-reported stack at integration. */
#endif
