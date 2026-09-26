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
#include <sys/eventfd.h>
#include <poll.h>
#include <errno.h>
#include <stdatomic.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <dirent.h>

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

/* Sentinel user_data for the wake-eventfd POLL_ADD (Amendment B / I16). The low bit is set, so
 * it can never equal a real msIoRequest* (calloc'd → ≥16-byte aligned), letting msIoEnginePoll
 * distinguish + re-arm the wake instead of dispatching it as a completion. */
#define MS_URING_WAKE_UD ((uint64_t)0xACC0DE17EFD1ULL)
#define MS_URING_TIMEOUT_UD ((uint64_t)0xACC0DE17EFD3ULL)

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
	int wakeFd;   /* eventfd for targeted cross-thread actor wake (Amendment B / I16); -1 = none */
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

/* Arm a oneshot POLL_ADD on the wake eventfd so a write() to it from any thread breaks this
 * engine's io_uring_enter (Amendment B / I16). Re-armed by msIoEnginePoll after each wake. */
static void uringArmWake(msIoEngine* e) {
	if (e->wakeFd < 0) return;
	struct io_uring_sqe* sqe = uringGetSqe(&e->ring);
	if (sqe == NULL) return;
	sqe->opcode = IORING_OP_POLL_ADD;
	sqe->fd = e->wakeFd;
	sqe->poll_events = POLLIN;
	sqe->user_data = MS_URING_WAKE_UD;
	uringSubmitSqe(&e->ring);
	uringSubmit(&e->ring);
}

/* ===== Create / Destroy ===== */

msIoEngine* msIoEngineCreate(void) {
	msIoEngine* e = (msIoEngine*)calloc(1, sizeof(msIoEngine));
	if (uringInit(&e->ring) < 0) {
		free(e);
		return NULL;
	}
	e->wakeFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);  /* armed only on serve engines, in AddWakeFd */
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
	msSchedWakeUnregisterEngine(e);  /* Amendment B: drop targeted-wake reg before freeing */
	if (e->wakeFd >= 0) close(e->wakeFd);
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

#define MS_FS_WATCH_BUFFER 65536
#define MS_FS_WATCH_MASK (IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO)

typedef struct msFsWatcher {
	int fd;
	int open;
	int recursive;
	int expanded;
	char* root;
	int* wds;
	char** dirs;
	int32_t count;
	int32_t cap;
	msIoRequest* pending;
} msFsWatcher;

static _Thread_local msFsWatcher* _msFsWatchers = NULL;
static _Thread_local int32_t _msFsWatcherCount = 0;
static _Thread_local int32_t _msFsWatchLastError = 0;

static int32_t fsWatchErrorCode(int err) {
	if (err == ENOENT) return 2;
	if (err == EACCES) return 5;
	if (err == ENOTDIR) return 267;
	return (int32_t)err;
}

int32_t msFsWatchLastError(void) {
	return _msFsWatchLastError;
}

static char* fsWatchJoin(const char* a, const char* b) {
	size_t la = strlen(a), lb = strlen(b);
	char* out = (char*)malloc(la + lb + 2);
	memcpy(out, a, la);
	size_t at = la;
	if (la > 0 && lb > 0) out[at++] = '/';
	memcpy(out + at, b, lb);
	out[at + lb] = 0;
	return out;
}

static int fsWatchAdd(msFsWatcher* w, const char* rel) {
	char* full = fsWatchJoin(w->root, rel);
	int wd = inotify_add_watch(w->fd, full, MS_FS_WATCH_MASK | IN_ONLYDIR);
	free(full);
	if (wd < 0) return wd;
	for (int32_t i = 0; i < w->count; i++) {
		if (w->wds[i] == wd) return wd;
	}
	if (w->count == w->cap) {
		w->cap = w->cap == 0 ? 16 : w->cap * 2;
		w->wds = (int*)realloc(w->wds, (size_t)w->cap * sizeof(int));
		w->dirs = (char**)realloc(w->dirs, (size_t)w->cap * sizeof(char*));
	}
	w->wds[w->count] = wd;
	w->dirs[w->count] = strdup(rel);
	w->count++;
	return wd;
}

static void fsWatchAddTree(msFsWatcher* w, const char* rel) {
	if (fsWatchAdd(w, rel) < 0) return;
	char* full = fsWatchJoin(w->root, rel);
	DIR* dir = opendir(full);
	free(full);
	if (dir == NULL) return;
	struct dirent* entry;
	while ((entry = readdir(dir)) != NULL) {
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
		char* child = fsWatchJoin(rel, entry->d_name);
		char* childFull = fsWatchJoin(w->root, child);
		struct stat info;
		if (lstat(childFull, &info) == 0 && S_ISDIR(info.st_mode)) fsWatchAddTree(w, child);
		free(childFull);
		free(child);
	}
	closedir(dir);
}

static const char* fsWatchDir(msFsWatcher* w, int wd) {
	for (int32_t i = 0; i < w->count; i++) {
		if (w->wds[i] == wd) return w->dirs[i];
	}
	return NULL;
}

static void fsWatchForget(msFsWatcher* w, int wd) {
	for (int32_t i = 0; i < w->count; i++) {
		if (w->wds[i] != wd) continue;
		free(w->dirs[i]);
		w->wds[i] = w->wds[w->count - 1];
		w->dirs[i] = w->dirs[w->count - 1];
		w->count--;
		return;
	}
}

static void fsWatchRelease(msFsWatcher* w) {
	if (w->fd >= 0) close(w->fd);
	w->fd = -1;
	for (int32_t i = 0; i < w->count; i++) free(w->dirs[i]);
	free(w->wds);
	free(w->dirs);
	free(w->root);
	w->wds = NULL;
	w->dirs = NULL;
	w->root = NULL;
	w->count = 0;
	w->cap = 0;
}

int32_t msFsWatchOpen(msIoEngine* e, msString path) {
	(void)e;
	_msFsWatchLastError = 0;
	char* root = (char*)malloc((size_t)path.len + 1);
	memcpy(root, path.p ? path.p->data : "", (size_t)path.len);
	root[path.len] = 0;
	struct stat info;
	if (stat(root, &info) != 0 || !S_ISDIR(info.st_mode)) {
		_msFsWatchLastError = fsWatchErrorCode(stat(root, &info) != 0 ? errno : ENOTDIR);
		free(root);
		return -1;
	}
	int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (fd < 0) {
		_msFsWatchLastError = fsWatchErrorCode(errno);
		free(root);
		return -1;
	}
	int32_t handle = _msFsWatcherCount;
	for (int32_t i = 0; i < _msFsWatcherCount; i++) {
		if (_msFsWatchers[i].fd < 0 && _msFsWatchers[i].pending == NULL) { handle = i; break; }
	}
	if (handle == _msFsWatcherCount) {
		_msFsWatchers = (msFsWatcher*)realloc(_msFsWatchers, (size_t)(_msFsWatcherCount + 1) * sizeof(msFsWatcher));
		_msFsWatcherCount++;
	}
	msFsWatcher* w = &_msFsWatchers[handle];
	memset(w, 0, sizeof(msFsWatcher));
	w->fd = fd;
	w->open = 1;
	w->root = root;
	if (fsWatchAdd(w, "") < 0) {
		_msFsWatchLastError = fsWatchErrorCode(errno);
		fsWatchRelease(w);
		return -1;
	}
	return handle;
}

static void fsWatchArm(msIoEngine* e, msFsWatcher* w, msIoRequest* req) {
	struct io_uring_sqe* sqe = uringGetSqe(&e->ring);
	if (sqe == NULL) {
		free(req->buf);
		req->buf = NULL;
		w->pending = NULL;
		msFutureCompleteT((msFuture_msString*)req->fut, msStringNew("*", 1));
		freeRequest(e, req);
		return;
	}
	w->pending = req;
	sqe->opcode = IORING_OP_POLL_ADD;
	sqe->fd = w->fd;
	sqe->poll_events = POLLIN;
	sqe->user_data = (uint64_t)(uintptr_t)req;
	uringSubmitSqe(&e->ring);
	uringSubmit(&e->ring);
}

void* msIoWatchNext(msIoEngine* e, int32_t handle, int32_t recursive) {
	msFuture_msString* fut = msFutureCreateT(msFuture_msString);
	if (handle < 0 || handle >= _msFsWatcherCount || !_msFsWatchers[handle].open) {
		msFutureCompleteT(fut, MS_EMPTY_STRING);
		return fut;
	}
	msFsWatcher* w = &_msFsWatchers[handle];
	w->recursive = recursive != 0;
	if (w->recursive && !w->expanded) {
		w->expanded = 1;
		fsWatchAddTree(w, "");
	}
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_WATCH;
	req->fd = w->fd;
	req->offset = handle;
	req->buf = (char*)malloc(MS_FS_WATCH_BUFFER);
	req->len = MS_FS_WATCH_BUFFER;
	req->fut = fut;
	fsWatchArm(e, w, req);
	return fut;
}

void msFsWatchClose(int32_t handle) {
	if (handle < 0 || handle >= _msFsWatcherCount) return;
	msFsWatcher* w = &_msFsWatchers[handle];
	if (!w->open) return;
	w->open = 0;
	if (w->pending == NULL) {
		fsWatchRelease(w);
		return;
	}
	msIoEngine* e = msGetIoEngine();
	struct io_uring_sqe* sqe = uringGetSqe(&e->ring);
	if (sqe == NULL) return;
	sqe->opcode = IORING_OP_ASYNC_CANCEL;
	sqe->fd = -1;
	sqe->addr = (uint64_t)(uintptr_t)w->pending;
	sqe->user_data = 0;
	uringSubmitSqe(&e->ring);
	uringSubmit(&e->ring);
}

static int fsWatchComplete(msIoEngine* e, msIoRequest* req, int32_t res) {
	msFsWatcher* w = &_msFsWatchers[req->offset];
	w->pending = NULL;
	if (res > 0 && w->open) {
		ssize_t got = read(w->fd, req->buf, (size_t)req->len);
		if (got < 0 && (errno == EAGAIN || errno == EINTR)) {
			fsWatchArm(e, w, req);
			return 1;
		}
		res = (int32_t)got;
	}
	if (res <= 0 || !w->open) {
		free(req->buf);
		req->buf = NULL;
		if (!w->open) fsWatchRelease(w);
		msFutureCompleteT((msFuture_msString*)req->fut, MS_EMPTY_STRING);
		return 0;
	}
	size_t cap = 256, used = 0;
	char* out = (char*)malloc(cap);
	int overflow = 0;
	for (int32_t at = 0; at < res;) {
		const struct inotify_event* ev = (const struct inotify_event*)(req->buf + at);
		at += (int32_t)(sizeof(struct inotify_event) + ev->len);
		if (ev->mask & IN_Q_OVERFLOW) { overflow = 1; continue; }
		if (ev->mask & IN_IGNORED) { fsWatchForget(w, ev->wd); continue; }
		const char* dir = fsWatchDir(w, ev->wd);
		if (dir == NULL || ev->len == 0 || ev->name[0] == 0) continue;
		char* rel = fsWatchJoin(dir, ev->name);
		if (w->recursive && (ev->mask & IN_ISDIR) && (ev->mask & (IN_CREATE | IN_MOVED_TO))) fsWatchAddTree(w, rel);
		size_t length = strlen(rel);
		while (used + length + 2 > cap) cap *= 2;
		out = (char*)realloc(out, cap);
		if (used > 0) out[used++] = '\n';
		memcpy(out + used, rel, length);
		used += length;
		free(rel);
	}
	if (!overflow && used == 0) {
		free(out);
		fsWatchArm(e, w, req);
		return 1;
	}
	msString changes = overflow ? msStringNew("*", 1) : msStringNew(out, (int64_t)used);
	free(out);
	free(req->buf);
	req->buf = NULL;
	msFutureCompleteT((msFuture_msString*)req->fut, changes);
	return 0;
}

/* ===== Process Completions ===== */

/* No-op: Linux 5.5+ emits -ECANCELED CQE on fd close. */
void msIoEngineCancelFd(msIoEngine* e, int fd) {
	(void)e; (void)fd;
}

void msIoEngineAddWakeFd(msIoEngine* e, int fd) {
	(void)fd;  /* external-fd chained-poll is PR-2's concern; the actor wake uses the eventfd below */
	if (e == NULL) return;
	/* Amendment B / I16: register this engine as its scheduler's targeted cross-thread actor-wake
	 * target, and arm the wake eventfd so msIoEngineWake can break io_uring_enter. Runs once per
	 * serve thread as it wires up — mirrors the readiness backend's msSchedWakeRegister. */
	extern MS_THREAD_LOCAL int msMySchedulerID;  /* actor.c */
	msSchedWakeRegister(msMySchedulerID, e);
	uringArmWake(e);
}

/* io_uring arm of the engine wake (Amendment B / I16): any thread write()s the eventfd; the
 * pre-armed POLL_ADD completes, breaking this engine's io_uring_enter. eventfd (not MSG_RING)
 * because the waker need not own a ring — verified on Linux 6.8: a ring-less write() wakes a
 * blocked io_uring_enter in ~one scheduling quantum. Mirrors msSelectorWake on readiness. */
void msIoEngineWake(msIoEngine* e) {
	if (e == NULL || e->wakeFd < 0) return;
	uint64_t one = 1;
	ssize_t w = write(e->wakeFd, &one, sizeof(one));
	(void)w;
}

int msIoEnginePoll(msIoEngine* e, int timeoutMs) {
	struct msUring* ring = &e->ring;

	/* Check for available CQEs */
	unsigned cqHead = atomic_load_explicit((_Atomic unsigned*)ring->cqHead, memory_order_acquire);
	unsigned cqTail = atomic_load_explicit((_Atomic unsigned*)ring->cqTail, memory_order_acquire);

	if (cqHead == cqTail) {
		if (timeoutMs == 0) return 0;
		struct { int64_t sec; long long nsec; } wait = { timeoutMs / 1000, (long long)(timeoutMs % 1000) * 1000000LL };
		struct io_uring_sqe* timer = timeoutMs > 0 ? uringGetSqe(ring) : NULL;
		if (timer != NULL) {
			timer->opcode = IORING_OP_TIMEOUT;
			timer->fd = -1;
			timer->addr = (uint64_t)(uintptr_t)&wait;
			timer->len = 1;
			timer->user_data = MS_URING_TIMEOUT_UD;
			uringSubmitSqe(ring);
			uringSubmit(ring);
		}
		int ret = uringSubmitAndWait(ring, 1);
		if (ret < 0) return 0;
		cqHead = atomic_load_explicit((_Atomic unsigned*)ring->cqHead, memory_order_acquire);
		cqTail = atomic_load_explicit((_Atomic unsigned*)ring->cqTail, memory_order_acquire);
		if (cqHead == cqTail) return 0;
	}

	int count = 0;
	while (cqHead != cqTail) {
		struct io_uring_cqe* cqe = &ring->cqes[cqHead & *ring->cqMask];

		if (cqe->user_data == MS_URING_TIMEOUT_UD) {
			cqHead++;
			continue;
		}

		if (cqe->user_data == MS_URING_WAKE_UD) {
			/* Targeted cross-thread wake fired (Amendment B / I16): drain the eventfd counter
			 * so the re-armed POLL_ADD won't fire immediately, then re-arm (POLL_ADD is oneshot).
			 * Not a user completion — it served only to break io_uring_enter; the serve loop
			 * drains actor mailboxes after poll returns. Skip without counting. */
			uint64_t drain;
			ssize_t dr = read(e->wakeFd, &drain, sizeof(drain)); (void)dr;
			cqHead++;
			uringArmWake(e);
			continue;
		}

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
		case MS_IO_WATCH: {
			if (fsWatchComplete(e, req, res)) continue;
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
