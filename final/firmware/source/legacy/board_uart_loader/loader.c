#include "loader.h"
static uint32_t le32(const uint8_t*p){return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint16_t le16(const uint8_t*p){return (uint16_t)(p[0]|(unsigned)p[1]<<8);}
static void put32(uint8_t*p,uint32_t x){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(x>>(8*i));}
static void copy(uint8_t*d,const uint8_t*s,unsigned n){while(n--)*d++=*s++;}
static int equal(const uint8_t*a,const uint8_t*b,unsigned n){uint8_t d=0;while(n--)d|=*a++^*b++;return d==0;}
void ul_parser_reset(ul_loader*s){s->used=0;s->target=0;}
void ul_timeout(ul_loader*s){ul_parser_reset(s);}
void ul_global_reset(ul_loader*s){ul_parser_reset(s);s->next=s->total=s->last_offset=s->last_length=0;s->expected_seq=s->last_seq=s->begin_seq=s->commit_seq=0;s->active=s->validmask=s->sticky=s->last_valid=s->commit_region=0;if(!s->configured)s->sticky=1;}
void ul_failstop(ul_loader*s){s->sticky=1;s->active=s->validmask=s->last_valid=s->commit_region=0;}
int ul_init(ul_loader*s,const ul_region r[3],const ul_backend*io){
 uint8_t*p=(uint8_t*)s;for(unsigned i=0;i<sizeof(*s);i++)p[i]=0;
 if(!r||!io||!io->read||!io->write||!io->infer||!io->reply)goto bad;
 for(unsigned i=0;i<3;i++){
  if(!r[i].length||r[i].length>0xffffffffu-r[i].base)goto bad;
  for(unsigned j=0;j<i;j++)if(r[i].base<r[j].base+r[j].length&&r[j].base<r[i].base+r[i].length)goto bad;
  s->regions[i]=r[i];
 }
 if(r[2].length!=UL_INPUT_BYTES)goto bad;
 s->io=*io;s->configured=1;ul_global_reset(s);return UL_OK;
 bad:s->sticky=1;return UL_CONFIG;
}
static void response(ul_loader*s,unsigned status){uint8_t p[32];copy(p,s->packet,12);p[4]|=128;p[12]=12;p[13]=p[14]=p[15]=0;put32(p+16,status);put32(p+20,(s->packet[4]==UL_STATUS||s->packet[4]==UL_RUN)?0:s->next);put32(p+24,s->validmask);put32(p+28,ul_crc32(p,28));s->io.reply(s->io.ctx,p,32);}
static unsigned io_failure(ul_loader*s){ul_failstop(s);return UL_IO;}
static unsigned dispatch(ul_loader*s){
 uint8_t*p=s->packet;unsigned c=p[4],r=p[5],n=le16(p+12);uint16_t q=le16(p+6);uint32_t off=le32(p+8);
 if(le16(p+14)||c<UL_BEGIN||c>UL_RUN)return UL_WIRE;
 if(c==UL_STATUS||c==UL_RUN){
  if(r||off||n)return UL_WIRE;
  if(c==UL_STATUS)return UL_OK;
  if(s->sticky)return UL_FAILSTOP;
  if(s->validmask!=7||s->active)return UL_NOT_READY;
  if(s->io.infer(s->io.ctx))return io_failure(s);
  return UL_OK;
 }
 if(r<1||r>3)return UL_RANGE;
 if(s->sticky)return UL_FAILSTOP;
 ul_region*region=&s->regions[r-1];
 if(c==UL_BEGIN){
  if(off||n!=36)return UL_WIRE;
  if(le32(p+16)!=region->length)return UL_RANGE;
  if(r!=3&&!equal(p+20,region->sha,32))return UL_SHA;
  /* Delayed identical BEGIN cannot discard previously accepted DATA. */
  if(s->active==r&&s->begin_seq==q&&equal(p+20,s->expected_sha,32))return UL_OK;
  s->validmask&=(uint8_t)((1u<<(r-1))-1u);s->active=(uint8_t)r;s->begin_seq=q;s->expected_seq=(uint16_t)(q+1);s->next=0;s->total=region->length;s->last_valid=0;s->commit_region=0;copy(s->expected_sha,p+20,32);return UL_OK;
 }
 if(c==UL_COMMIT&&s->commit_region==r&&q==s->commit_seq&&off==s->total&&n==0)return UL_OK;
 if(s->active!=r)return UL_SEQUENCE;
 if(c==UL_DATA){
  if(!n||off>region->length||n>region->length-off)return UL_RANGE;
  if(s->last_valid&&q==s->last_seq&&off==s->last_offset&&n==s->last_length){
   uint8_t buf[64];for(unsigned i=0;i<n;){unsigned count=n-i;if(count>64)count=64;if(s->io.read(s->io.ctx,region->base+off+i,buf,count))return io_failure(s);if(!equal(buf,p+16+i,count))return UL_SEQUENCE;i+=count;}return UL_OK;
  }
  if(q!=s->expected_seq||off!=s->next)return UL_SEQUENCE;
  if(s->io.write(s->io.ctx,region->base+off,p+16,n))return io_failure(s);
  s->last_seq=q;s->last_offset=off;s->last_length=n;s->last_valid=1;s->next+=n;s->expected_seq=(uint16_t)(q+1);return UL_OK;
 }
 if(n)return UL_WIRE;
 if(q!=s->expected_seq)return UL_SEQUENCE;
 if(off!=s->next||s->next!=s->total)return UL_RANGE;
 ul_sha256 hash;uint8_t buf[64],digest[32];ul_sha_init(&hash);
 for(uint32_t i=0;i<s->total;){uint32_t count=s->total-i;if(count>64)count=64;if(s->io.read(s->io.ctx,region->base+i,buf,count))return io_failure(s);ul_sha_update(&hash,buf,count);i+=count;}
 ul_sha_final(&hash,digest);s->active=s->last_valid=0;
 if(!equal(digest,s->expected_sha,32))return UL_SHA;
 s->validmask|=(uint8_t)(1u<<(r-1));s->commit_region=(uint8_t)r;s->commit_seq=q;return UL_OK;
}
static void rejected_reset(ul_loader*s){
 /* Retain only a terminal partial magic; embedded candidates require host retry. */
 static const uint8_t magic[4]={'A','I','P','1'};unsigned keep=0;
 for(unsigned n=1;n<=3&&n<=s->used;n++)if(equal(s->packet+s->used-n,magic,n))keep=n;
 ul_parser_reset(s);for(unsigned i=0;i<keep;i++)s->packet[i]=magic[i];s->used=(uint16_t)keep;
}
void ul_feed(ul_loader*s,uint8_t byte){
 static const uint8_t magic[4]={'A','I','P','1'};
 if(!s->configured)return;
 if(s->used<4){if(byte==magic[s->used])s->packet[s->used++]=byte;else{s->used=(uint16_t)(byte=='A');if(s->used)s->packet[0]='A';}return;}
 s->packet[s->used++]=byte;
 if(s->used==16){unsigned n=le16(s->packet+12);if(n>256){response(s,UL_RANGE);rejected_reset(s);return;}s->target=(uint16_t)(20+n);}
 if(s->target&&s->used==s->target){unsigned n=s->target-4;if(ul_crc32(s->packet,n)!=le32(s->packet+n)){response(s,UL_WIRE);rejected_reset(s);}else{response(s,dispatch(s));ul_parser_reset(s);}}
}
