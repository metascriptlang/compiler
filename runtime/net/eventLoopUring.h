/*
 * io_uring Native Ops for HTTP Server Event Loop
 *
 * Provides individual submit + batch-wait functions that the MetaScript
 * event loop calls directly. No C-level event loop — MetaScript retains
 * full control of request parsing and handler dispatch.
 *
 * On Linux: native io_uring (zero syscall per I/O op, batched submission).
 * On macOS: stubs that fall back to non-blocking syscalls.
 */

#ifndef MS_EVENT_LOOP_URING_H
#define MS_EVENT_LOOP_URING_H

#include "runtime/core/system.h"
#include <stdint.h>

static inline int32_t msHasUringEventLoop(void) {
#if defined(__linux__) && !defined(MS_USE_EPOLL)
	return 1;
#else
	return 0;
#endif
}

#if defined(__linux__) && !defined(MS_USE_EPOLL)

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/io_uring.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <errno.h>
#include <stdatomic.h>

/* ===== Ring management ===== */

static int __uring_setup(unsigned entries, struct io_uring_params* p) {
	return (int)syscall(__NR_io_uring_setup, entries, p);
}

static int __uring_enter(int fd, unsigned toSubmit, unsigned minComplete, unsigned flags) {
	return (int)syscall(__NR_io_uring_enter, fd, toSubmit, minComplete, flags, NULL, 0);
}

#define URING_EVT_ENTRIES 512
#define URING_EVT_MAX     64

/* Encode op + fd into user_data */
#define URING_TAG(fd, op) ((uint64_t)(uint32_t)(fd) | ((uint64_t)(uint32_t)(op) << 32))
#define URING_TAG_FD(v)   ((int32_t)(uint32_t)(v))
#define URING_TAG_OP(v)   ((int32_t)(uint32_t)((v) >> 32))

#define URING_OP_ACCEPT 0
#define URING_OP_RECV   1
#define URING_OP_SEND   2

/* Per-thread io_uring ring for event loop */
typedef struct {
	int ringFd;
	unsigned* sqHead;
	unsigned* sqTail;
	unsigned* sqMask;
	unsigned* sqArray;
	struct io_uring_sqe* sqes;
	unsigned sqEntries;
	unsigned* cqHead;
	unsigned* cqTail;
	unsigned* cqMask;
	struct io_uring_cqe* cqes;
	unsigned cqEntries;
	int pending;  /* pending submissions */
} msUringEvt;

/* Event result — returned to MetaScript */
typedef struct {
	int32_t fd;
	int32_t op;
	int32_t res;  /* bytes received/sent, or client fd for accept, or -1 error */
} msUringEvent;

static _Thread_local msUringEvt _uringEvt;
static _Thread_local int _uringEvtInit = 0;
static _Thread_local msUringEvent _uringEvtBuf[URING_EVT_MAX];

static int32_t msUringEvtInit(void) {
	if (_uringEvtInit) return 0;
	struct io_uring_params params;
	memset(&params, 0, sizeof(params));
	int fd = __uring_setup(URING_EVT_ENTRIES, &params);
	if (fd < 0) return -1;
	_uringEvt.ringFd = fd;
	_uringEvt.sqEntries = params.sq_entries;
	_uringEvt.cqEntries = params.cq_entries;
	_uringEvt.pending = 0;

	size_t sqRingSz = params.sq_off.array + params.sq_entries * sizeof(unsigned);
	void* sqPtr = mmap(NULL, sqRingSz, PROT_READ | PROT_WRITE,
	                    MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
	if (sqPtr == MAP_FAILED) { close(fd); return -1; }
	_uringEvt.sqHead  = (unsigned*)((char*)sqPtr + params.sq_off.head);
	_uringEvt.sqTail  = (unsigned*)((char*)sqPtr + params.sq_off.tail);
	_uringEvt.sqMask  = (unsigned*)((char*)sqPtr + params.sq_off.ring_mask);
	_uringEvt.sqArray = (unsigned*)((char*)sqPtr + params.sq_off.array);

	size_t sqesSz = params.sq_entries * sizeof(struct io_uring_sqe);
	_uringEvt.sqes = (struct io_uring_sqe*)mmap(NULL, sqesSz, PROT_READ | PROT_WRITE,
	                  MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
	if (_uringEvt.sqes == MAP_FAILED) { close(fd); return -1; }

	size_t cqRingSz = params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe);
	void* cqPtr = mmap(NULL, cqRingSz, PROT_READ | PROT_WRITE,
	                    MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
	if (cqPtr == MAP_FAILED) { close(fd); return -1; }
	_uringEvt.cqHead = (unsigned*)((char*)cqPtr + params.cq_off.head);
	_uringEvt.cqTail = (unsigned*)((char*)cqPtr + params.cq_off.tail);
	_uringEvt.cqMask = (unsigned*)((char*)cqPtr + params.cq_off.ring_mask);
	_uringEvt.cqes   = (struct io_uring_cqe*)((char*)cqPtr + params.cq_off.cqes);

	_uringEvtInit = 1;
	return 0;
}

static struct io_uring_sqe* __uringGetSqe(void) {
	msUringEvt* r = &_uringEvt;
	unsigned tail = atomic_load_explicit((_Atomic unsigned*)r->sqTail, memory_order_relaxed);
	unsigned head = atomic_load_explicit((_Atomic unsigned*)r->sqHead, memory_order_acquire);
	if (tail - head >= r->sqEntries) return NULL;
	struct io_uring_sqe* sqe = &r->sqes[tail & *r->sqMask];
	memset(sqe, 0, sizeof(*sqe));
	return sqe;
}

static void __uringSubmitSqe(void) {
	msUringEvt* r = &_uringEvt;
	unsigned tail = atomic_load_explicit((_Atomic unsigned*)r->sqTail, memory_order_relaxed);
	r->sqArray[tail & *r->sqMask] = tail & *r->sqMask;
	atomic_store_explicit((_Atomic unsigned*)r->sqTail, tail + 1, memory_order_release);
	r->pending++;
}

/* Per-fd recv buffers — kernel writes directly here, MetaScript reads via msUringRecvData.
 * Heap-allocated on first use (4KB per fd, 1024 fds max = 4MB per thread). */
#define URING_MAX_FDS 1024
static _Thread_local char (*_uringRecvBufs)[4096] = NULL;

/* Per-fd response buffers — reused across requests (zero malloc after warmup).
 * msBuildResponseReuse writes header+body into these msStrings. */
static _Thread_local msString* _uringRespBufs = NULL;

static inline void __ensureRecvBufs(void) {
	if (_uringRecvBufs == NULL) {
		_uringRecvBufs = (char(*)[4096])calloc(URING_MAX_FDS, 4096);
	}
	if (_uringRespBufs == NULL) {
		_uringRespBufs = (msString*)calloc(URING_MAX_FDS, sizeof(msString));
	}
}

/* Submit accept */
static inline void msUringSubmitAccept(int32_t listenFd) {
	struct io_uring_sqe* sqe = __uringGetSqe();
	if (!sqe) return;
	sqe->opcode = IORING_OP_ACCEPT;
	sqe->fd = listenFd;
	sqe->user_data = URING_TAG(listenFd, URING_OP_ACCEPT);
	__uringSubmitSqe();
}

/* Submit recv — kernel writes into thread-local per-fd buffer.
 * After CQE, call msUringRecvData(fd, res) to get the data as msString. */
static inline void msUringSubmitRecv(int32_t fd, msString str, int32_t len) {
	(void)str;
	__ensureRecvBufs();
	struct io_uring_sqe* sqe = __uringGetSqe();
	if (!sqe) return;
	int slot = fd < URING_MAX_FDS ? fd : 0;
	sqe->opcode = IORING_OP_RECV;
	sqe->fd = fd;
	sqe->addr = (uint64_t)(uintptr_t)_uringRecvBufs[slot];
	sqe->len = (uint32_t)(len > 4096 ? 4096 : len);
	sqe->user_data = URING_TAG(fd, URING_OP_RECV);
	__uringSubmitSqe();
}

/* Submit send — uses msString's internal data pointer */
static inline void msUringSubmitSend(int32_t fd, msString data, int32_t len) {
	struct io_uring_sqe* sqe = __uringGetSqe();
	if (!sqe) return;
	sqe->opcode = IORING_OP_SEND;
	sqe->fd = fd;
	sqe->addr = data.p ? (uint64_t)(uintptr_t)data.p->data : 0;
	sqe->len = (uint32_t)len;
	sqe->user_data = URING_TAG(fd, URING_OP_SEND);
	__uringSubmitSqe();
}

/* Submit all pending + wait for completions. Returns number of events. */
static inline int32_t msUringWait(int32_t timeoutMs) {
	msUringEvt* r = &_uringEvt;
	int pending = r->pending;
	r->pending = 0;

	/* Submit + wait */
	int ret = __uring_enter(r->ringFd,
		pending > 0 ? (unsigned)pending : 0,
		1, IORING_ENTER_GETEVENTS);
	if (ret < 0) return 0;
	(void)timeoutMs;

	unsigned cqHead = atomic_load_explicit((_Atomic unsigned*)r->cqHead, memory_order_acquire);
	unsigned cqTail = atomic_load_explicit((_Atomic unsigned*)r->cqTail, memory_order_acquire);

	int32_t count = 0;
	while (cqHead != cqTail && count < URING_EVT_MAX) {
		struct io_uring_cqe* cqe = &r->cqes[cqHead & *r->cqMask];
		_uringEvtBuf[count].fd = URING_TAG_FD(cqe->user_data);
		_uringEvtBuf[count].op = URING_TAG_OP(cqe->user_data);
		_uringEvtBuf[count].res = (int32_t)cqe->res;
		count++;
		cqHead++;
	}

	atomic_store_explicit((_Atomic unsigned*)r->cqHead, cqHead, memory_order_release);
	return count;
}

/* Access event results */
static inline int32_t msUringEventFd(int32_t idx) { return _uringEvtBuf[idx].fd; }
static inline int32_t msUringEventOp(int32_t idx) { return _uringEvtBuf[idx].op; }
static inline int32_t msUringEventRes(int32_t idx) { return _uringEvtBuf[idx].res; }

/* Get recv data as msString (call after msUringWait for RECV events) */
static inline msString msUringRecvData(int32_t fd, int32_t bytesRecv) {
	if (bytesRecv <= 0 || _uringRecvBufs == NULL) return MS_EMPTY_STRING;
	int slot = fd < URING_MAX_FDS ? fd : 0;
	_uringRecvBufs[slot][bytesRecv] = '\0';
	return msStringNew(_uringRecvBufs[slot], (int64_t)bytesRecv);
}

/* Build response into per-fd reusable buffer — zero malloc after warmup.
 * Returns the msString (owned by per-fd pool, DO NOT free — stays alive until next request on this fd). */
static inline msString msUringBuildResponse(int32_t fd, int32_t status, msString statusText,
                                             msString contentType, msString body) {
	__ensureRecvBufs();
	int slot = fd < URING_MAX_FDS ? fd : 0;
	msBuildResponseReuse(&_uringRespBufs[slot], status, statusText, contentType, body);
	return _uringRespBufs[slot];
}

/* Find CRLFCRLF header terminator anywhere in recv buffer. Returns position
 * immediately AFTER the terminator (i.e. body start offset) or -1 if not yet
 * complete. Scanning the whole buffer is required: POST/PUT with body in the
 * first recv ends with body bytes, not \r\n\r\n. */
static inline int32_t msUringFastHeaderCheck(int32_t fd, int32_t bytesRecv) {
	if (bytesRecv < 4 || _uringRecvBufs == NULL) return -1;
	int slot = fd < URING_MAX_FDS ? fd : 0;
	const char* d = _uringRecvBufs[slot];
	for (int32_t i = 0; i <= bytesRecv - 4; i++) {
		if (d[i]=='\r' && d[i+1]=='\n' && d[i+2]=='\r' && d[i+3]=='\n')
			return i + 4;
	}
	return -1;
}

#else /* !__linux__ or MS_USE_EPOLL — stubs for macOS/fallback */

static inline int32_t msUringEvtInit(void) { return -1; }
static inline void msUringSubmitAccept(int32_t fd) { (void)fd; }
static inline void msUringSubmitRecv(int32_t fd, msString s, int32_t len) { (void)fd; (void)s; (void)len; }
static inline void msUringSubmitSend(int32_t fd, msString s, int32_t len) { (void)fd; (void)s; (void)len; }
static inline msString msUringRecvData(int32_t fd, int32_t n) { (void)fd; (void)n; return MS_EMPTY_STRING; }
static inline msString msUringBuildResponse(int32_t fd, int32_t st, msString stT, msString ct, msString b) {
	(void)fd; (void)st; (void)stT; (void)ct; (void)b; return MS_EMPTY_STRING;
}
static inline int32_t msUringFastHeaderCheck(int32_t fd, int32_t n) { (void)fd; (void)n; return -1; }
static inline int32_t msUringWait(int32_t t) { (void)t; return 0; }
static inline int32_t msUringEventFd(int32_t i) { (void)i; return -1; }
static inline int32_t msUringEventOp(int32_t i) { (void)i; return -1; }
static inline int32_t msUringEventRes(int32_t i) { (void)i; return -1; }

#endif /* platform */

#endif /* MS_EVENT_LOOP_URING_H */
