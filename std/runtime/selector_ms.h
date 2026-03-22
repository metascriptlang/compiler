/*
 * MetaScript Selector Bridge — exposes kqueue/epoll selector to MetaScript
 *
 * Uses thread-local buffer for poll results (avoids passing struct arrays).
 * Selector handle passed as int64 (opaque pointer cast).
 */

#ifndef MS_SELECTOR_MS_H
#define MS_SELECTOR_MS_H

#include "selector.h"
#include "std/core/promise/future.h"  /* MS_THREAD_LOCAL */

/* Thread-local result buffer — each thread gets its own (safe for event-loop-per-core) */
static MS_THREAD_LOCAL msReadyEvent _msEvtBuf[64];

static inline int64_t msSelectorCreateMS(void) {
	return (int64_t)(intptr_t)msSelectorCreate();
}

static inline void msSelectorDestroyMS(int64_t sel) {
	msSelectorDestroy((msSelector*)(intptr_t)sel);
}

static inline int32_t msSelectorRegisterMS(int64_t sel, int32_t fd, int32_t events) {
	return msSelectorRegister((msSelector*)(intptr_t)sel, fd, (uint32_t)events, NULL);
}

static inline int32_t msSelectorUpdateMS(int64_t sel, int32_t fd, int32_t events) {
	return msSelectorUpdate((msSelector*)(intptr_t)sel, fd, (uint32_t)events, NULL);
}

static inline int32_t msSelectorUnregisterMS(int64_t sel, int32_t fd) {
	return msSelectorUnregister((msSelector*)(intptr_t)sel, fd);
}

static inline int32_t msSelectorPollMS(int64_t sel, int32_t timeoutMs) {
	return msSelectorPoll((msSelector*)(intptr_t)sel, timeoutMs, _msEvtBuf, 64);
}

static inline int32_t msSelectorEventFd(int32_t index) {
	return (int32_t)_msEvtBuf[index].fd;
}

static inline int32_t msSelectorEventFlags(int32_t index) {
	return (int32_t)_msEvtBuf[index].events;
}

#endif /* MS_SELECTOR_MS_H */
