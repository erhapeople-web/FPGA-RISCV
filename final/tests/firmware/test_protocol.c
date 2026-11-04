/* Actual hooks + application + loader; deterministic fake MMIO/DDR/graph/PP.
   Verifies admission, real capture preprocessing, phase order and input SHA.
   Full numerical graph regression is a separate test. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CAMERA_HOOKS_TEST 1
#include "camera_hooks.c"
#include "app.h"
static uint8_t memory[CAM_DDR_HIGH-CAM_DDR_LOW];
static ap_application application;
static unsigned tests,assertions,video_writes,video_reads,input_writes,graph_runs,pp_runs;
static unsigned index_q,status_q,osd_seq,frame_seq,tick,fail_capture,fail_write;
static uint8_t sent[1024][276];static unsigned sizes[1024],sent_count;
static void check(int ok,const char*msg){assertions++;if(!ok){fprintf(stderr,"FAIL %s test=%u\n",msg,tests);exit(10);}}
static uint16_t picture(unsigned i){return (uint16_t)((i*37u)^(i>>3)^0x25a5u);}
uint32_t camera_test_video_read(unsigned i){
 video_reads++;
 if(i==0x40/4)return fail_capture?0:0x43500001u;
 if(i==0x80/4)return 0x4f530001u;
 if(i==0x48/4)return status_q;
 if(i==0x4c/4)return frame_seq;
 if(i==0x54/4)return picture(index_q);
 if(i==0x9c/4)return osd_seq;
 return 0;
}
void camera_test_video_write(unsigned i,uint32_t v){
 video_writes++;
 if(i==0x44/4){status_q=v==1?18:0;if(v==1)frame_seq++;}
 if(i==0x50/4){index_q=v;status_q=26;}
 if(i==0x94/4)osd_seq++;
}
uint32_t camera_test_stats_read(unsigned i){return i==0?++tick:0;}
void camera_test_gpio_write(uint32_t v){check(v==0xe4,"capture GPIO failure code");}
int __real_platform_read(void*c,uint32_t a,uint8_t*p,uint32_t n){(void)c;if(a<CAM_DDR_LOW||a>CAM_DDR_HIGH||n>CAM_DDR_HIGH-a)return 1;memcpy(p,memory+a-CAM_DDR_LOW,n);return 0;}
int __real_platform_write(void*c,uint32_t a,const uint8_t*p,uint32_t n){(void)c;if(fail_write)return 1;if(a<CAM_DDR_LOW||a>CAM_DDR_HIGH||n>CAM_DDR_HIGH-a)return 1;memcpy(memory+a-CAM_DDR_LOW,p,n);if(a>=CAM_INPUT_BASE&&a<CAM_INPUT_BASE+CAM_INPUT_BYTES)input_writes+=n;return 0;}
int __real_platform_send(void*c,const uint8_t*p,uint32_t n){(void)c;check(sent_count<1024&&n<=276,"send capacity");check(n>=20&&ul_crc32(p,n-4)==get32(p+n-4),"outgoing CRC");memcpy(sent[sent_count],p,n);sizes[sent_count++]=n;return 0;}
void __real_ul_feed(void*s,uint8_t b){ul_feed((ul_loader*)s,b);}
void __real_ul_timeout(void*s){ul_timeout((ul_loader*)s);}
int __real_ai_graph_run(void*s,const void*b,uint32_t ops,uint32_t count,int(*obs)(void*,uint32_t,const uint32_t[40]),void*c){
 (void)ops;(void)b;graph_runs++;check(count==119,"graph node count");
 for(unsigned i=0;i<count;i++){uint32_t d[40]={0};if(obs&&obs(c,i,d))return 1;}
 ((ai_graph_state*)s)->completed=count;return 0;
}
void ai_graph_reset(ai_graph_state*s){memset(s,0,sizeof(*s));}
int pp_run(const pp_input*in,pp_workspace*w,unsigned*count){(void)in;pp_runs++;*count=1;int32_t box[6]={256,512,1024,2048,9000,66};memcpy(w->output[0].v,box,sizeof(box));return 0;}
static int mac_stub(void*c,const uint8_t*x,const uint8_t*w,unsigned m,unsigned f,unsigned l,int32_t b,unsigned u,int32_t z,int32_t*out){(void)c;(void)x;(void)w;(void)m;(void)f;(void)l;(void)b;(void)u;(void)z;(void)out;check(0,"unexpected MAC in protocol-only stub graph");return 1;}
static int reset_stub(void*c){(void)c;return 1;}
static void reset_case(void){
 memset(&application,0,sizeof(application));memset(memory,0,sizeof(memory));
 camera_ok=cache_enabled=cache_fault=0;graph_completed=results_reported=0;incoming_count=incoming_total=0;osd_count=0;camera_seq=0;
 video_writes=video_reads=input_writes=graph_runs=pp_runs=sent_count=0;index_q=status_q=osd_seq=frame_seq=tick=fail_capture=fail_write=0;
 ap_config cfg={0};cfg.low=CAM_DDR_LOW;cfg.work=CAM_INPUT_BASE;cfg.high=CAM_DDR_HIGH;cfg.ops=CAM_DDR_LOW+16;cfg.nodes=119;
 cfg.regions[0].base=CAM_DDR_LOW;cfg.regions[0].length=16;cfg.regions[1].base=cfg.ops;cfg.regions[1].length=16;cfg.regions[2].base=CAM_INPUT_BASE;cfg.regions[2].length=CAM_INPUT_BYTES;
 uint8_t zero[16]={0};for(unsigned i=0;i<2;i++){ul_sha256 h;ul_sha_init(&h);ul_sha_update(&h,zero,16);ul_sha_final(&h,cfg.regions[i].sha);}
 ap_platform io={0,__wrap_platform_read,__wrap_platform_write,mac_stub,__wrap_platform_send,reset_stub,0,camera_prepare_input};
 check(ap_init(&application,&cfg,&io)==0,"application init");tests++;
}
static void request(unsigned cmd,unsigned region,unsigned flags,uint32_t offset,const uint8_t*p,unsigned n,int corrupt){
 uint8_t bytes[276]={ 'A','I','P','1' };check(n<=256,"request bound");bytes[4]=(uint8_t)cmd;bytes[5]=(uint8_t)region;bytes[6]=1;put32(bytes+8,offset);bytes[12]=(uint8_t)n;bytes[13]=(uint8_t)(n>>8);bytes[14]=(uint8_t)flags;bytes[15]=(uint8_t)(flags>>8);if(n)memcpy(bytes+16,p,n);put32(bytes+16+n,ul_crc32(bytes,16+n)^(corrupt?1u:0u));
 for(unsigned i=0;i<20+n;i++)ap_feed(&application,bytes[i]);
}
static unsigned reply_status(void){check(sent_count!=0,"response exists");check(sizes[sent_count-1]==32,"ACK size");return get32(sent[sent_count-1]+16);}
static void upload(unsigned region){
 unsigned n=application.config.regions[region-1].length;uint8_t zero[256]={0},begin[36];ul_sha256 h;ul_sha_init(&h);for(unsigned i=0;i<n;){unsigned take=n-i;if(take>256)take=256;ul_sha_update(&h,zero,take);i+=take;}put32(begin,n);ul_sha_final(&h,begin+4);
 request(1,region,0,0,begin,36,0);check(reply_status()==0,"upload begin");
 /* Set wire sequence to match actual production loader acceptance. */
 unsigned seq=2;
 for(unsigned off=0;off<n;){unsigned take=n-off;if(take>256)take=256;uint8_t b[276]={ 'A','I','P','1',2 };b[5]=(uint8_t)region;b[6]=(uint8_t)seq;b[7]=(uint8_t)(seq>>8);put32(b+8,off);b[12]=(uint8_t)take;b[13]=(uint8_t)(take>>8);memcpy(b+16,zero,take);put32(b+16+take,ul_crc32(b,16+take));for(unsigned k=0;k<20+take;k++)ap_feed(&application,b[k]);check(reply_status()==0,"upload DATA");off+=take;seq++;}
 uint8_t b[20]={ 'A','I','P','1',3 };b[5]=(uint8_t)region;b[6]=(uint8_t)seq;b[7]=(uint8_t)(seq>>8);put32(b+8,n);put32(b+16,ul_crc32(b,16));for(unsigned k=0;k<20;k++)ap_feed(&application,b[k]);check(reply_status()==0,"upload COMMIT");
}
static void ready(void){upload(1);upload(2);upload(3);check(application.loader.validmask==7,"ready mask");sent_count=0;input_writes=0;}
static void no_side_effects(unsigned expected){check(reply_status()==expected,"reject code");check(video_writes==0&&input_writes==0&&graph_runs==0&&pp_runs==0,"rejected RUN has no side effects");}
static void verify_run(void){
 request(5,0,0,0,0,0,0);check(!application.failed&&graph_runs==1&&pp_runs==1,"normal graph and PP");check(application.loader.validmask==3,"input consumed");check(input_writes==76800,"capture wrote exact input size");check(osd_seq==1&&osd_count==1,"OSD committed one result");
 uint8_t expected[76800];for(unsigned y=0;y<160;y++)for(unsigned x=0;x<160;x++){unsigned pixel=picture((y+10)*320+x+80);expected[y*160+x]=(uint8_t)((pixel>>11)*8);expected[25600+y*160+x]=(uint8_t)(((pixel>>5)&63)*4);expected[51200+y*160+x]=(uint8_t)((pixel&31)*8);}
 check(memcmp(expected,memory+CAM_INPUT_BASE-CAM_DDR_LOW,sizeof(expected))==0,"independent full pixel reference");
 uint8_t digest[32];ul_sha256 h;ul_sha_init(&h);ul_sha_update(&h,expected,sizeof(expected));ul_sha_final(&h,digest);check(memcmp(digest,application.input_sha,32)==0,"actual acquired INPUT SHA");
 unsigned at=0;for(unsigned i=0;i<sent_count;i++)if(sent[i][4]==0xb0){unsigned phase=get32(sent[i]+16),node=get32(sent[i]+20);if(at<3)check(phase==at+1&&node==0,"capture phases");else if(at<122)check(phase==4&&node==at-2,"119 node phases");else{unsigned tail[4]={6,7,8,5};check(at<126&&phase==tail[at-122]&&node==119,"result phases");}at++;}check(at==126,"one complete split sequence");
 unsigned before_writes=video_writes,before_input=input_writes;request(5,0,0,0,0,0,0);check(reply_status()==UL_NOT_READY,"consumed RUN rejected");check(video_writes==before_writes&&input_writes==before_input&&graph_runs==1,"duplicate RUN leaves frame unchanged");
}
int main(void){
 reset_case();request(5,0,0,0,0,0,0);no_side_effects(UL_NOT_READY);
 reset_case();upload(1);request(5,0,0,0,0,0,0);no_side_effects(UL_NOT_READY);
 reset_case();ready();application.loader.active=3;request(5,0,0,0,0,0,0);no_side_effects(UL_NOT_READY);
 reset_case();ready();ul_failstop(&application.loader);request(5,0,0,0,0,0,0);no_side_effects(UL_FAILSTOP);
 for(unsigned k=0;k<5;k++){reset_case();ready();uint8_t value=0;request(5,k==0?1:0,k==1?1:k==2?256:0,k==3?4:0,&value,k==4?1:0,0);no_side_effects(UL_WIRE);}
 reset_case();ready();request(5,0,0,0,0,0,1);no_side_effects(UL_WIRE);
 reset_case();ready();verify_run();
 reset_case();ready();fail_capture=1;request(5,0,0,0,0,0,0);check(reply_status()==UL_IO,"capture failure ACK");check(application.loader.sticky&&graph_runs==0&&pp_runs==0,"capture failure stops graph");
 reset_case();ready();fail_write=1;request(5,0,0,0,0,0,0);check(reply_status()==UL_IO&&application.loader.sticky&&graph_runs==0,"capture write failure stops graph");
 for(unsigned cmd=0x21;cmd<=0x22;cmd++)for(unsigned k=0;k<4;k++){reset_case();uint8_t count[4]={2,0,0,0};request(cmd,k==0?99:0,k==1?1:k==2?256:0,k==3?1:0,count,cmd==0x21?4:0,0);check(sent[sent_count-1][4]==0xb2,"custom malformed error");check(video_reads==0&&video_writes==0&&input_writes==0,"bad custom no MMIO");}
 reset_case();request(0x22,0,0,0,0,0,0);check(sent[0][4]==0xa2&&sizes[0]==52,"valid status works before capture");
 reset_case();{uint8_t p=0;request(0x22,0,0,0,&p,1,0);check(sent[0][4]==0xb2&&video_reads==0&&video_writes==0,"status length rejects before MMIO");}
 reset_case();request(0x22,0,0,0,0,0,1);check(reply_status()==UL_WIRE&&video_reads==0&&video_writes==0,"custom bad CRC rejected");
 reset_case();{const uint8_t prefix[4]={'A','I','P','1'};for(unsigned i=0;i<4;i++)ap_feed(&application,prefix[i]);__wrap_ul_timeout(&application.loader);request(5,0,0,0,0,0,0);no_side_effects(UL_NOT_READY);}
 reset_case();ready();verify_run();sent_count=0;{uint8_t n[4]={240,0,0,0};request(0x21,0,0,0,n,4,0);check(sent[0][4]==0xa1&&sizes[0]==260,"valid locked snapshot read");for(unsigned k=0;k<120;k++)check(((unsigned)sent[0][16+2*k]|(unsigned)sent[0][17+2*k]<<8)==picture(k),"snapshot pixel exact");}
 reset_case();ready();verify_run();sent_count=0;upload(3);sent_count=0;graph_runs=pp_runs=input_writes=0;request(5,0,0,0,0,0,0);check(graph_runs==1&&pp_runs==1&&input_writes==76800&&osd_seq==2,"fresh input allows second run");
 printf("PROTOCOL_REGRESSION_PASS cases=%u assertions=%u\n",tests,assertions);return 0;
}
