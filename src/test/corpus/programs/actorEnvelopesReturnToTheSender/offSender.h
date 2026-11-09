#ifndef ACTOR_ENVELOPES_OFF_SENDER_H
#define ACTOR_ENVELOPES_OFF_SENDER_H
#include <stdint.h>
void probeMarkSender(void);
void probeTake(void);
void probeMade(void);
int32_t probeWaitMade(void);
int32_t probeWaitTaken(int64_t n);
int64_t probeOnSender(void);
#endif
