#include "postprocess.h"
typedef struct {uint32_t lo,hi;} pp_u64;
uint32_t __mulsi3(uint32_t a,uint32_t b){uint32_t r=0;while(b){if(b&1u)r+=a;a<<=1;b>>=1;}return r;}
static pp_u64 add64(pp_u64 a,pp_u64 b){pp_u64 r;r.lo=a.lo+b.lo;r.hi=a.hi+b.hi+(r.lo<a.lo);return r;}
static pp_u64 sub64(pp_u64 a,pp_u64 b){pp_u64 r;r.lo=a.lo-b.lo;r.hi=a.hi-b.hi-(a.lo<b.lo);return r;}
static int greater64(pp_u64 a,pp_u64 b){return a.hi>b.hi||(a.hi==b.hi&&a.lo>b.lo);}
static pp_u64 mul64_32(pp_u64 a,uint32_t b){
 pp_u64 r={0,0};while(b){if(b&1u)r=add64(r,a);a.hi=(a.hi<<1)|(a.lo>>31);a.lo<<=1;b>>=1;}return r;
}
static pp_u64 mul32(uint32_t a,uint32_t b){pp_u64 x={a,0};return mul64_32(x,b);}
static int rne64(pp_u64 a,unsigned shift,uint32_t *out){
 if(!shift||shift>31)return 2;
 uint32_t upper=a.hi>>shift,q=(a.hi<<(32-shift))|(a.lo>>shift),r=a.lo&((1u<<shift)-1),half=1u<<(shift-1);
 if(r>half||(r==half&&(q&1u))){q++;if(!q)upper++;}if(upper)return 2;*out=q;return 0;
}
static int read32(const pp_input *in,uint32_t a,uint32_t *v){uint8_t p[4];if(in->read(in->ctx,a,p,4))return 1;*v=p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);return 0;}
static int probability(const pp_input *in,uint32_t address,uint32_t *p){
 uint8_t q[2];if(in->read(in->ctx,address,q,2))return 1;int32_t code=(int16_t)((uint32_t)q[0]|((uint32_t)q[1]<<8));if(code<-4096)code=-4096;if(code>4096)code=4096;
 if(read32(in,in->sigmoid+4*(uint32_t)(code+4096),p))return 1;return *p>32768u ? 2:0;
}
static pp_u64 area(const pp_box *b){return mul32((uint32_t)(b->v[2]-b->v[0]),(uint32_t)(b->v[3]-b->v[1]));}
static int32_t maximum(int32_t a,int32_t b){return a>b ? a:b;}
static int32_t minimum(int32_t a,int32_t b){return a<b ? a:b;}
static int suppress(const pp_box *a,const pp_box *b,pp_u64 aa){
 if(a->v[5]!=b->v[5])return 0;
 int32_t dx=minimum(a->v[2],b->v[2])-maximum(a->v[0],b->v[0]),dy=minimum(a->v[3],b->v[3])-maximum(a->v[1],b->v[1]);
 pp_u64 inter=mul32(dx>0?(uint32_t)dx:0,dy>0?(uint32_t)dy:0),un=sub64(add64(aa,area(b)),inter);
 return greater64(mul64_32(inter,100),mul64_32(un,45));
}
int pp_nms(pp_workspace *w,unsigned n,unsigned *count){
 if(!w||!count||n>PP_CANDIDATES)return 2;*count=0;
 for(unsigned i=0;i<n;i++){
  pp_box *b=w->candidates+i;
  for(unsigned j=0;j<4;j++)if(b->v[j]<-266240||b->v[j]>307200)return 2;
  if(b->v[2]<b->v[0]||b->v[3]<b->v[1]||b->v[2]-b->v[0]>524288||b->v[3]-b->v[1]>524288||b->v[4]<0||b->v[4]>32768||b->v[5]<0||b->v[5]>=80)return 2;
  unsigned j=i;while(j&&w->candidates[w->order[j-1]].v[4]<b->v[4]){w->order[j]=w->order[j-1];j--;}w->order[j]=(uint16_t)i;
 }
 unsigned remaining=n;
 while(remaining&&*count<PP_OUTPUTS){
  unsigned idx=w->order[0];w->output[*count]=w->candidates[idx];(*count)++;pp_u64 aa=area(w->candidates+idx);unsigned dst=0;
  for(unsigned i=1;i<remaining;i++){unsigned j=w->order[i];if(!suppress(w->candidates+idx,w->candidates+j,aa))w->order[dst++]=(uint16_t)j;}
  remaining=dst;
 }
 return 0;
}
int pp_run(const pp_input *in,pp_workspace *w,unsigned *count){
 if(!in||!in->read||!w||!count)return 2;*count=0;
 unsigned sizes[3]={20,10,5},strides[3]={8,16,32},num=0;
 if(in->sigmoid>0xffffffffu-32772u)return 2;
 for(unsigned level=0;level<3;level++){
  unsigned h=sizes[level],pixels=h*h,stride=strides[level];
  if(in->heads[level]>0xffffffffu-510*pixels||in->anchors[level]>0xffffffffu-24)return 2;
  for(unsigned anchor=0;anchor<3;anchor++){
   uint32_t aw,ah;if(read32(in,in->anchors[level]+anchor*8,&aw)||read32(in,in->anchors[level]+anchor*8+4,&ah))return 1;
   if(!aw||!ah||aw>131072||ah>131072)return 2;
   for(unsigned gy=0;gy<h;gy++)for(unsigned gx=0;gx<h;gx++){
    unsigned at=gy*h+gx;uint32_t base=in->heads[level]+2*(anchor*85*pixels+at),obj,best=0,cls=0;
    if(probability(in,base+8*pixels,&obj))return 1;
    /* With pclass<=32768, exact rounded score<=objectness. */
    if(obj<=8192)continue;
    for(unsigned c=0;c<80;c++){uint32_t p;if(probability(in,base+2*(5+c)*pixels,&p))return 1;if(p>best){best=p;cls=c;}}
    uint32_t score;if(rne64(mul32(obj,best),15,&score))return 2;
#ifdef MUTANT_THRESHOLD
    if(score<8192)continue;
#else
    if(score<=8192)continue;
#endif
    uint32_t p[4];for(unsigned c=0;c<4;c++)if(probability(in,base+2*c*pixels,p+c))return 1;
    uint32_t cx,cy,bw,bh,half_w,half_h;
    if(rne64(mul32(2*p[0],stride*256),15,&cx)||rne64(mul32(2*p[1],stride*256),15,&cy))return 2;
    /* Width square may equal2^32; preserve hi word before anchor product. */
    if(rne64(mul64_32(mul32(2*p[2],2*p[2]),aw),30,&bw)||rne64(mul64_32(mul32(2*p[3],2*p[3]),ah),30,&bh))return 2;
    pp_u64 x={bw,0},y={bh,0};if(rne64(x,1,&half_w)||rne64(y,1,&half_h))return 2;
    int32_t center_x=(int32_t)cx+(int32_t)(gx*stride*256)-(int32_t)(stride*128),center_y=(int32_t)cy+(int32_t)(gy*stride*256)-(int32_t)(stride*128);
    if(num>=PP_CANDIDATES)return 2;pp_box *box=w->candidates+num++;
    box->v[0]=center_x-(int32_t)half_w;box->v[1]=center_y-(int32_t)half_h;box->v[2]=center_x+(int32_t)half_w;box->v[3]=center_y+(int32_t)half_h;box->v[4]=(int32_t)score;box->v[5]=(int32_t)cls;
   }
  }
 }
 return pp_nms(w,num,count);
}
