/* Camera firmware ABI and v0x10002 central-crop progress contract. */
#ifndef CAMERA_HOOKS_H
#define CAMERA_HOOKS_H
#include <stdint.h>

/* 8 little-endian u32: phase,node,frame_seq,cycles_lo,cycles_hi,calls,hits,misses.
 * Successful split sequence: 1,2,3,4@1..119,6,7,8,5.
 * Readers also accept the complete legacy sequence without 6/7/8. */
#define CAM_PHASE_CAPTURE 1u
#define CAM_PHASE_PREPROCESS 2u
#define CAM_PHASE_INPUT_READY 3u
#define CAM_PHASE_NODE 4u
#define CAM_PHASE_OSD_DONE 5u
#define CAM_PHASE_GRAPH_DONE 6u
#define CAM_PHASE_RESULT_READY 7u
#define CAM_PHASE_OSD_SUBMITTED 8u
#define CAM_PROGRESS_PAYLOAD 32u
#define CAM_LAST_NODE 119u
#define CAM_MAX_BOXES 16u
#define CAM_BOX_BYTES 24u

#define CAM_PREPROCESS_VERSION 0x10002u
#define CAM_SNAPSHOT_W 320u
#define CAM_SNAPSHOT_H 180u
#define CAM_SNAPSHOT_PIXELS (CAM_SNAPSHOT_W*CAM_SNAPSHOT_H)
#define CAM_INPUT_W 160u
#define CAM_INPUT_H 160u
#define CAM_INPUT_PLANE 25600u
#define CAM_INPUT_BYTES (3u*CAM_INPUT_PLANE)
#define CAM_CROP_X 80u
#define CAM_CROP_Y 10u
#define CAM_OSD_ORIGIN_X 320u
#define CAM_OSD_ORIGIN_Y 40u
#define CAM_DDR_LOW 16777216u
#define CAM_DDR_HIGH 19353760u
#define CAM_INPUT_BASE 18969760u

/* Called only from admitted application RUN, before actual-input hashing. */
int camera_prepare_input(void*);
int __wrap_platform_read(void*,uint32_t,uint8_t*,uint32_t);
int __wrap_platform_write(void*,uint32_t,const uint8_t*,uint32_t);
int __wrap_platform_send(void*,const uint8_t*,uint32_t);
void __wrap_ul_feed(void*,uint8_t);
void __wrap_ul_timeout(void*);
int __wrap_ai_graph_run(void*,const void*,uint32_t,uint32_t,
                       int(*)(void*,uint32_t,const uint32_t[40]),void*);
int __real_platform_read(void*,uint32_t,uint8_t*,uint32_t);
int __real_platform_write(void*,uint32_t,const uint8_t*,uint32_t);
int __real_platform_send(void*,const uint8_t*,uint32_t);
void __real_ul_feed(void*,uint8_t);
void __real_ul_timeout(void*);
int __real_ai_graph_run(void*,const void*,uint32_t,uint32_t,
                       int(*)(void*,uint32_t,const uint32_t[40]),void*);
uint32_t ul_crc32(const uint8_t*,uint32_t);
#endif
