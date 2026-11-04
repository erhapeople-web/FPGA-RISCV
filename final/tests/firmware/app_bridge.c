#include "app.h"
#include "camera_hooks.h"
#define ul_feed __wrap_ul_feed
#define ai_graph_run __wrap_ai_graph_run
#include "app.c"
