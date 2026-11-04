#ifndef AIP_LOADER_H
#define AIP_LOADER_H
#include <stdint.h>
#define UL_MAX_PAYLOAD 256u
#define UL_INPUT_BYTES 76800u
enum {UL_OK=0,UL_WIRE=1,UL_RANGE=2,UL_SEQUENCE=3,UL_SHA=4,UL_NOT_READY=5,UL_IO=6,UL_FAILSTOP=7,UL_CONFIG=8};
enum {UL_BEGIN=1,UL_DATA=2,UL_COMMIT=3,UL_STATUS=4,UL_RUN=5};
typedef struct {uint32_t h[8],lo,hi,used;uint8_t block[64];} ul_sha256;
void ul_sha_init(ul_sha256 *s);
void ul_sha_update(ul_sha256 *s,const uint8_t *p,uint32_t n);
void ul_sha_final(ul_sha256 *s,uint8_t digest[32]);
uint32_t ul_crc32(const uint8_t *p,uint32_t n);
typedef struct {uint32_t base,length;uint8_t sha[32];} ul_region;
typedef struct {
 void *ctx;
 int (*read)(void*,uint32_t,uint8_t*,uint32_t);
 int (*write)(void*,uint32_t,const uint8_t*,uint32_t);
 int (*infer)(void*);
 void (*reply)(void*,const uint8_t*,uint32_t);
} ul_backend;
typedef struct {
 ul_region regions[3];ul_backend io;
 uint8_t packet[276],expected_sha[32];
 uint32_t next,total,last_offset,last_length;
 uint16_t used,target,expected_seq,last_seq,begin_seq,commit_seq;
 uint8_t active,validmask,sticky,last_valid,configured,commit_region;
} ul_loader;
/* Returns CONFIG for null callbacks, overlapping/wrapping/zero regions or wrong input size. */
int ul_init(ul_loader *s,const ul_region regions[3],const ul_backend *io);
void ul_feed(ul_loader *s,uint8_t byte);
void ul_parser_reset(ul_loader *s);
void ul_timeout(ul_loader *s);
/* Caller has coordinated and completed backend/MAC/global reset before this call. */
void ul_global_reset(ul_loader *s);
void ul_failstop(ul_loader *s);
#endif
