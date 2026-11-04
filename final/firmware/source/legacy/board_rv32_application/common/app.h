#ifndef AIP_APPLICATION_H
#define AIP_APPLICATION_H
#include <stdint.h>
#include "loader.h"
#include "graph_runner.h"
#include "postprocess.h"
typedef struct {ul_region regions[3];uint32_t low,high,work,ops,nodes,heads[3],sigmoid,anchors[3];} ap_config;
typedef struct {
 void *ctx;
 int (*read)(void*,uint32_t,uint8_t*,uint32_t);
 int (*write)(void*,uint32_t,const uint8_t*,uint32_t);
 int (*mac)(void*,const uint8_t[8],const uint8_t[8],unsigned,unsigned,unsigned,int32_t,unsigned,int32_t,int32_t*);
 int (*send)(void*,const uint8_t*,uint32_t);
 int (*reset)(void*);
 ai_graph_observer observer;
 /* Optional acquisition after loader RUN admission, before input SHA/graph.
    Failure puts the loader in fail-stop without starting graph execution. */
 int (*prepare_input)(void*);
} ap_platform;
typedef struct {ap_config config;ap_platform io;ul_loader loader;ai_graph_state graph;pp_workspace post;uint8_t input_sha[32];unsigned count;uint32_t runs,initialized;unsigned failed,queued,consume;} ap_application;
/* Storage MUST be zero-initialized before its first and only ap_init. Reuse the
   configured object via ap_global_reset after coordinated platform reset; never
   call ap_init again to clear failure or an in-flight transaction. */
int ap_init(ap_application*,const ap_config*,const ap_platform*);
void ap_feed(ap_application*,uint8_t);
void ap_fault(ap_application*);
int ap_global_reset(ap_application*);
int ap_upload_read(void*,uint32_t,uint8_t*,uint32_t);
int ap_upload_write(void*,uint32_t,const uint8_t*,uint32_t);
int ap_graph_probe(void*,uint32_t,uint32_t,int);
int ap_graph_read(void*,uint32_t,uint8_t*,uint32_t);
int ap_graph_write(void*,uint32_t,const uint8_t*,uint32_t);
void ap_box_encode(uint8_t[24],const pp_box*);
#endif
