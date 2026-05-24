/*
 * MetaScript I/O Selector — platform-agnostic event notification
 *
 * Abstracts kqueue (macOS/BSD), epoll (Linux), and poll (POSIX fallback)
 * behind a unified interface for the async dispatcher.
 */
#ifndef MS_SELECTOR_H
#define MS_SELECTOR_H

#include <stdbool.h>
#include <stdint.h>

/* Event flags (bitmask) */
#define MS_EVENT_READ   1
#define MS_EVENT_WRITE  2
#define MS_EVENT_ERROR  4

/* A ready event returned by msSelectorPoll */
typedef struct {
	int fd;
	uint32_t events;    /* bitmask of MS_EVENT_* */
	void* userdata;     /* e.g. msFuture* */
} msReadyEvent;

/* Opaque selector handle */
typedef struct msSelector msSelector;

/* Create a new selector (kqueue/epoll/poll depending on platform) */
msSelector* msSelectorCreate(void);

/* Destroy selector and release OS resources */
void msSelectorDestroy(msSelector* sel);

/* Register fd for event notification. Returns 0 on success, -1 on error. */
int msSelectorRegister(msSelector* sel, int fd, uint32_t events, void* userdata);

/* Update events/userdata for an already-registered fd. Returns 0 on success, -1 on error. */
int msSelectorUpdate(msSelector* sel, int fd, uint32_t events, void* userdata);

/* Unregister fd. Returns 0 on success, -1 on error. */
int msSelectorUnregister(msSelector* sel, int fd);

/* Poll for ready events. Returns number of ready events (0 on timeout, -1 on error).
 * Results written to out array, up to maxEvents entries. */
int msSelectorPoll(msSelector* sel, int timeoutMs, msReadyEvent* out, int maxEvents);

/* Expose the underlying selector fd (kqueue/epoll). Returns -1 if the
 * backend has no fd (poll(), Windows fallback) — caller falls back to
 * timeout-polling. Use this to register the selector as a watched fd in
 * another selector (chained-poll pattern, httpbeast-style). */
int msSelectorGetFd(msSelector* sel);

/* ===== MetaScript Bridge =====
 * Thin wrappers that cast int64 handles ↔ msSelector* pointers.
 * MetaScript has no raw pointer type, so selector handles are passed as int64.
 * Thread-local result buffer avoids passing struct arrays across the FFI boundary. */

/* Bridge is always available — the static inline functions are only
 * instantiated in translation units that actually call them. */

#include "runtime/promise/future.h"  /* MS_THREAD_LOCAL */

/* Per-thread poll result buffer. Extern (definition in actor.c) so writer
 * (msSelectorWait) and readers (msSelectorEventFd/Flags) called across TUs
 * on the same thread see the same buffer. */
extern MS_THREAD_LOCAL msReadyEvent _msEvtBuf[64];

static inline int64_t msSelectorOpen(void) {
	return (int64_t)(intptr_t)msSelectorCreate();
}

static inline void msSelectorClose(int64_t sel) {
	msSelectorDestroy((msSelector*)(intptr_t)sel);
}

static inline int32_t msSelectorAdd(int64_t sel, int32_t fd, int32_t events) {
	return msSelectorRegister((msSelector*)(intptr_t)sel, fd, (uint32_t)events, NULL);
}

static inline int32_t msSelectorModify(int64_t sel, int32_t fd, int32_t events) {
	return msSelectorUpdate((msSelector*)(intptr_t)sel, fd, (uint32_t)events, NULL);
}

static inline int32_t msSelectorRemove(int64_t sel, int32_t fd) {
	return msSelectorUnregister((msSelector*)(intptr_t)sel, fd);
}

static inline int32_t msSelectorWait(int64_t sel, int32_t timeoutMs) {
	return msSelectorPoll((msSelector*)(intptr_t)sel, timeoutMs, _msEvtBuf, 64);
}

static inline int32_t msSelectorEventFd(int32_t index) {
	return (int32_t)_msEvtBuf[index].fd;
}

static inline int32_t msSelectorEventFlags(int32_t index) {
	return (int32_t)_msEvtBuf[index].events;
}

static inline int32_t msSelectorFd(int64_t sel) {
	return (int32_t)msSelectorGetFd((msSelector*)(intptr_t)sel);
}

/* end bridge */

#endif /* MS_SELECTOR_H */
