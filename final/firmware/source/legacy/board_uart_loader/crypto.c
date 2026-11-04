#include "loader.h"
static const uint32_t k[64]={
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
static uint32_t ror(uint32_t x,unsigned n){return (x>>n)|(x<<(32-n));}
static void transform(ul_sha256*s){
 uint32_t w[16],a=s->h[0],b=s->h[1],c=s->h[2],d=s->h[3],e=s->h[4],f=s->h[5],g=s->h[6],h=s->h[7];
 for(unsigned i=0;i<16;i++){const uint8_t*p=s->block+4*i;w[i]=(uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3];}
 for(unsigned i=0;i<64;i++){
  if(i>=16){uint32_t x=w[(i+1)&15],y=w[(i+14)&15];w[i&15]+=(ror(x,7)^ror(x,18)^(x>>3))+w[(i+9)&15]+(ror(y,17)^ror(y,19)^(y>>10));}
  uint32_t t1=h+(ror(e,6)^ror(e,11)^ror(e,25))+((e&f)^(~e&g))+k[i]+w[i&15];
  uint32_t t2=(ror(a,2)^ror(a,13)^ror(a,22))+((a&b)^(a&c)^(b&c));
  h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
 }
 s->h[0]+=a;s->h[1]+=b;s->h[2]+=c;s->h[3]+=d;s->h[4]+=e;s->h[5]+=f;s->h[6]+=g;s->h[7]+=h;
}
void ul_sha_init(ul_sha256*s){static const uint32_t h[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};for(unsigned i=0;i<8;i++)s->h[i]=h[i];s->lo=s->hi=s->used=0;}
void ul_sha_update(ul_sha256*s,const uint8_t*p,uint32_t n){uint32_t old=s->lo;s->lo+=n;if(s->lo<old)s->hi++;while(n--){s->block[s->used++]=*p++;if(s->used==64){transform(s);s->used=0;}}}
void ul_sha_final(ul_sha256*s,uint8_t out[32]){
 uint32_t hi=(s->hi<<3)|(s->lo>>29),lo=s->lo<<3;
 s->block[s->used++]=128;if(s->used>56){while(s->used<64)s->block[s->used++]=0;transform(s);s->used=0;}
 while(s->used<56)s->block[s->used++]=0;
 for(unsigned i=0;i<4;i++){s->block[56+i]=(uint8_t)(hi>>(24-8*i));s->block[60+i]=(uint8_t)(lo>>(24-8*i));}transform(s);
 for(unsigned i=0;i<32;i++)out[i]=(uint8_t)(s->h[i>>2]>>(24-8*(i&3)));
}
uint32_t ul_crc32(const uint8_t*p,uint32_t n){uint32_t c=~0u;while(n--){c^=*p++;for(unsigned j=0;j<8;j++)c=(c>>1)^(0xedb88320u&(0u-(c&1u)));}return ~c;}
