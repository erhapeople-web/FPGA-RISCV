#include "app.h"
static void zero(void*v,unsigned n){uint8_t*p=v;while(n--)*p++=0;}
static void put(uint8_t*p,uint32_t x){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(x>>(8*i));}
static uint32_t get(const uint8_t*p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static int inside(uint32_t a,uint32_t n,uint32_t lo,uint32_t hi){return n&&a>=lo&&a<hi&&n<=hi-a;}
void ap_fault(ap_application*a){a->failed=1;a->queued=a->consume=a->count=0;ul_failstop(&a->loader);}
static int fail(ap_application*a){ap_fault(a);return 1;}
static int upload_allowed(ap_application*a,uint32_t p,uint32_t n){if(a->failed)return 0;for(unsigned i=0;i<3;i++){ul_region*r=&a->config.regions[i];if(inside(p,n,r->base,r->base+r->length))return 1;}return 0;}
int ap_upload_read(void*v,uint32_t p,uint8_t*out,uint32_t n){ap_application*a=v;if(!upload_allowed(a,p,n))return fail(a);if(a->io.read(a->io.ctx,p,out,n))return fail(a);return 0;}
int ap_upload_write(void*v,uint32_t p,const uint8_t*in,uint32_t n){ap_application*a=v;if(!upload_allowed(a,p,n))return fail(a);if(a->io.write(a->io.ctx,p,in,n))return fail(a);return 0;}
int ap_graph_probe(void*v,uint32_t p,uint32_t n,int w){ap_application*a=v;return a->failed||!inside(p,n,w?a->config.work:a->config.low,a->config.high);}
int ap_graph_read(void*v,uint32_t p,uint8_t*out,uint32_t n){ap_application*a=v;if(ap_graph_probe(a,p,n,0))return fail(a);if(a->io.read(a->io.ctx,p,out,n))return fail(a);return 0;}
int ap_graph_write(void*v,uint32_t p,const uint8_t*in,uint32_t n){ap_application*a=v;if(ap_graph_probe(a,p,n,1))return fail(a);if(a->io.write(a->io.ctx,p,in,n))return fail(a);return 0;}
static int mac(void*v,const uint8_t*x,const uint8_t*w,unsigned mask,unsigned first,unsigned last,int32_t bias,unsigned uns,int32_t zero_point,int32_t*out){ap_application*a=v;if(a->failed)return 1;if(a->io.mac(a->io.ctx,x,w,mask,first,last,bias,uns,zero_point,out))return fail(a);return 0;}
static int infer(void*v){ap_application*a=v;uint8_t data[64];ul_sha256 sha;if(a->failed||a->queued)return fail(a);
 /* dispatch() has admitted this RUN. Never acquire or overwrite INPUT for
    a rejected RUN; hash the actual newly acquired frame, not its placeholder. */
 if(a->io.prepare_input && a->io.prepare_input(a->io.ctx))return 1;
 a->runs++;ul_sha_init(&sha);
 for(uint32_t i=0;i<a->config.regions[2].length;){unsigned n=a->config.regions[2].length-i;if(n>64)n=64;if(ap_upload_read(a,a->config.regions[2].base+i,data,n))return 1;ul_sha_update(&sha,data,n);i+=n;}
 ul_sha_final(&sha,a->input_sha);
 ai_backend b={a,ap_graph_probe,ap_graph_read,ap_graph_write,mac};
 if(ai_graph_run(&a->graph,&b,a->config.ops,a->config.nodes,a->io.observer,a->io.ctx))return fail(a);
 pp_input input={a,ap_graph_read,{0,0,0},a->config.sigmoid,{0,0,0}};for(unsigned i=0;i<3;i++){input.heads[i]=a->config.heads[i];input.anchors[i]=a->config.anchors[i];}
 if(pp_run(&input,&a->post,&a->count)||a->count>PP_OUTPUTS)return fail(a);a->queued=1;return 0;
}
void ap_box_encode(uint8_t out[24],const pp_box*b){for(unsigned i=0;i<6;i++)put(out+4*i,(uint32_t)b->v[i]);}
static uint32_t crc_update(uint32_t c,const uint8_t*p,unsigned n){while(n--){c^=*p++;for(unsigned i=0;i<8;i++)c=(c>>1)^(0xedb88320u&(0u-(c&1u)));}return c;}
static int send(ap_application*a,const uint8_t*p,unsigned n){if(a->failed)return 1;if(a->io.send(a->io.ctx,p,n))return fail(a);return 0;}
static int frame(ap_application*a,unsigned cmd,unsigned seq,unsigned index,const uint8_t*p,unsigned n){uint8_t b[276];zero(b,16);b[0]='A';b[1]='I';b[2]='P';b[3]='1';b[4]=(uint8_t)cmd;b[6]=(uint8_t)seq;b[7]=(uint8_t)(seq>>8);put(b+8,index);b[12]=(uint8_t)n;b[13]=(uint8_t)(n>>8);for(unsigned i=0;i<n;i++)b[16+i]=p[i];put(b+16+n,ul_crc32(b,16+n));return send(a,b,20+n);}
static void reply(void*v,const uint8_t*p,uint32_t n){ap_application*a=v;if(n!=32){fail(a);return;}if(send(a,p,n))return;
 if(p[4]!=0x85||get(p+16))return;if(!a->queued){fail(a);return;}unsigned seq=p[6]|(unsigned)p[7]<<8;uint32_t crc=0xffffffffu;
 for(unsigned i=0;i<a->count;i+=10){uint8_t payload[240];unsigned count=a->count-i;if(count>10)count=10;for(unsigned j=0;j<count;j++)ap_box_encode(payload+24*j,&a->post.output[i+j]);crc=crc_update(crc,payload,24*count);if(frame(a,0x90,seq,i,payload,24*count))return;}
 uint8_t end[40];put(end,a->count);put(end+4,~crc);for(unsigned i=0;i<32;i++)end[i+8]=a->input_sha[i];if(frame(a,0x91,seq,a->count,end,40))return;a->queued=0;a->consume=1;
}
int ap_init(ap_application*a,const ap_config*c,const ap_platform*i){if(a->initialized)return fail(a);zero(a,sizeof(*a));a->initialized=1;if(!c||!i||!i->read||!i->write||!i->mac||!i->send||!i->reset)return fail(a);a->config=*c;a->io=*i;
 if(c->low>=c->work||c->work>=c->high||!c->nodes||c->ops!=c->regions[1].base)return fail(a);
#ifndef AP_TEST_FIXTURE
 if(c->nodes!=119)return fail(a);
#endif
 for(unsigned k=0;k<3;k++){const ul_region*r=&c->regions[k];if(!inside(r->base,r->length,c->low,c->high))return fail(a);if(k<2&&(r->base>=c->work||r->length>c->work-r->base))return fail(a);if(k==2&&r->base<c->work)return fail(a);}
 ul_backend b={a,ap_upload_read,ap_upload_write,infer,reply};if(ul_init(&a->loader,c->regions,&b))return fail(a);ai_graph_reset(&a->graph);return 0;
}
void ap_feed(ap_application*a,uint8_t b){if(a->failed)return;ul_feed(&a->loader,b);if(a->failed){ul_failstop(&a->loader);return;}if(a->consume){a->loader.validmask&=3u;a->loader.commit_region=0;a->consume=0;}}
int ap_global_reset(ap_application*a){if(!a->loader.configured)return fail(a);if(!a->io.reset||a->io.reset(a->io.ctx))return fail(a);a->failed=a->queued=a->consume=a->count=0;zero(a->input_sha,32);ul_global_reset(&a->loader);ai_graph_reset(&a->graph);return 0;}
