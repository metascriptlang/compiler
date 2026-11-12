#ifndef ACTOR_SEND_PAST_ITS_ALIVE_CHECK_H
#define ACTOR_SEND_PAST_ITS_ALIVE_CHECK_H
#include <stdint.h>
void probeMade(void);
int32_t probeWaitMade(void);
int32_t probeSendAfterStop(int64_t pid);
#endif
