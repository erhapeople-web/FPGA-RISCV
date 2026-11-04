#include "app.h"
#include "production.h"
#include "platform.h"
#include "camera_hooks.h"
static ap_application application;
volatile uint32_t application_state[4];
int main(void){ap_config cfg;ap_production_config(&cfg);ap_platform io={0,platform_read,platform_write,platform_mac,platform_send,platform_reset,0,camera_prepare_input};application_state[0]=0x41505031u;
 if(platform_initialize()||ap_init(&application,&cfg,&io)){application_state[1]=0xe1u;for(;;);}
 application_state[1]=1;
 for(;;){uint8_t b;int r=platform_receive(&b);if(r<0){ap_fault(&application);application_state[1]=0xe2u;for(;;);}if(r)ap_feed(&application,b);else ul_timeout(&application.loader);application_state[2]=application.runs;application_state[3]=application.graph.completed;if(application.failed){application_state[1]=0xe3u;for(;;);}}
}
