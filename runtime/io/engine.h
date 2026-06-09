/*
 * MetaScript Async I/O Engine — Unified Completion-Based Interface
 *
 * Zig-style design: completion API surface on all platforms.
 * - Readiness platforms (epoll/kqueue/poll): simulate completions internally
 * - io_uring (Linux 5.6+): native completion via SQE/CQE
 *
 * User code is identical regardless of backend:
 *   void* fut = msIoRecv(engine, fd, maxBytes);
 *   // ... event loop runs, engine completes future with data ...
 *   msString data = msUnboxString(msFutureRead(fut));
 */
#ifndef MS_IO_ENGINE_H
#define MS_IO_ENGINE_H

#include "runtime/promise/future.h"
#ifndef _WIN32
#include "runtime/actor/selector.h"
#endif
#include "runtime/core/system.h"
#include <stdint.h>

/* ===== Operation Types ===== */

typedef enum {
	MS_IO_ACCEPT  = 0,
	MS_IO_RECV    = 1,
	MS_IO_SEND    = 2,
	MS_IO_CLOSE   = 3,
} msIoOp;

/* ===== I/O Request (SQE equivalent) ===== */

typedef struct msIoRequest {
	msIoOp op;
	int fd;
	char* buf;             /* recv: engine-allocated buffer. send: borrowed data pointer */
	int32_t len;           /* recv: buffer capacity. send: data length */
	int32_t offset;        /* send: offset for partial writes */
	void* fut;             /* msFuture* to complete with result */
	msString strRef;       /* send: incref'd string (decref on completion to prevent use-after-free) */
	struct msIoRequest* next;  /* free-list chain */
} msIoRequest;

/* ===== Engine (opaque, backend-specific) ===== */

typedef struct msIoEngine msIoEngine;

/* Create/destroy */
msIoEngine* msIoEngineCreate(void);
void msIoEngineDestroy(msIoEngine* e);

/* Thread-local singleton (lazy-init) */
msIoEngine* msGetIoEngine(void);
msIoEngine* msGetIoEngineIfExists(void);

/* ===== Async Operations ===== */

/* Accept: returns msFuture_int32* (client fd, or -1 on error) */
void* msIoAccept(msIoEngine* e, int listenFd);

/* Recv: returns msFuture_msString* (inline msString — empty string on close/error) */
void* msIoRecv(msIoEngine* e, int fd, int32_t maxBytes);

/* Send: returns msFuture_int32* (bytes sent, or -1 on error) */
void* msIoSend(msIoEngine* e, int fd, const char* data, int32_t len);

/* Send with msString lifetime management (incref on submit, decref on complete) */
void* msIoSendString(msIoEngine* e, int fd, msString data);

/* ===== Event Loop Integration ===== */

/* Process completions. Called by msRunOnce or standalone event loop.
 * Returns number of completions processed. */
int msIoEnginePoll(msIoEngine* e, int timeoutMs);

/* Drop pending I/O on fd and complete its future (peer-close shape).
 * Readiness does real cleanup — kqueue/epoll silently drop closed fds
 * so userspace must clear fdMap and complete the future. uring + IOCP
 * stubs: kernel cancels pending ops on close. */
void msIoEngineCancelFd(msIoEngine* e, int fd);

static inline void msIoEngineCancelFd_ms(int32_t fd) {
	msIoEngine* eng = msGetIoEngineIfExists();
	if (eng != NULL) msIoEngineCancelFd(eng, fd);
}

/* Watch (don't drain) an external fd — caller's selector drains the
 * underlying state. Used to chain-poll the dispatcher selector / wake pipe
 * so cross-thread completions wake the engine immediately. */
void msIoEngineAddWakeFd(msIoEngine* e, int fd);

static inline void msIoEngineAddWakeFd_ms(int32_t fd) {
	msIoEngine* eng = msGetIoEngineIfExists();
	if (eng != NULL) msIoEngineAddWakeFd(eng, fd);
}

/* ===== Targeted Cross-Thread Scheduler Wake (PARALOCK Amendment B / I16) =====
 *
 * A serve loop parks in msIoEnginePoll (backend-specific: kqueue/epoll/io_uring/
 * IOCP), where the pool condvar is invisible. To deliver a cross-thread actor send
 * to such a scheduler, the wake must break that backend's blocking poll — so it is
 * an ENGINE method, implemented per-backend:
 *   readiness → EVFILT_USER (kqueue) / eventfd (epoll) on the selector
 *   io_uring  → eventfd + a re-armed POLL_ADD (a ring-less write() breaks io_uring_enter)
 *   IOCP      → PostQueuedCompletionStatus (NULL-overlapped, skipped by the poll)
 * The poll() fallback (no user-event primitive) is a no-op — the DRIVER_POLL busy-poll
 * still delivers there, just at coarser latency. */
void msIoEngineWake(msIoEngine* e);

/* Per-scheduler registry (defined in pool.c). A serve thread publishes its engine
 * as scheduler `sid`'s wake target via msIoEngineAddWakeFd; msPoolWakeWorker routes
 * a cross-thread send through msIoEngineWake so it reaches a scheduler parked in its
 * engine poll, not just the pool condvar. msSchedWakeUnregisterEngine clears any slot
 * pointing at `e` before it is destroyed. */
void msSchedWakeRegister(int sid, msIoEngine* e);
void msSchedWakeUnregisterEngine(msIoEngine* e);

/* ===== MetaScript Bridge Wrappers ===== */

static inline void* msIoAccept_ms(int32_t listenFd) {
	return msIoAccept(msGetIoEngine(), listenFd);
}

static inline void* msIoRecv_ms(int32_t fd, int32_t maxBytes) {
	return msIoRecv(msGetIoEngine(), fd, maxBytes);
}

static inline void* msIoSend_ms(int32_t fd, msString data) {
	return msIoSendString(msGetIoEngine(), fd, data);
}

/* Poll engine + dispatcher together (for async server event loops) */
static inline int32_t msIoRunOnce(int32_t timeoutMs) {
	msIoEngine* eng = msGetIoEngineIfExists();
	int32_t did = 0;
	if (eng != NULL) {
		did = (int32_t)msIoEnginePoll(eng, timeoutMs);
	}
	/* Also drain dispatcher callbacks/timers */
	extern bool msRunOnce(int timeoutMs);
	msRunOnce(0);
	return did;
}

#endif /* MS_IO_ENGINE_H */
