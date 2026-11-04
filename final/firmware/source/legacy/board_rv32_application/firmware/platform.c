#include "platform.h"
#include "production.h"
static ap_config cfg;
#define D ((volatile uint32_t*)0x20006000u)
#define M ((volatile uint32_t*)0x20005800u)
static unsigned platform_failed;
static int latch(void){platform_failed=1;return 1;}
int platform_initialize(void){
 if(platform_failed)return 1;
 ap_production_config(&cfg);
 if(D[0]!=0x44440001u||M[0]!=0x4d380001u)return latch();
 unsigned timeout=100000,s;
 do{s=D[2];if((s&32u)||!timeout--)return latch();}while(s&16u);
 if(s&15u)return latch();return 0;
}
static int word(unsigned write,uint32_t off,uint32_t data,unsigned mask,uint32_t *out){
 if(platform_failed)return 1;
 unsigned s=D[2],timeout=100000;if(s&63u)return latch();
 D[4]=off;D[5]=data;D[6]=mask;D[1]=write?2u:1u;
 do{s=D[2];if((s&0x30u)||!timeout--)return latch();}while(!(s&2u));
 uint32_t result=D[8];
 if((s&4u)||((s>>3)&1u)!=write||(D[2]&63u))return latch();
 *out=result;return 0;
}
int platform_probe(void *ctx,uint32_t off,uint32_t bytes,int write){
 (void)write;(void)ctx;return platform_failed||off<cfg.low||off>cfg.high||bytes>cfg.high-off||0;
}
int platform_read(void *ctx,uint32_t off,uint8_t *out,uint32_t bytes){
 if(platform_probe(ctx,off,bytes,0))return latch();
 while(bytes){unsigned lane=off&3u,n=4u-lane;uint32_t v;if(n>bytes)n=bytes;
  if(word(0,off&~3u,0,0,&v))return 1;
  for(unsigned i=0;i<n;i++)out[i]=(uint8_t)(v>>(8u*(lane+i)));
  off+=n;out+=n;bytes-=n;
 }return 0;
}
int platform_write(void *ctx,uint32_t off,const uint8_t *in,uint32_t bytes){
 if(platform_probe(ctx,off,bytes,1))return latch();
 while(bytes){unsigned lane=off&3u,n=4u-lane;uint32_t v=0,result;if(n>bytes)n=bytes;
  for(unsigned i=0;i<n;i++)v|=(uint32_t)in[i]<<(8u*(lane+i));
  if(word(1,off&~3u,v,((1u<<n)-1u)<<lane,&result))return 1;
  off+=n;in+=n;bytes-=n;
 }return 0;
}
int platform_mac(void *ctx,const uint8_t x[8],const uint8_t w[8],unsigned mask,unsigned first,unsigned last,int32_t bias,unsigned uns,int32_t zero,int32_t *acc){
 (void)ctx;if(platform_failed)return 1;if(!(M[2]&1u))return latch();
 uint32_t xl=0,xh=0,wl=0,wh=0;
 for(unsigned k=0;k<4;k++){xl|=(uint32_t)x[k]<<(8*k);xh|=(uint32_t)x[k+4]<<(8*k);wl|=(uint32_t)w[k]<<(8*k);wh|=(uint32_t)w[k+4]<<(8*k);}
 M[4]=xl;M[5]=xh;M[6]=wl;M[7]=wh;M[8]=(uint32_t)bias;M[9]=mask|(first<<8)|(last<<9)|(uns<<10)|(((uint32_t)zero&255u)<<16);M[1]=1;
 if(last){unsigned s,timeout=100000;do{s=M[2];if(!timeout--)return latch();}while(!(s&2u));if(s&4u)return latch();*acc=(int32_t)M[10];}
 return 0;
}

#define U ((volatile uint32_t*)0x20000000u)
int platform_send(void*ctx,const uint8_t*p,uint32_t n){(void)ctx;if(platform_failed)return 1;for(unsigned i=0;i<n;i++){unsigned budget=100000;uint32_t s;do{s=U[1];if((s&4u)||!budget--)return latch();}while(!(s&1u));U[0]=p[i];}return 0;}
/* No software-only recovery: physical coordinated reset is required. */
int platform_reset(void*ctx){(void)ctx;return latch();}
int platform_receive(uint8_t*out){if(platform_failed)return -1;unsigned budget=100000;while(budget--){uint32_t s=U[1];if(s&4u){latch();return -1;}if(s&2u){*out=(uint8_t)U[2];return 1;}}return 0;}
