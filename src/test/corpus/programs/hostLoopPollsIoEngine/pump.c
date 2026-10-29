#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include "pump.h"

extern void* msGetDispatcher(void);
extern int msGetDispatcherSelectorFd(void);
extern bool msRunOnce(int timeoutMs);

static bool gDone = false;

void msTestHostLoopDone(void) { gDone = true; }

static int64_t monoMs(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int32_t msTestHostLoopRun(int32_t maxMs) {
	msGetDispatcher();
	struct pollfd watched = { .fd = msGetDispatcherSelectorFd(), .events = POLLIN };
	if (watched.fd < 0) return -1;
	int64_t deadline = monoMs() + maxMs;
	while (!gDone) {
		int64_t left = deadline - monoMs();
		if (left <= 0 || poll(&watched, 1, (int)left) <= 0) break;
		msRunOnce(0);
	}
	return gDone ? 1 : 0;
}
