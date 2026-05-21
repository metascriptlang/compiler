/*
 * MetaScript I/O Engine — io_uring Backend (raw syscalls, zero dependency)
 *
 * Direct io_uring kernel interface via syscalls + mmap'd ring buffers.
 * No liburing needed — only <linux/io_uring.h> kernel header.
 * Zig-aio inspired: minimal wrapper for the subset we need.
 *
 * Included from engineSelect.c on Linux (automatic — no flags needed).
 */

/* Included from engineSelect.c — engine.h already included by parent */

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

/* ===== Raw Syscalls ===== */

static int io_uring_setup(unsigned entries, struct io_uring_params* p) {
	return (int)syscall(__NR_io_uring_setup, entries, p);
}

static int io_uring_enter(int fd, unsigned to_submit, unsigned min_complete, unsigned flags) {
	return (int)syscall(__NR_io_uring_enter, fd, to_submit, min_complete, flags, NULL, 0);
}

/* ===== Ring Buffer Management ===== */

#define URING_ENTRIES 256
#define ENGINE_INIT_POOL 64

struct msUring {
	int fd;

	/* Submission ring */
	unsigned* sqHead;
	unsigned* sqTail;
	unsigned* sqMask;
	unsigned* sqArray;
	struct io_uring_sqe* sqes;
	unsigned sqEntries;

	/* Completion ring */
	unsigned* cqHead;
	unsigned* cqTail;
	unsigned* cqMask;
	struct io_uring_cqe* cqes;
	unsigned cqEntries;
};

static int uringInit(struct msUring* ring) {
	struct io_uring_params params;
	memset(&params, 0, sizeof(params));

	int fd = io_uring_setup(URING_ENTRIES, &params);
	if (fd < 0) return -1;
	ring->fd = fd;
	ring->sqEntries = params.sq_entries;
	ring->cqEntries = params.cq_entries;

	/* mmap submission ring */
	size_t sqRingSz = params.sq_off.array + params.sq_entries * sizeof(unsigned);
	void* sqPtr = mmap(NULL, sqRingSz, PROT_READ | PROT_WRITE,
	                    MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
	if (sqPtr == MAP_FAILED) { close(fd); return -1; }

	ring->sqHead  = (unsigned*)((char*)sqPtr + params.sq_off.head);
	ring->sqTail  = (unsigned*)((char*)sqPtr + params.sq_off.tail);
	ring->sqMask  = (unsigned*)((char*)sqPtr + params.sq_off.ring_mask);
	ring->sqArray = (unsigned*)((char*)sqPtr + params.sq_off.array);

	/* mmap SQE array */
	size_t sqesSz = params.sq_entries * sizeof(struct io_uring_sqe);
	ring->sqes = (struct io_uring_sqe*)mmap(NULL, sqesSz, PROT_READ | PROT_WRITE,
	              MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
	if (ring->sqes == MAP_FAILED) { close(fd); return -1; }

	/* mmap completion ring */
	size_t cqRingSz = params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe);
	void* cqPtr = mmap(NULL, cqRingSz, PROT_READ | PROT_WRITE,
	                    MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
	if (cqPtr == MAP_FAILED) { close(fd); return -1; }

	ring->cqHead = (unsigned*)((char*)cqPtr + params.cq_off.head);
	ring->cqTail = (unsigned*)((char*)cqPtr + params.cq_off.tail);
	ring->cqMask = (unsigned*)((char*)cqPtr + params.cq_off.ring_mask);
	ring->cqes   = (struct io_uring_cqe*)((char*)cqPtr + params.cq_off.cqes);

	return 0;
}

static struct io_uring_sqe* uringGetSqe(struct msUring* ring) {
	unsigned tail = atomic_load_explicit((_Atomic unsigned*)ring->sqTail, memory_order_relaxed);
	unsigned head = atomic_load_explicit((_Atomic unsigned*)ring->sqHead, memory_order_acquire);
	if (tail - head >= ring->sqEntries) return NULL;
	struct io_uring_sqe* sqe = &ring->sqes[tail & *ring->sqMask];
	memset(sqe, 0, sizeof(*sqe));
	return sqe;
}

static void uringSubmitSqe(struct msUring* ring) {
	unsigned tail = atomic_load_explicit((_Atomic unsigned*)ring->sqTail, memory_order_relaxed);
	ring->sqArray[tail & *ring->sqMask] = tail & *ring->sqMask;
	/* Write barrier: ensure SQE data + sq_array entry visible before tail advance */
	atomic_store_explicit((_Atomic unsigned*)ring->sqTail, tail + 1, memory_order_release);
}

static int uringSubmit(struct msUring* ring) {
	return io_uring_enter(ring->fd, 1, 0, 0);
}

static int uringSubmitAndWait(struct msUring* ring, unsigned min_complete) {
	return io_uring_enter(ring->fd, 0, min_complete, IORING_ENTER_GETEVENTS);
}

/* ===== Engine State ===== */

struct msIoEngine {
	struct msUring ring;
	msIoRequest* freeList;
	int freeCount;
};

/* ===== Request Pool ===== */

static msIoRequest* allocRequest(msIoEngine* e) {
	if (e->freeList != NULL) {
		msIoRequest* r = e->freeList;
		e->freeList = r->next;
		e->freeCount--;
		memset(r, 0, sizeof(msIoRequest));
		return r;
	}
	return (msIoRequest*)calloc(1, sizeof(msIoRequest));
}

static void freeRequest(msIoEngine* e, msIoRequest* r) {
	r->next = e->freeList;
	e->freeList = r;
	e->freeCount++;
}

/* ===== Create / Destroy ===== */

msIoEngine* msIoEngineCreate(void) {
	msIoEngine* e = (msIoEngine*)calloc(1, sizeof(msIoEngine));
	if (uringInit(&e->ring) < 0) {
		free(e);
		return NULL;
	}
	for (int i = 0; i < ENGINE_INIT_POOL; i++) {
		msIoRequest* r = (msIoRequest*)calloc(1, sizeof(msIoRequest));
		r->next = e->freeList;
		e->freeList = r;
		e->freeCount++;
	}
	return e;
}

void msIoEngineDestroy(msIoEngine* e) {
	if (e == NULL) return;
	close(e->ring.fd);
	msIoRequest* r = e->freeList;
	while (r != NULL) {
		msIoRequest* next = r->next;
		free(r);
		r = next;
	}
	free(e);
}

/* ===== Thread-Local Singleton ===== */

static _Thread_local msIoEngine* _tlEngine = NULL;

msIoEngine* msGetIoEngine(void) {
	if (_tlEngine == NULL) {
		_tlEngine = msIoEngineCreate();
	}
	return _tlEngine;
}

msIoEngine* msGetIoEngineIfExists(void) {
	return _tlEngine;
}

/* ===== Submit Operations ===== */

void* msIoAccept(msIoEngine* e, int listenFd) {
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_ACCEPT;
	req->fd = listenFd;
	msFuture_int32* fut = msFutureCreateT(msFuture_int32);
	req->fut = fut;

	struct io_uring_sqe* sqe = uringGetSqe(&e->ring);
	if (sqe == NULL) { msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1); freeRequest(e, req); return fut; }
	sqe->opcode = IORING_OP_ACCEPT;
	sqe->fd = listenFd;
	sqe->user_data = (uint64_t)(uintptr_t)req;
	uringSubmitSqe(&e->ring);
	uringSubmit(&e->ring);
	return fut;
}

void* msIoRecv(msIoEngine* e, int fd, int32_t maxBytes) {
	if (maxBytes <= 0) maxBytes = 4096;
	if (maxBytes > 16777216) maxBytes = 16777216;
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_RECV;
	req->fd = fd;
	req->buf = (char*)malloc((size_t)maxBytes + 1);
	req->len = maxBytes;
	msFuture_msString* fut = msFutureCreateT(msFuture_msString);
	req->fut = fut;

	struct io_uring_sqe* sqe = uringGetSqe(&e->ring);
	if (sqe == NULL) { free(req->buf); msFutureCompleteT(fut, MS_EMPTY_STRING); freeRequest(e, req); return fut; }
	sqe->opcode = IORING_OP_RECV;
	sqe->fd = fd;
	sqe->addr = (uint64_t)(uintptr_t)req->buf;
	sqe->len = (uint32_t)maxBytes;
	sqe->user_data = (uint64_t)(uintptr_t)req;
	uringSubmitSqe(&e->ring);
	uringSubmit(&e->ring);
	return fut;
}

void* msIoSend(msIoEngine* e, int fd, const char* data, int32_t len) {
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_SEND;
	req->fd = fd;
	req->buf = (char*)data;
	req->len = len;
	msFuture_int32* fut = msFutureCreateT(msFuture_int32);
	req->fut = fut;

	struct io_uring_sqe* sqe = uringGetSqe(&e->ring);
	if (sqe == NULL) { msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1); freeRequest(e, req); return fut; }
	sqe->opcode = IORING_OP_SEND;
	sqe->fd = fd;
	sqe->addr = (uint64_t)(uintptr_t)data;
	sqe->len = (uint32_t)len;
	sqe->user_data = (uint64_t)(uintptr_t)req;
	uringSubmitSqe(&e->ring);
	uringSubmit(&e->ring);
	return fut;
}

void* msIoSendString(msIoEngine* e, int fd, msString data) {
	if (data.p) msStringIncref(data);
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_SEND;
	req->fd = fd;
	req->buf = data.p ? data.p->data : "";
	req->len = (int32_t)data.len;
	req->strRef = data;
	msFuture_int32* fut = msFutureCreateT(msFuture_int32);
	req->fut = fut;

	struct io_uring_sqe* sqe = uringGetSqe(&e->ring);
	if (sqe == NULL) {
		if (data.p) msStringDecref(data);
		msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1);
		freeRequest(e, req);
		return fut;
	}
	sqe->opcode = IORING_OP_SEND;
	sqe->fd = fd;
	sqe->addr = (uint64_t)(uintptr_t)req->buf;
	sqe->len = (uint32_t)req->len;
	sqe->user_data = (uint64_t)(uintptr_t)req;
	uringSubmitSqe(&e->ring);
	uringSubmit(&e->ring);
	return fut;
}

/* ===== Process Completions ===== */

/* No-op: Linux 5.5+ emits -ECANCELED CQE on fd close. */
void msIoEngineCancelFd(msIoEngine* e, int fd) {
	(void)e; (void)fd;
}

/* No-op: io_uring needs IORING_OP_POLL_ADD instead of selector registration. */
void msIoEngineAddWakeFd(msIoEngine* e, int fd) {
	(void)e; (void)fd;
}

int msIoEnginePoll(msIoEngine* e, int timeoutMs) {
	struct msUring* ring = &e->ring;

	/* Check for available CQEs */
	unsigned cqHead = atomic_load_explicit((_Atomic unsigned*)ring->cqHead, memory_order_acquire);
	unsigned cqTail = atomic_load_explicit((_Atomic unsigned*)ring->cqTail, memory_order_acquire);

	if (cqHead == cqTail) {
		if (timeoutMs == 0) return 0;
		int ret = uringSubmitAndWait(ring, 1);
		if (ret < 0) return 0;
		cqHead = atomic_load_explicit((_Atomic unsigned*)ring->cqHead, memory_order_acquire);
		cqTail = atomic_load_explicit((_Atomic unsigned*)ring->cqTail, memory_order_acquire);
		if (cqHead == cqTail) return 0;
	}

	int count = 0;
	while (cqHead != cqTail) {
		struct io_uring_cqe* cqe = &ring->cqes[cqHead & *ring->cqMask];
		msIoRequest* req = (msIoRequest*)(uintptr_t)cqe->user_data;
		int32_t res = cqe->res;

		cqHead++;
		count++;

		if (req == NULL) continue;

		switch (req->op) {
		case MS_IO_RECV: {
			msString recvResult;
			if (res <= 0) {
				recvResult = MS_EMPTY_STRING;
			} else {
				req->buf[res] = '\0';
				recvResult = msStringNew(req->buf, (int64_t)res);
			}
			msFutureCompleteT((msFuture_msString*)req->fut, recvResult);
			free(req->buf);
			req->buf = NULL;
			break;
		}
		case MS_IO_ACCEPT: {
			if (res >= 0) {
				int flag = 1;
				setsockopt(res, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
			}
			msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)res);
			break;
		}
		case MS_IO_SEND: {
			if (req->strRef.p) msStringDecref(req->strRef);
			req->strRef = MS_EMPTY_STRING;
			msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)res);
			break;
		}
		case MS_IO_CLOSE: {
			msFutureCompleteVoid(req->fut);
			break;
		}
		}

		freeRequest(e, req);
	}

	/* Advance CQ head — tell kernel we consumed these CQEs */
	atomic_store_explicit((_Atomic unsigned*)ring->cqHead, cqHead, memory_order_release);

	return count;
}

/* end io_uring backend */
