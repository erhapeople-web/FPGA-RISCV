#include "executor.h"
/* Explicit RV32I compiler helpers; no libgcc or M-extension dependency. */
uint32_t __mulsi3(uint32_t a,uint32_t b){uint32_t r=0;while(b){if(b&1u)r+=a;a<<=1;b>>=1;}return r;}
static uint32_t divide(uint32_t n,uint32_t d,uint32_t *rem){
 uint32_t q=0,r=0;if(!d){if(rem)*rem=n;return 0xffffffffu;}
 for(unsigned k=32;k;k--){unsigned carry=r>>31;r=(r<<1)|((n>>(k-1))&1u);if(carry||r>=d){r-=d;q|=1u<<(k-1);}}
 if(rem)*rem=r;return q;
}
uint32_t __udivsi3(uint32_t a,uint32_t b){return divide(a,b,0);}
uint32_t __umodsi3(uint32_t a,uint32_t b){uint32_t r;divide(a,b,&r);return r;}
static unsigned es(unsigned t){return t==1||t==2 ? 1:t==3 ? 2:t==4 ? 4:0;}
static int product(uint32_t a,uint32_t b,uint32_t *out){
 uint32_t lo=0,hi=0,ahi=0;
 while(b){if(b&1u){uint32_t old=lo;lo+=a;hi+=ahi+(lo<old);}ahi=(ahi<<1)|(a>>31);a<<=1;b>>=1;}
 if(hi)return 1;*out=lo;return 0;
}
static int bytes4(uint32_t n,uint32_t c,uint32_t h,uint32_t w,unsigned e,uint32_t *out){
 uint32_t r;if(product(n,c,&r)||product(r,h,&r)||product(r,w,&r)||product(r,e,&r))return 1;*out=r;return 0;
}
static int overlap(uint32_t a,uint32_t an,uint32_t b,uint32_t bn){return a<b+bn&&b<a+an;}
static int range(const ai_backend *b,uint32_t a,uint32_t n,int wr){return !n||n>0xffffffffu-a||b->probe(b->ctx,a,n,wr);}
static int get(const ai_backend *b,uint32_t a,unsigned t,int32_t *v){
 uint8_t x[4];unsigned n=es(t);if(b->read(b->ctx,a,x,n))return AI_IO;
 uint32_t q=x[0];for(unsigned i=1;i<n;i++)q|=(uint32_t)x[i]<<(8*i);
 if(t==2)*v=(int8_t)q;else if(t==3)*v=(int16_t)q;else *v=(int32_t)q;return AI_OK;
}
static int put(const ai_backend *b,uint32_t a,unsigned t,int32_t v){
 uint8_t x[4];unsigned n=es(t);for(unsigned i=0;i<n;i++)x[i]=(uint32_t)v>>(8*i);
 return b->write(b->ctx,a,x,n) ? AI_IO:AI_OK;
}
/* Reuses the accepted magnitude/two-word multiplication method, generalized
   to descriptor bounds including wide INT32 and head INT16. */
static int32_t scaled(int32_t a,uint32_t m,int32_t low,int32_t high){
 uint32_t x=a<0 ? 0u-(uint32_t)a:(uint32_t)a,lo=0,hi=0,xhi=0;
 while(m){if(m&1u){uint32_t old=lo;lo+=x;hi+=xhi+(lo<old);}xhi=(xhi<<1)|(x>>31);x<<=1;m>>=1;}
 uint32_t upper=hi>>24,q=(hi<<8)|(lo>>24),r=lo&0xffffffu;
 if(r>0x800000u||(r==0x800000u&&(q&1u))){q++;if(!q)upper++;}
 if(upper||q>0x80000000u||(a>=0&&q==0x80000000u))return a<0 ? low:high;
 int32_t y=(int32_t)(a<0 ? 0u-q:q);return y<low ? low:y>high ? high:y;
}
static int validate(const uint32_t *d,const ai_backend *b){
 if(!d||!b||!b->probe||!b->read||!b->write||!b->mac)return AI_DESCRIPTOR;
 unsigned op=d[0],flags=d[1],nin=d[2],ot=d[17],it=d[13];
 if(d[39]!=0x10000||d[38]||op<1||op>6||(flags&~31u)||!nin||nin>4||!es(ot)||!es(it))return AI_DESCRIPTOR;
 for(unsigned i=18;i<=24;i++)if(!d[i]||d[i]>65535u)return AI_DESCRIPTOR;
 uint32_t n=d[18],ci=d[19],h=d[20],w=d[21],co=d[22],ho=d[23],wo=d[24],size;
 if(bytes4(n,co,ho,wo,es(ot),&size)||size!=d[4])return AI_DESCRIPTOR;
 if(bytes4(n,ci,h,w,es(it),&size)||size!=d[9])return AI_DESCRIPTOR;
 int32_t low=(int32_t)d[31],high=(int32_t)d[32],iz=(int32_t)d[29],oz=(int32_t)d[30];
 if(op!=4&&low>high)return AI_DESCRIPTOR;
 if(op!=4&&nin!=(op==3?2u:1u))return AI_DESCRIPTOR;
 if(op!=1&&(flags&25u))return AI_DESCRIPTOR;
 if(op==1){
  unsigned kh=d[34]&255,kw=(d[34]>>8)&255,sh=(d[34]>>16)&255,sw=d[34]>>24;
  unsigned ph=d[35]&255,pw=(d[35]>>8)&255,dh=(d[35]>>16)&255,dw=d[35]>>24,g=d[36];
  if((flags&2u)||!kh||!kw||!sh||!sw||!dh||!dw||!g||ci%g||co%g||(it!=1&&it!=2)||((flags>>3)&1u)!=(it==1)||iz<-128||iz>127||(it==1&&iz))return AI_DESCRIPTOR;
  unsigned eh=dh*(kh-1)+1,ew=dw*(kw-1)+1;
  if(h+2*ph<eh||w+2*pw<ew||(h+2*ph-eh)/sh+1!=ho||(w+2*pw-ew)/sw+1!=wo)return AI_DESCRIPTOR;
  if(flags&1u){if(ot!=2||(flags&16u)||low!=-2048||high!=2047||d[33]!=2048)return AI_DESCRIPTOR;}
  else if(ot!=3||!(flags&16u)||low<-32768||high>32767||d[28]||d[33])return AI_DESCRIPTOR;
  uint32_t count;if(product(co,ci/g,&count)||product(count,kh,&count)||product(count,kw,&count))return AI_DESCRIPTOR;
  uint32_t count4;if(product(co,4,&count4))return AI_DESCRIPTOR;
  uint32_t lengths[4]={count,count4,count4,(flags&1u)?4096u:0u};
  for(unsigned i=0;i<4;i++)if(lengths[i]&&(range(b,d[25+i],lengths[i],0)||overlap(d[3],d[4],d[25+i],lengths[i])))return AI_ADDRESS;
  for(unsigned c=0;c<co;c++){int32_t mult;if(get(b,d[27]+4*c,4,&mult))return AI_IO;if(mult<0)return AI_NUMERIC;}
 }else if(op==2){
  if(it!=2||co!=ci||h!=ho||w!=wo||iz<-128||iz>127||oz<-128||oz>127)return AI_DESCRIPTOR;
  if(flags&2u){if(ot!=4||low!=-(1<<30)||high!=(1<<30)-1)return AI_DESCRIPTOR;}
  else if(ot!=2||low!=((flags&4u)?-128:-127)||high!=127)return AI_DESCRIPTOR;
  if(range(b,d[27],4,0)||overlap(d[3],d[4],d[27],4))return AI_ADDRESS;
  int32_t mult;if(get(b,d[27],4,&mult))return AI_IO;if(mult<0)return AI_NUMERIC;
 }else if(op==3){
  if((flags&2u)||it!=4||d[14]!=4||d[9]!=d[10]||ot!=2||co!=ci||ho!=h||wo!=w||oz<-128||oz>127||low!=((flags&4u)?-128:-127)||high!=127)return AI_DESCRIPTOR;
 }else if(op==4){
  if(flags||ot!=2||it!=2||h!=ho||w!=wo)return AI_DESCRIPTOR;
  uint32_t unit;if(bytes4(n,1,h,w,1,&unit))return AI_DESCRIPTOR;unsigned total=0;
  for(unsigned i=0;i<nin;i++){if(d[13+i]!=2||!d[9+i]||d[9+i]%unit)return AI_DESCRIPTOR;unsigned c=d[9+i]/unit;if(c>co-total)return AI_DESCRIPTOR;total+=c;}
  if(total!=co)return AI_DESCRIPTOR;
 }else if(op==5){
  if(flags||it!=2||ot!=2||co!=ci||ho!=h||wo!=w||!d[37]||d[37]>255||!(d[37]&1u))return AI_DESCRIPTOR;
 }else{
  uint32_t hh,ww;if(flags||it!=2||ot!=2||co!=ci||!d[37]||product(h,d[37],&hh)||product(w,d[37],&ww)||hh!=ho||ww!=wo)return AI_DESCRIPTOR;
 }
 if(range(b,d[3],d[4],1))return AI_ADDRESS;
 for(unsigned i=0;i<nin;i++){
  if(!es(d[13+i]))return AI_DESCRIPTOR;
  if(range(b,d[5+i],d[9+i],0)||overlap(d[3],d[4],d[5+i],d[9+i]))return AI_ADDRESS;
 }
 for(unsigned i=nin;i<4;i++)if(d[5+i]||d[9+i]||d[13+i])return AI_DESCRIPTOR;
 return AI_OK;
}
/* Two adjacent output pixels share their input patches across output channels.
   Flatten each complete input dot once, preserving IC/KY/KX and MAC lane order.
   At most2304 input bytes plus1152 weight bytes; no persistent RAM increase.
   Stable backend data is required, as for the existing pointwise prefetch path.
   IO may be prefetched and completed output writes batched; any error stops
   immediately and no incomplete dot is published as a valid output value. */
static int conv_small_channel(const uint32_t d[40],const ai_backend *b){
 uint8_t tile[2][1152],weights[1152];
 const unsigned n=d[18],ci=d[19],h=d[20],w=d[21],co=d[22],ho=d[23],wo=d[24];
 const unsigned kh=d[34]&255,kw=(d[34]>>8)&255,sh=(d[34]>>16)&255,sw=d[34]>>24;
 const unsigned ph=d[35]&255,pw=(d[35]>>8)&255,dh=(d[35]>>16)&255,dw=d[35]>>24;
 const unsigned cg=ci/d[36],og=co/d[36],total=cg*kh*kw,plane=h*w,frame=ci*plane;
 const unsigned row_step=dh*w,oe=es(d[17]),uns=d[13]==1,out_plane=ho*wo*oe;
 const int32_t iz=(int32_t)d[29],low=(int32_t)d[31],high=(int32_t)d[32];
 uint32_t batch=d[5],output_batch=d[3];
 for(unsigned bn=0;bn<n;bn++,batch+=frame,output_batch+=co*out_plane){
  uint32_t group_base=batch,output_group=output_batch,weight_group=d[25],bias_group=d[26],mult_group=d[27];
  for(unsigned group=0;group<d[36];group++,group_base+=cg*plane,output_group+=og*out_plane,
      weight_group+=og*total,bias_group+=og*4,mult_group+=og*4){
   int32_t y0=-(int32_t)ph;
   uint32_t output_row=output_group;
   for(unsigned oy=0;oy<ho;oy++,y0+=(int32_t)sh,output_row+=wo*oe){
    uint32_t row_top=(uint32_t)y0*w;
    int32_t x0=-(int32_t)pw;
    for(unsigned ox=0;ox<wo;ox+=2,x0+=(int32_t)(2*sw)){
     unsigned take=wo-ox;if(take>2)take=2;
     for(unsigned pixel=0;pixel<take;pixel++){
      unsigned index=0;uint32_t input_plane=group_base;
      int32_t origin_x=x0+(int32_t)(pixel*sw);
      for(unsigned channel=0;channel<cg;channel++,input_plane+=plane){
       int32_t iy=y0;uint32_t row=input_plane+row_top+(uint32_t)origin_x;
       for(unsigned ky=0;ky<kh;ky++,iy+=(int32_t)dh,row+=row_step){
        int32_t ix=origin_x;uint32_t address=row;unsigned kx=0,valid_y=iy>=0&&(unsigned)iy<h;
        while(kx<kw){
         unsigned run=kw-kx;
         if(valid_y && ix>=0 && (unsigned)ix<w){
          if(dw==1){unsigned remaining=w-(unsigned)ix;if(run>remaining)run=remaining;}
          else run=1;
          if(b->read(b->ctx,address,tile[pixel]+index,run))return AI_IO;
         }else{
          if(valid_y && ix<0)run=1;
          for(unsigned k=0;k<run;k++)tile[pixel][index+k]=(uint8_t)iz;
         }
         kx+=run;index+=run;ix+=(int32_t)(run*dw);address+=run*dw;
        }
       }
      }
      for(unsigned k=total;k<((total+7u)&~7u);k++)tile[pixel][k]=0;
     }
     uint32_t channel_weights=weight_group,bias_address=bias_group,mult_address=mult_group;
     uint32_t output=output_row+ox*oe;
     for(unsigned oc=0;oc<og;oc++,channel_weights+=total,bias_address+=4,mult_address+=4,output+=out_plane){
      int32_t bias,mult;
      if(get(b,bias_address,4,&bias)||get(b,mult_address,4,&mult))return AI_IO;
      if(b->read(b->ctx,channel_weights,weights,total))return AI_IO;
      for(unsigned k=total;k<((total+7u)&~7u);k++)weights[k]=0;
      uint8_t values[4];
      for(unsigned pixel=0;pixel<take;pixel++){
       int32_t acc=0;unsigned at=0;const uint8_t *input=tile[pixel];
       for(;at+8<=total;at+=8)
        if(b->mac(b->ctx,input+at,weights+at,255u,at==0,at+8==total,bias,uns,iz,&acc))return AI_MAC;
       if(at<total)
        if(b->mac(b->ctx,input+at,weights+at,(1u<<(total-at))-1u,at==0,1,bias,uns,iz,&acc))return AI_MAC;
       int32_t value=scaled(acc,(uint32_t)mult,low,high);
       if(d[1]&1u){if(get(b,d[28]+(uint32_t)(value+(int32_t)d[33]),2,&value))return AI_IO;}
       values[pixel*oe]=(uint8_t)value;
       if(oe==2)values[pixel*oe+1]=(uint8_t)((uint32_t)value>>8);
      }
      if(b->write(b->ctx,output,values,take*oe))return AI_IO;
     }
    }
   }
  }
 }
 return AI_OK;
}

/* Reuse one stable input tile across output channels. A complete original
   IC-ordered MAC8 dot product is finished before the next pixel starts.
   Output callbacks batch only already completed values from one output row.
   Preflight establishes disjoint output and every input/weight/table range;
   failure remains fail-stop, with a possibly reordered valid output subset. */
static int conv_pointwise8(const uint32_t d[40],const ai_backend *b){
 uint8_t tile[512*8],weights[520];
 const unsigned n=d[18],ci=d[19],h=d[20],w=d[21],co=d[22],groups=d[36];
 const unsigned cg=ci/groups,og=co/groups,plane=h*w,frame=ci*plane;
 const unsigned oe=es(d[17]),uns=d[13]==1,output_plane=plane*oe;
 const int32_t iz=(int32_t)d[29],low=(int32_t)d[31],high=(int32_t)d[32];
 uint32_t batch=d[5],output_batch=d[3];
 for(unsigned bn=0;bn<n;bn++,batch+=frame,output_batch+=co*output_plane){
  uint32_t group_base=batch,output_group=output_batch,weight_group=d[25],bias_group=d[26],mult_group=d[27];
  for(unsigned group=0;group<groups;group++,group_base+=cg*plane,output_group+=og*output_plane,
      weight_group+=og*cg,bias_group+=og*4,mult_group+=og*4){
   uint32_t row=group_base,output_row=output_group;
   for(unsigned oy=0;oy<h;oy++,row+=w,output_row+=w*oe)for(unsigned ox=0;ox<w;ox+=8){
    unsigned take=w-ox;if(take>8)take=8;
    uint32_t input_plane=row+ox;
    for(unsigned c=0;c<cg;c++,input_plane+=plane)
     if(b->read(b->ctx,input_plane,tile+c*8,take))return AI_IO;
    uint32_t channel_weights=weight_group,bias_address=bias_group,mult_address=mult_group;
    uint32_t output=output_row+ox*oe;
    for(unsigned oc=0;oc<og;oc++,channel_weights+=cg,bias_address+=4,mult_address+=4,output+=output_plane){
     int32_t bias,mult;
     if(get(b,bias_address,4,&bias)||get(b,mult_address,4,&mult))return AI_IO;
     if(b->read(b->ctx,channel_weights,weights,cg))return AI_IO;
     for(unsigned k=cg;k<((cg+7u)&~7u);k++)weights[k]=0;
     uint8_t values[16];
     for(unsigned pixel=0;pixel<take;pixel++){
      uint8_t xs[8]={0};int32_t acc=0;unsigned c=0;
      for(;c+8<=cg;c+=8){
       const uint8_t *t=tile+c*8+pixel;
       xs[0]=t[0];xs[1]=t[8];xs[2]=t[16];xs[3]=t[24];
       xs[4]=t[32];xs[5]=t[40];xs[6]=t[48];xs[7]=t[56];
       if(b->mac(b->ctx,xs,weights+c,255u,c==0,c+8==cg,bias,uns,iz,&acc))return AI_MAC;
      }
      if(c<cg){
       const uint8_t *t=tile+c*8+pixel;
       unsigned lanes=cg-c;
       for(unsigned k=0;k<lanes;k++)xs[k]=t[k*8];
       if(b->mac(b->ctx,xs,weights+c,(1u<<lanes)-1,c==0,1,bias,uns,iz,&acc))return AI_MAC;
      }
      int32_t value=scaled(acc,(uint32_t)mult,low,high);
      if(d[1]&1u){if(get(b,d[28]+(uint32_t)(value+(int32_t)d[33]),2,&value))return AI_IO;}
      values[pixel*oe]=(uint8_t)value;
      if(oe==2)values[pixel*oe+1]=(uint8_t)((uint32_t)value>>8);
     }
     if(b->write(b->ctx,output,values,take*oe))return AI_IO;
    }
   }
  }
 }
 return AI_OK;
}

int ai_execute(const uint32_t d[40],const ai_backend *b){
 int status=validate(d,b);if(status)return status;
 unsigned op=d[0],n=d[18],ci=d[19],h=d[20],w=d[21],co=d[22],ho=d[23],wo=d[24],ie=es(d[13]),oe=es(d[17]);
 int32_t low=(int32_t)d[31],high=(int32_t)d[32],iz=(int32_t)d[29],oz=(int32_t)d[30],v=0;
 if(op==1){
  unsigned kh=d[34]&255,kw=(d[34]>>8)&255,sh=(d[34]>>16)&255,sw=d[34]>>24;
  unsigned ph=d[35]&255,pw=(d[35]>>8)&255,dh=(d[35]>>16)&255,dw=d[35]>>24,g=d[36],cg=ci/g,og=co/g;
  if(d[34]==0x01010101u && d[35]==0x01010000u && cg<=512u)return conv_pointwise8(d,b);
  if(cg*kh*kw<=1152u)return conv_small_channel(d,b);
  for(unsigned bn=0;bn<n;bn++)for(unsigned oc=0;oc<co;oc++){
   int32_t bias,mult;if(get(b,d[26]+4*oc,4,&bias)||get(b,d[27]+4*oc,4,&mult))return AI_IO;
   for(unsigned oy=0;oy<ho;oy++)for(unsigned ox=0;ox<wo;ox++){
    uint8_t xs[8]={0},ws[8]={0};unsigned lane=0,done=0,total=cg*kh*kw;int32_t acc=0;
    for(unsigned c=0;c<cg;c++)for(unsigned ky=0;ky<kh;ky++)for(unsigned kx=0;kx<kw;kx++){
     int32_t iy=(int32_t)(oy*sh+ky*dh)-(int32_t)ph,ix=(int32_t)(ox*sw+kx*dw)-(int32_t)pw,q=iz,weight;
     if(iy>=0&&ix>=0&&(unsigned)iy<h&&(unsigned)ix<w){unsigned pos=((bn*ci+(oc/og)*cg+c)*h+(unsigned)iy)*w+(unsigned)ix;if(get(b,d[5]+pos*ie,d[13],&q))return AI_IO;}
     if(get(b,d[25]+((oc*cg+c)*kh+ky)*kw+kx,2,&weight))return AI_IO;
     xs[lane]=(uint8_t)q;ws[lane]=(uint8_t)weight;lane++;done++;
     if(lane==8||done==total){if(b->mac(b->ctx,xs,ws,(1u<<lane)-1,done==lane,done==total,bias,d[13]==1,iz,&acc))return AI_MAC;lane=0;}
    }
    v=scaled(acc,(uint32_t)mult,low,high);
    if(d[1]&1u){if(get(b,d[28]+(uint32_t)(v+(int32_t)d[33]),2,&v))return AI_IO;}
    if(put(b,d[3]+(((bn*co+oc)*ho+oy)*wo+ox)*oe,d[17],v))return AI_IO;
   }
  }
 }else if(op==2){
  int32_t mult;if(get(b,d[27],4,&mult))return AI_IO;
  for(unsigned i=0;i<d[9]/ie;i++){
   if(get(b,d[5]+i*ie,d[13],&v))return AI_IO;
#ifdef MUTANT
   /* Wrong clamp-before-zero limits: deliberately detected by affine fixture. */
   v=scaled(v-iz,(uint32_t)mult,low,high);
#else
   v=scaled(v-iz,(uint32_t)mult,(d[1]&2u)?low:low-oz,(d[1]&2u)?high:high-oz);
#endif
   if(!(d[1]&2u))v+=oz;
   if(put(b,d[3]+i*oe,d[17],v))return AI_IO;
  }
 }else if(op==3){
  for(unsigned i=0;i<d[4];i++){
   int32_t x,y;if(get(b,d[5]+4*i,4,&x)||get(b,d[6]+4*i,4,&y))return AI_IO;
   int64_t sum=(int64_t)x+(int64_t)y+oz;v=sum<low ? low:sum>high ? high:(int32_t)sum;
   if(put(b,d[3]+i,2,v))return AI_IO;
  }
 }else if(op==4){
  unsigned dest=0;
  for(unsigned bn=0;bn<n;bn++)for(unsigned j=0;j<d[2];j++){
   unsigned chunk=d[9+j]/n;
   for(unsigned i=0;i<chunk;i++){if(get(b,d[5+j]+bn*chunk+i,2,&v)||put(b,d[3]+dest++,2,v))return AI_IO;}
  }
 }else if(op==5){
  unsigned k=d[37];
  for(unsigned bn=0;bn<n;bn++)for(unsigned c=0;c<ci;c++)for(unsigned oy=0;oy<h;oy++)for(unsigned ox=0;ox<w;ox++){
   int32_t best=-128;
   for(unsigned ky=0;ky<k;ky++)for(unsigned kx=0;kx<k;kx++){
    int32_t iy=(int32_t)(oy+ky)-(int32_t)(k/2),ix=(int32_t)(ox+kx)-(int32_t)(k/2);
    if(iy>=0&&ix>=0&&(unsigned)iy<h&&(unsigned)ix<w){if(get(b,d[5]+((bn*ci+c)*h+(unsigned)iy)*w+(unsigned)ix,2,&v))return AI_IO;if(v>best)best=v;}
   }
   if(put(b,d[3]+((bn*ci+c)*h+oy)*w+ox,2,best))return AI_IO;
  }
 }else{
  unsigned factor=d[37];
  for(unsigned bn=0;bn<n;bn++)for(unsigned c=0;c<ci;c++)for(unsigned oy=0;oy<ho;oy++)for(unsigned ox=0;ox<wo;ox++){
   if(get(b,d[5]+((bn*ci+c)*h+oy/factor)*w+ox/factor,2,&v)||put(b,d[3]+((bn*ci+c)*ho+oy)*wo+ox,2,v))return AI_IO;
  }
 }
 return AI_OK;
}
