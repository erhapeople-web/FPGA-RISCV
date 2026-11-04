#ifndef AP_PLATFORM_H
#define AP_PLATFORM_H
#include <stdint.h>
int platform_initialize(void);
int platform_probe(void*,uint32_t,uint32_t,int);
int platform_read(void*,uint32_t,uint8_t*,uint32_t);
int platform_write(void*,uint32_t,const uint8_t*,uint32_t);
int platform_mac(void*,const uint8_t[8],const uint8_t[8],unsigned,unsigned,unsigned,int32_t,unsigned,int32_t,int32_t*);
int platform_send(void*,const uint8_t*,uint32_t);
int platform_reset(void*);
int platform_receive(uint8_t*);
#endif
