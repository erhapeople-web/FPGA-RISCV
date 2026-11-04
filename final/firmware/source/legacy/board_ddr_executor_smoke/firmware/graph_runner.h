#ifndef GRAPH_RUNNER_H
#define GRAPH_RUNNER_H
#include "executor.h"
typedef struct {unsigned failed;int status;uint32_t node_index,completed;} ai_graph_state;
typedef int (*ai_graph_observer)(void *ctx,uint32_t index,const uint32_t descriptor[40]);
/* Reset state only after hardware/global reset has canceled residual work.
 count>0, descriptors are160-byte little-endian records at byte offsets.
 Any failure latches status/index; later calls perform no backend/MAC/observer.
 Observer sees only completed nodes, must not mutate payload; nonzero=>AI_IO.
 Success does not imply vendor DDR visibility beyond backend's contract. */
void ai_graph_reset(ai_graph_state *state);
int ai_graph_run(ai_graph_state *state,const ai_backend *backend,uint32_t ops_base,uint32_t count,ai_graph_observer observer,void *observer_ctx);
#endif
