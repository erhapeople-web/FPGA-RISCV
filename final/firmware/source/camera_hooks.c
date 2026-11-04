/* Single real camera frame -> DDR input -> original graph/PP -> hardware OSD.
 * The original target objects supply the production protocol and application.
 * These wrappers add capture, progress, coherent read caching and result OSD;
 * no host-computed detections, fixture tensors or reference boxes are used.
 */
#include <stdint.h>
#include "camera_hooks.h"
#define VIDEO ((volatile uint32_t *)0x20007000u)
#define STATS ((volatile uint32_t *)0x20004000u)
#define GPIO (*(volatile uint32_t *)0x20001000u)
#ifdef CAMERA_HOOKS_TEST
extern uint32_t camera_test_video_read(unsigned);
extern void camera_test_video_write(unsigned,uint32_t);
extern uint32_t camera_test_stats_read(unsigned);
extern void camera_test_gpio_write(uint32_t);
#define VIDEO_READ(i) camera_test_video_read(i)
#define VIDEO_WRITE(i,v) camera_test_video_write(i,v)
#define STATS_READ(i) camera_test_stats_read(i)
#define GPIO_WRITE(v) camera_test_gpio_write(v)
#else
#define VIDEO_READ(i) VIDEO[i]
#define VIDEO_WRITE(i,v) (VIDEO[i]=(v))
#define STATS_READ(i) STATS[i]
#define GPIO_WRITE(v) (GPIO=(v))
#endif
#define DDR_LOW 16777216u
#define DDR_HIGH 19353760u
#define INPUT_BASE 18969760u
#define PLANE 25600u
#define CACHE_LINES 512u
#define CACHE_BYTES 8u
#define CACHE_SHIFT 3u

#define CAM_ASSERT(name,expr) typedef char cam_assert_##name[(expr)?1:-1]
CAM_ASSERT(input_base,INPUT_BASE==CAM_INPUT_BASE);
CAM_ASSERT(plane,PLANE==CAM_INPUT_PLANE);
CAM_ASSERT(ddr_low,DDR_LOW==CAM_DDR_LOW);
CAM_ASSERT(ddr_high,DDR_HIGH==CAM_DDR_HIGH);
CAM_ASSERT(crop_inside,CAM_CROP_X+CAM_INPUT_W<=CAM_SNAPSHOT_W && CAM_CROP_Y+CAM_INPUT_H<=CAM_SNAPSHOT_H);
typedef int (*observer_fn)(void *,uint32_t,const uint32_t[40]);

static uint8_t cached[CACHE_LINES][CACHE_BYTES],valid[CACHE_LINES];
static uint32_t tags[CACHE_LINES];
static unsigned cache_enabled;
static unsigned cache_fault;
static uint32_t read_calls,read_hits,read_misses;
static uint32_t camera_seq,camera_ok,osd_count;
static unsigned graph_completed,results_reported;
static uint8_t incoming[276];
static unsigned incoming_count,incoming_total;
static uint8_t row_rgb[3][160];

static uint32_t get32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put32(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static uint64_t cycles(void){uint32_t hi,lo,again;do{hi=STATS_READ(1);lo=STATS_READ(0);again=STATS_READ(1);}while(hi!=again);return ((uint64_t)hi<<32)|lo;}
static unsigned line_index(uint32_t base){uint32_t n=base>>CACHE_SHIFT;return (n^(n>>6)^(n>>12))&(CACHE_LINES-1);}

/* Keep generic/miss state out of the byte-hit entry's register allocation.
   This is also required on native validation builds, so both compilers test
   the same function boundary. */
#if defined(__GNUC__)
#define CAMERA_NOINLINE __attribute__((noinline))
#elif defined(_MSC_VER)
#define CAMERA_NOINLINE __declspec(noinline)
#else
#define CAMERA_NOINLINE
#endif
static CAMERA_NOINLINE int platform_read_slow(void *ctx,uint32_t off,uint8_t *out,uint32_t n){
 if(cache_fault)return 1;
 if(!cache_enabled || n>=CACHE_BYTES || off<DDR_LOW || off>DDR_HIGH || n>DDR_HIGH-off){
  int result=__real_platform_read(ctx,off,out,n);if(result)cache_fault=1;return result;
 }
 read_calls++;
 while(n){
  uint32_t base=off&~(CACHE_BYTES-1u);unsigned slot=line_index(base),lane=off&(CACHE_BYTES-1u),take=CACHE_BYTES-lane;
  if(take>n)take=n;
  if(!valid[slot] || tags[slot]!=base){
   unsigned fill=DDR_HIGH-base;if(fill>CACHE_BYTES)fill=CACHE_BYTES;
   if(__real_platform_read(ctx,base,cached[slot],fill)){cache_fault=1;return 1;}
   valid[slot]=1;tags[slot]=base;read_misses++;
  }else read_hits++;
  for(unsigned k=0;k<take;k++)out[k]=cached[slot][lane+k];
  off+=take;out+=take;n-=take;
 }
 return 0;
}
/* Only the two/three-byte dispatcher enters here. Cross-line reads retain
   the generic path, including partial-copy and second-fill failure behavior. */
static CAMERA_NOINLINE int platform_read_short(void *ctx,uint32_t off,uint8_t *out,uint32_t n){
 unsigned lane=off&(CACHE_BYTES-1u);
 if(!cache_fault && cache_enabled && off>=DDR_LOW && off<=DDR_HIGH-n && lane+n<=CACHE_BYTES){
  uint32_t base=off&~(CACHE_BYTES-1u);unsigned slot=line_index(base);
  if(valid[slot] && tags[slot]==base){
   const uint8_t *p=cached[slot]+lane;
   read_calls++;read_hits++;out[0]=p[0];out[1]=p[1];if(n==3)out[2]=p[2];return 0;
  }
 }
 return platform_read_slow(ctx,off,out,n);
}
static CAMERA_NOINLINE int platform_read_fallback(void *ctx,uint32_t off,uint8_t *out,uint32_t n){
 if(n==2 || n==3)return platform_read_short(ctx,off,out,n);
 return platform_read_slow(ctx,off,out,n);
}
int __wrap_platform_read(void *ctx,uint32_t off,uint8_t *out,uint32_t n){
 if(n==1 && !cache_fault && cache_enabled && off>=DDR_LOW && off<DDR_HIGH){
  uint32_t base=off&~(CACHE_BYTES-1u);unsigned slot=line_index(base);
  if(valid[slot] && tags[slot]==base){
   read_calls++;read_hits++;*out=cached[slot][off&(CACHE_BYTES-1u)];return 0;
  }
 }
 /* The slow path owns its original counters and sticky failure handling.
    In particular a miss must not count the read twice. */
 return platform_read_fallback(ctx,off,out,n);
}
int __wrap_platform_write(void *ctx,uint32_t off,const uint8_t *in,uint32_t n){
 if(cache_fault)return 1;
 if(__real_platform_write(ctx,off,in,n)){cache_fault=1;return 1;}
 if(!cache_enabled)return 0;
 while(n){
  uint32_t base=off&~(CACHE_BYTES-1u);unsigned slot=line_index(base),lane=off&(CACHE_BYTES-1u),take=CACHE_BYTES-lane;
  if(take>n)take=n;
  if(valid[slot] && tags[slot]==base)for(unsigned k=0;k<take;k++)cached[slot][lane+k]=in[k];
  off+=take;in+=take;n-=take;
 }
 return 0;
}
static int frame(unsigned cmd,unsigned seq,uint32_t index,const uint8_t *payload,unsigned n){
 uint8_t bytes[276];if(n>256)return 1;
 for(unsigned i=0;i<16;i++)bytes[i]=0;
 bytes[0]='A';bytes[1]='I';bytes[2]='P';bytes[3]='1';bytes[4]=(uint8_t)cmd;
 bytes[6]=(uint8_t)seq;bytes[7]=(uint8_t)(seq>>8);put32(bytes+8,index);
 bytes[12]=(uint8_t)n;bytes[13]=(uint8_t)(n>>8);
 for(unsigned i=0;i<n;i++)bytes[16+i]=payload[i];
 put32(bytes+16+n,ul_crc32(bytes,16+n));
 return __real_platform_send(0,bytes,20+n);
}
static int progress(unsigned phase,unsigned node){
 uint8_t p[32];uint64_t c=cycles();
 put32(p,phase);put32(p+4,node);put32(p+8,camera_seq);
 put32(p+12,(uint32_t)c);put32(p+16,(uint32_t)(c>>32));
 put32(p+20,read_calls);put32(p+24,read_hits);put32(p+28,read_misses);
 return frame(0xb0,0,node,p,32);
}
static int pixel(unsigned index,uint16_t *out){
 if(index>=57600 || !(VIDEO_READ(0x48/4)&2u))return 1;
 VIDEO_WRITE(0x50/4,index);
 unsigned budget=100000;uint32_t s;
 do{s=VIDEO_READ(0x48/4);if((s&4u)||!(s&2u)||!budget--)return 1;}while(!(s&8u));
 *out=(uint16_t)VIDEO_READ(0x54/4);return 0;
}
static int capture_input(void){
 camera_ok=0;cache_enabled=0;graph_completed=results_reported=0;
 if(VIDEO_READ(0x40/4)!=0x43500001u || VIDEO_READ(0x80/4)!=0x4f530001u)return 1;
 if(progress(CAM_PHASE_CAPTURE,0))return 1;
 VIDEO_WRITE(0x44/4,2);
 uint32_t begin=(uint32_t)cycles();
 while(VIDEO_READ(0x48/4)&1u)if((uint32_t)cycles()-begin>100000000u)return 1;
 VIDEO_WRITE(0x44/4,1);begin=(uint32_t)cycles();
 while(!(VIDEO_READ(0x48/4)&2u)){
  if((VIDEO_READ(0x48/4)&4u)||(uint32_t)cycles()-begin>100000000u)return 1;
 }
 camera_seq=VIDEO_READ(0x4c/4);if(!camera_seq)return 1;
 if(progress(CAM_PHASE_PREPROCESS,0))return 1;
 /* Version 0x10002: the central 160x160 of the locked 320x180 snapshot.
    No resize or padding; expand RGB565 with left shifts into NCHW uint8.
    The complete snapshot remains available for independent input checking. */
 for(unsigned y=0;y<160;y++){
  for(unsigned x=0;x<160;x++){
   uint16_t p;if(pixel((y+10)*320+x+80,&p))return 1;
   row_rgb[0][x]=(uint8_t)(((p>>11)&31u)<<3);
   row_rgb[1][x]=(uint8_t)(((p>>5)&63u)<<2);
   row_rgb[2][x]=(uint8_t)((p&31u)<<3);
  }
  for(unsigned c=0;c<3;c++)if(__real_platform_write(0,INPUT_BASE+c*PLANE+y*160,row_rgb[c],160))return 1;
 }
 camera_ok=1;return progress(CAM_PHASE_INPUT_READY,0);
}
int camera_prepare_input(void *ctx){
 (void)ctx;
 if(capture_input()){GPIO_WRITE(0xe4);return 1;}
 return 0;
}
/* Clip to the actual central input ROI, including its final display pixel.
   Bound signed Q8 before the unsigned shift; INT32_MIN/MAX cannot overflow. */
static unsigned screen_coord(int32_t q,unsigned origin){
 if(q<=0)return origin;
 if(q>=160*256)return origin+639;
 return origin+((unsigned)q>>6);
}
static unsigned screen_x(int32_t q){return screen_coord(q,320);}
static unsigned screen_y(int32_t q){return screen_coord(q,40);}
static int wait_osd(void){uint32_t begin=(uint32_t)cycles();while(VIDEO_READ(0x98/4)&1u)if((uint32_t)cycles()-begin>100000000u)return 1;return 0;}
int __wrap_platform_send(void *ctx,const uint8_t *p,uint32_t n){
 if(camera_ok && n>=20 && p[0]=='A' && p[1]=='I' && p[2]=='P' && p[3]=='1'){
  unsigned len=(unsigned)p[12]|(unsigned)p[13]<<8;
  if(n!=20+len)return 1;
  /* A failed RUN ACK must never claim that postprocessing succeeded.
     Reset both markers for each capture/graph, including repeated runs. */
  if(graph_completed && !results_reported &&
     ((p[4]==0x85 && len==12 && get32(p+16)==0) ||
      (p[4]==0x90 && len && len%24==0) || (p[4]==0x91 && len==40))){
   if(progress(CAM_PHASE_RESULT_READY,CAM_LAST_NODE))return 1;
   results_reported=1;
  }
  if(p[4]==0x85 && len==12 && get32(p+16)==0)osd_count=0;
  if(p[4]==0x90){
   if(len%24 || wait_osd())return 1;
   for(unsigned at=0;at<len && osd_count<16;at+=24){
    const uint8_t *b=p+16+at;unsigned x1=screen_x((int32_t)get32(b)),y1=screen_y((int32_t)get32(b+4));
    unsigned x2=screen_x((int32_t)get32(b+8)),y2=screen_y((int32_t)get32(b+12));
    if(x2<x1 || y2<y1)return 1;
    VIDEO_WRITE(0x84/4,osd_count);VIDEO_WRITE(0x88/4,x1|(y1<<16));VIDEO_WRITE(0x8c/4,x2|(y2<<16));
    VIDEO_WRITE(0x90/4,(get32(b+16)&65535u)|(get32(b+20)<<16));osd_count++;
   }
  }
  if(p[4]==0x91){
   if(len!=40 || wait_osd())return 1;
   VIDEO_WRITE(0x94/4,osd_count);
   if(graph_completed && progress(CAM_PHASE_OSD_SUBMITTED,CAM_LAST_NODE))return 1;
   if(wait_osd())return 1;
   cache_enabled=0;if(progress(CAM_PHASE_OSD_DONE,CAM_LAST_NODE))return 1;
  }
 }
 return __real_platform_send(ctx,p,n);
}
static observer_fn previous_observer;static void *previous_observer_context;
static int node_done(void *ctx,uint32_t index,const uint32_t descriptor[40]){
 (void)ctx;
 if(previous_observer && previous_observer(previous_observer_context,index,descriptor))return 1;
 return progress(CAM_PHASE_NODE,index+1);
}
int __wrap_ai_graph_run(void *state,const void *backend,uint32_t ops,uint32_t count,observer_fn observer,void *ctx){
 graph_completed=results_reported=0;
 previous_observer=observer;previous_observer_context=ctx;
 for(unsigned i=0;i<CACHE_LINES;i++)valid[i]=0;
 read_calls=read_hits=read_misses=0;cache_enabled=1;
 int rc=__real_ai_graph_run(state,backend,ops,count,node_done,0);
 if(!rc && count==CAM_LAST_NODE){
  if(progress(CAM_PHASE_GRAPH_DONE,CAM_LAST_NODE))return 1;
  graph_completed=1;
 }
 return rc;
}
static int custom_command(unsigned cmd,unsigned seq,uint32_t index,const uint8_t *p,unsigned n){
 if(cmd==0x21){
  if(n!=4 || !camera_ok || index&1u)return 1;
  unsigned count=get32(p);if(!count || count>240 || count&1u || index>115200 || count>115200-index)return 1;
  uint8_t out[240];
  for(unsigned k=0;k<count;k+=2){uint16_t value;if(pixel((index+k)/2,&value))return 1;out[k]=(uint8_t)value;out[k+1]=(uint8_t)(value>>8);}
  return frame(0xa1,seq,index,out,count);
 }
 if(cmd==0x22){
  if(n)return 1;
  uint8_t out[32];put32(out,camera_seq);put32(out+4,VIDEO_READ(0x48/4));put32(out+8,0x00010002u);
  put32(out+12,VIDEO_READ(0x9c/4));put32(out+16,osd_count);put32(out+20,read_calls);put32(out+24,read_hits);put32(out+28,read_misses);
  return frame(0xa2,seq,0,out,32);
 }
 return 1;
}
void __wrap_ul_feed(void *loader,uint8_t byte){
 const uint8_t magic[4]={'A','I','P','1'};
 if(incoming_count<4 && byte!=magic[incoming_count]){
  /* Preserve production parser behavior on malformed prefixes. */
  for(unsigned i=0;i<incoming_count;i++)__real_ul_feed(loader,incoming[i]);
  __real_ul_feed(loader,byte);incoming_count=0;incoming_total=0;return;
 }
 incoming[incoming_count++]=byte;
 if(incoming_count==16){
  unsigned len=(unsigned)incoming[12]|(unsigned)incoming[13]<<8;
  if(len>256){for(unsigned i=0;i<16;i++)__real_ul_feed(loader,incoming[i]);incoming_count=incoming_total=0;return;}
  incoming_total=20+len;
 }
 if(!incoming_total || incoming_count<incoming_total)return;
 unsigned n=incoming_total;incoming_count=incoming_total=0;
 unsigned len=n-20,cmd=incoming[4],seq=(unsigned)incoming[6]|(unsigned)incoming[7]<<8;
 int crc_ok=get32(incoming+n-4)==ul_crc32(incoming,n-4);
 if(crc_ok && (cmd==0x21 || cmd==0x22)){
  /* Custom commands use the same reserved-header rules as production.
     Reject malformed headers before custom_command can touch video MMIO. */
  if(incoming[5]!=0 || incoming[14]!=0 || incoming[15]!=0 ||
     (cmd==0x22 && get32(incoming+8)!=0) ||
     custom_command(cmd,seq,get32(incoming+8),incoming+16,len)){
   uint8_t e[4];put32(e,0xc1);frame(0xb2,seq,cmd,e,4);
  }
  return;
 }
 /* The production loader owns RUN admission. Its application callback now
    acquires the frame only after validity/fail-stop/upload-state checks. */
 for(unsigned i=0;i<n;i++)__real_ul_feed(loader,incoming[i]);
}
/* The frozen loader's ul_timeout and ul_parser_reset both immediately clear
   its parser count (one SW at offset 464); no delayed timeout counter exists.
   Drop the wrapper's pending frame at that same boundary. */
void __wrap_ul_timeout(void *loader){
 incoming_count=incoming_total=0;
 __real_ul_timeout(loader);
}
