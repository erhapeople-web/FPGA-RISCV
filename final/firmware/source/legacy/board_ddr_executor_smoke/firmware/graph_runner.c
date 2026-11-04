#include "graph_runner.h"
void ai_graph_reset(ai_graph_state *s){s->failed=0;s->status=AI_OK;s->node_index=0;s->completed=0;}
static int stop(ai_graph_state *s,int error,uint32_t index){s->failed=1;s->status=error;s->node_index=index;return error;}
int ai_graph_run(ai_graph_state *s,const ai_backend *b,uint32_t base,uint32_t count,ai_graph_observer observe,void *ctx){
 if(!s)return AI_DESCRIPTOR;
 if(s->failed)return s->status;
 if(!b||!b->read||!count)return stop(s,AI_DESCRIPTOR,0);
 if(count>0xffffffffu/160u||count*160u>0xffffffffu-base)return stop(s,AI_ADDRESS,0);
 s->completed=0;
 for(uint32_t i=0;i<count;i++){
 uint8_t bytes[160];uint32_t d[40];s->node_index=i;
 if(b->read(b->ctx,base+160u*i,bytes,160))return stop(s,AI_IO,i);
 for(unsigned j=0;j<40;j++)d[j]=(uint32_t)bytes[4*j]|((uint32_t)bytes[4*j+1]<<8)|((uint32_t)bytes[4*j+2]<<16)|((uint32_t)bytes[4*j+3]<<24);
 int r=ai_execute(d,b);if(r)return stop(s,r,i);
 if(observe&&observe(ctx,i,d))return stop(s,AI_IO,i);
 s->completed=i+1;
 }s->status=AI_OK;return AI_OK;
}
