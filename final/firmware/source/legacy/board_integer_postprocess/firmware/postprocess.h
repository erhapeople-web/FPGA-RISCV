#ifndef POSTPROCESS_H
#define POSTPROCESS_H
#include <stdint.h>
#define PP_CANDIDATES 1575
#define PP_OUTPUTS 300
typedef struct {int32_t v[6];} pp_box;
typedef struct {pp_box candidates[PP_CANDIDATES],output[PP_OUTPUTS];uint16_t order[PP_CANDIDATES];} pp_workspace;
typedef struct {void *ctx;int (*read)(void *,uint32_t,uint8_t *,uint32_t);uint32_t heads[3],sigmoid,anchors[3];} pp_input;
/* Fixed NCHW INT16 heads1x255x20x20,10x10,5x5. Callback addresses are byte
   offsets, never CPU pointers; read completes synchronously and returns0.
   Table entries0..32768 and positive anchors<=131072 Q8 are model contract.
   pp_run returns0, count<=300. Any nonzero discards output; caller restores
   failed backend before reuse. Workspace belongs exclusively to this call.
   Graph activation RAM and this workspace must be reused, not simultaneously
   retained in a64KiB TCM; head/model storage must remain in external backend. */
int pp_run(const pp_input *,pp_workspace *,unsigned *count);
int pp_nms(pp_workspace *,unsigned candidates,unsigned *count);
#endif
