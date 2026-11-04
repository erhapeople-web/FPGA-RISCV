#ifndef J5_CM_COMMAND_H
#define J5_CM_COMMAND_H
#include <stdint.h>
#define CM_COMMAND_BYTES 32u
/* ASCII: "J5CM5000V1 P 01234567 cccccccc\r\n". CRC32 covers bytes 0..21. */
static uint32_t cm_crc32_prefix(const uint8_t *data) {
    uint32_t crc=0xffffffffu;
    for(unsigned i=0;i<22u;i++) {
        crc^=data[i];
        for(unsigned bit=0;bit<8u;bit++)crc=(crc>>1)^((0u-(crc&1u))&0xedb88320u);
    }
    return ~crc;
}
static int cm_hex8(const uint8_t *p,uint32_t *result) {
    uint32_t value=0;
    for(unsigned i=0;i<8u;i++) {
        unsigned digit;
        if(p[i]>='0' && p[i]<='9')digit=p[i]-'0';
        else if(p[i]>='a' && p[i]<='f')digit=p[i]-'a'+10u;
        else return 0;
        value=(value<<4)|digit;
    }
    *result=value;return 1;
}
static int cm_parse_command(const uint8_t *frame,uint32_t *nonce,char *mode) {
    const char magic[10]={'J','5','C','M','5','0','0','0','V','1'};
    uint32_t received_crc;
    for(unsigned i=0;i<10u;i++)if(frame[i]!=(uint8_t)magic[i])return 0;
    if(frame[10]!=' ' || (frame[11]!='P' && frame[11]!='V') || frame[12]!=' ' ||
       frame[21]!=' ' || frame[30]!='\r' || frame[31]!='\n')return 0;
    if(!cm_hex8(frame+13,nonce) || !*nonce || !cm_hex8(frame+22,&received_crc))return 0;
    if(received_crc!=cm_crc32_prefix(frame))return 0;
    *mode=(char)frame[11];return 1;
}
#endif
