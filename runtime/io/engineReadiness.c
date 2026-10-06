/*
 * MetaScript I/O Engine — Readiness Simulation Backend
 *
 * Wraps epoll/kqueue/poll selector to present completion-based semantics.
 * For each submitted I/O op: register fd → poll for readiness → perform syscall → complete future.
 *
 * Used on all platforms except when MS_USE_IO_URING is defined on Linux.
 */
/* Included from engineSelect.c — engine.h already included by parent */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <errno.h>

#define ENGINE_INIT_FDMAP 1024
#define ENGINE_INIT_POOL  64

/* ===== Engine State ===== */

struct msIoEngine {
	msSelector* selector;
	msIoRequest** fdMap;      /* fd → pending request (O(1) lookup) */
	int fdMapCap;
	msIoRequest* freeList;    /* pre-allocated request pool */
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

/* ===== fdMap Management ===== */

static void growFdMap(msIoEngine* e, int fd) {
	if (fd < e->fdMapCap) return;
	int newCap = e->fdMapCap;
	while (newCap <= fd) newCap *= 2;
	e->fdMap = (msIoRequest**)realloc(e->fdMap, newCap * sizeof(msIoRequest*));
	memset(e->fdMap + e->fdMapCap, 0, (newCap - e->fdMapCap) * sizeof(msIoRequest*));
	e->fdMapCap = newCap;
}

/* ===== Create / Destroy ===== */

msIoEngine* msIoEngineCreate(void) {
	msIoEngine* e = (msIoEngine*)calloc(1, sizeof(msIoEngine));
	e->selector = msSelectorCreate();
	if (e->selector == NULL) { free(e); return NULL; }
	e->fdMapCap = ENGINE_INIT_FDMAP;
	e->fdMap = (msIoRequest**)calloc(ENGINE_INIT_FDMAP, sizeof(msIoRequest*));
	/* Pre-allocate request pool */
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
	msSelectorDestroy(e->selector);
	/* Free pool */
	msIoRequest* r = e->freeList;
	while (r != NULL) {
		msIoRequest* next = r->next;
		free(r);
		r = next;
	}
	free(e->fdMap);
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
	growFdMap(e, listenFd);
	e->fdMap[listenFd] = req;
	msSelectorRegister(e->selector, listenFd, MS_EVENT_READ, req);
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
	growFdMap(e, fd);
	e->fdMap[fd] = req;
	msSelectorRegister(e->selector, fd, MS_EVENT_READ, req);
	return fut;
}

void* msIoSend(msIoEngine* e, int fd, const char* data, int32_t len) {
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_SEND;
	req->fd = fd;
	req->buf = (char*)data;
	req->len = len;
	req->offset = 0;
	msFuture_int32* fut = msFutureCreateT(msFuture_int32);
	req->fut = fut;
	growFdMap(e, fd);
	e->fdMap[fd] = req;
	msSelectorRegister(e->selector, fd, MS_EVENT_WRITE, req);
	return fut;
}

/* Watch-only — no req, no fdMap entry. msIoEnginePoll skips it via the
 * req==NULL `continue` branch. Caller's poll drains the underlying fd. */
void msIoEngineAddWakeFd(msIoEngine* e, int fd) {
	if (e == NULL || fd < 0) return;
	msSelectorRegister(e->selector, fd, MS_EVENT_READ, NULL);
	/* Amendment B: this serve thread's engine is also its scheduler's targeted
	 * cross-thread actor wake target (this runs once per serve thread, as it wires up). */
	extern MS_THREAD_LOCAL int msMySchedulerID;  /* actor.c */
	msSchedWakeRegister(msMySchedulerID, e);
}

/* Readiness arm of the engine wake (Amendment B / I16): break a thread parked in
 * msIoEnginePoll → msSelectorPoll via the selector's EVFILT_USER/eventfd channel. */
void msIoEngineWake(msIoEngine* e) {
	if (e != NULL) msSelectorWake(e->selector);
}

void* msIoSendString(msIoEngine* e, int fd, msString data) {
	if (data.p) msStringIncref(data);  /* keep alive during async send */
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_SEND;
	req->fd = fd;
	req->buf = data.p ? data.p->data : "";
	req->len = (int32_t)data.len;
	req->offset = 0;
	req->strRef = data;  /* stored for decref on completion */
	msFuture_int32* fut = msFutureCreateT(msFuture_int32);
	req->fut = fut;
	growFdMap(e, fd);
	e->fdMap[fd] = req;
	msSelectorRegister(e->selector, fd, MS_EVENT_WRITE, req);
	return fut;
}

/* ===== Process Completions ===== */

static void completeRecv(msIoRequest* req) {
	ssize_t n;
	do {
		n = recv(req->fd, req->buf, (size_t)req->len, 0);
	} while (n < 0 && errno == EINTR);

	msString result;
	if (n > 0) {
		req->buf[n] = '\0';
		result = msStringNew(req->buf, (int64_t)n);
	} else if (n == 0) {
		/* Legitimate EOF — peer sent FIN. */
		result = MS_EMPTY_STRING;
	} else if (errno == EAGAIN || errno == EWOULDBLOCK) {
		/* Selector told us fd is readable but recv has no data — stale event
		 * or leaked filter. completeRecv must not silently treat this as EOF;
		 * that masks selector/registration bugs. Abort loudly so the cause is
		 * visible in CI/logs rather than surfacing as "connection closed after
		 * one keep-alive request" weeks later. */
		fprintf(stderr,
			"FATAL: completeRecv fd=%d got EAGAIN — selector fired spuriously. "
			"Likely a leaked filter in the kqueue/epoll registration path.\n",
			req->fd);
		abort();
	} else {
		/* Real socket error (ECONNRESET, EPIPE, EBADF, ...) — surface as EOF
		 * for the caller. The fd will be closed by the caller's close path. */
		result = MS_EMPTY_STRING;
	}
	/* Typed completion — no heap boxing, msFutureReadString reads inline value */
	msFutureCompleteT((msFuture_msString*)req->fut, result);
	free(req->buf);
	req->buf = NULL;
}

static void completeAccept(msIoRequest* req) {
	struct sockaddr_in addr;
	socklen_t addrLen = sizeof(addr);
	int cfd;
	do {
		cfd = accept(req->fd, (struct sockaddr*)&addr, &addrLen);
	} while (cfd < 0 && errno == EINTR);

	if (cfd >= 0) {
		int flag = 1;
		setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
	}
	msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)cfd);
}

static void completeSend(msIoRequest* req) {
	ssize_t bytesSent;
	do {
		bytesSent = send(req->fd, req->buf + req->offset, (size_t)(req->len - req->offset), 0);
	} while (bytesSent < 0 && errno == EINTR);

	if (bytesSent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
		/* Same rationale as completeRecv: selector said writable, but send
		 * blocked. That means our filter state is out of sync — abort loud. */
		fprintf(stderr,
			"FATAL: completeSend fd=%d got EAGAIN — selector fired spuriously. "
			"Likely a leaked filter in the kqueue/epoll registration path.\n",
			req->fd);
		abort();
	}

	/* Decref the msString that msIoSendString incref'd */
	if (req->strRef.p) msStringDecref(req->strRef);
	req->strRef = MS_EMPTY_STRING;

	msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)bytesSent);
}

/* msFutureCompleteT (not msFutureCancel) — Cancel skips callbacks so the
 * stepper would never resume; CompleteT with empty/-1 mimics peer-close
 * and the fiber takes its existing close path. */
void msIoEngineCancelFd(msIoEngine* e, int fd) {
	if (e == NULL || fd < 0 || fd >= e->fdMapCap) return;
	msIoRequest* req = e->fdMap[fd];
	if (req == NULL) return;
	e->fdMap[fd] = NULL;
	msSelectorUnregister(e->selector, fd);
	if (req->strRef.p != NULL) {
		msStringDecref(req->strRef);
		req->strRef = MS_EMPTY_STRING;
	}
	if (req->fut != NULL) {
		switch (req->op) {
		case MS_IO_RECV:
			msFutureCompleteT((msFuture_msString*)req->fut, MS_EMPTY_STRING);
			break;
		case MS_IO_ACCEPT:
		case MS_IO_SEND:
			msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)-1);
			break;
		case MS_IO_CLOSE:
			msFutureCompleteVoid(req->fut);
			break;
		}
	}
	if (req->buf != NULL) { free(req->buf); req->buf = NULL; }
	freeRequest(e, req);
}

#if defined(__APPLE__) && TARGET_OS_OSX
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <strings.h>
#include <sys/stat.h>

#define MS_FS_WATCH_LATENCY 0.05
#define MS_FS_WATCH_BATCH_LIMIT (1 << 20)
#define MS_FSE_SINCE_NOW 0xFFFFFFFFFFFFFFFFULL
#define MS_FSE_CREATE_WATCH_ROOT 0x00000004u
#define MS_FSE_CREATE_FILE_EVENTS 0x00000010u
#define MS_FSE_MUST_SCAN_SUB_DIRS 0x00000001u
#define MS_FSE_USER_DROPPED 0x00000002u
#define MS_FSE_KERNEL_DROPPED 0x00000004u
#define MS_FSE_ITEM_RENAMED 0x00000800u
#define MS_FSE_ITEM_IS_FILE 0x00010000u
#define MS_CF_UTF8 0x08000100u

typedef struct {
	long version;
	void* info;
	const void* (*retain)(const void*);
	void (*release)(const void*);
	const void* (*copyDescription)(const void*);
} msFseContext;

typedef void (*msFseCallback)(const void* stream, void* info, size_t count, void* paths,
	const uint32_t* flags, const uint64_t* ids);

static struct {
	void* (*streamCreate)(const void*, msFseCallback, msFseContext*, const void*, uint64_t, double, uint32_t);
	void (*setDispatchQueue)(void*, dispatch_queue_t);
	unsigned char (*start)(void*);
	void (*flushSync)(void*);
	void (*stop)(void*);
	void (*invalidate)(void*);
	void (*release)(void*);
	const void* (*stringCreate)(const void*, const char*, uint32_t);
	const void* (*arrayCreate)(const void*, const void**, long, const void*);
	void (*cfRelease)(const void*);
} msFse;
static pthread_once_t msFseOnce = PTHREAD_ONCE_INIT;
static int msFseLoaded = 0;

static void fsEventsLoad(void) {
	void* lib = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW | RTLD_LOCAL);
	if (lib == NULL) {
		fprintf(stderr, "std/fs/watch: cannot load CoreServices: %s\n", dlerror());
		return;
	}
	const char* names[] = {
		"FSEventStreamCreate", "FSEventStreamSetDispatchQueue", "FSEventStreamStart", "FSEventStreamFlushSync",
		"FSEventStreamStop", "FSEventStreamInvalidate", "FSEventStreamRelease",
		"CFStringCreateWithCString", "CFArrayCreate", "CFRelease",
	};
	void** slots[] = {
		(void**)&msFse.streamCreate, (void**)&msFse.setDispatchQueue, (void**)&msFse.start, (void**)&msFse.flushSync,
		(void**)&msFse.stop, (void**)&msFse.invalidate, (void**)&msFse.release,
		(void**)&msFse.stringCreate, (void**)&msFse.arrayCreate, (void**)&msFse.cfRelease,
	};
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		*slots[i] = dlsym(lib, names[i]);
		if (*slots[i] == NULL) {
			fprintf(stderr, "std/fs/watch: CoreServices has no %s\n", names[i]);
			return;
		}
	}
	msFseLoaded = 1;
}

typedef struct msFsWatcher {
	int readFd;
	int writeFd;
	int open;
	char* root;
	size_t rootLen;
	void* stream;
	dispatch_queue_t queue;
	msIoRequest* pending;
	pthread_mutex_t lock;
	int recursive;
	int overflow;
	char* batch;
	size_t used;
	size_t cap;
} msFsWatcher;

static _Thread_local msFsWatcher** _msFsWatchers = NULL;
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

static void fsWatchAppend(msFsWatcher* w, char kind, const char* rel) {
	size_t length = strlen(rel);
	if (w->used + length + 2 > MS_FS_WATCH_BATCH_LIMIT) {
		w->overflow = 1;
		return;
	}
	if (w->used + length + 2 > w->cap) {
		while (w->used + length + 2 > w->cap) w->cap = w->cap == 0 ? 256 : w->cap * 2;
		w->batch = (char*)realloc(w->batch, w->cap);
	}
	if (w->used > 0) w->batch[w->used++] = '\n';
	w->batch[w->used++] = kind;
	memcpy(w->batch + w->used, rel, length);
	w->used += length;
}

static void fsWatchCollect(const void* stream, void* info, size_t count, void* paths,
	const uint32_t* flags, const uint64_t* ids) {
	(void)stream;
	(void)ids;
	msFsWatcher* w = (msFsWatcher*)info;
	char** names = (char**)paths;
	pthread_mutex_lock(&w->lock);
	int wasEmpty = w->used == 0 && !w->overflow;
	for (size_t i = 0; i < count; i++) {
		if (flags[i] & (MS_FSE_MUST_SCAN_SUB_DIRS | MS_FSE_USER_DROPPED | MS_FSE_KERNEL_DROPPED)) {
			w->overflow = 1;
			continue;
		}
		const char* path = names[i];
		if (strncasecmp(path, w->root, w->rootLen) != 0 || path[w->rootLen] != '/') continue;
		const char* rel = path + w->rootLen + 1;
		if (rel[0] == 0 || (!w->recursive && strchr(rel, '/') != NULL)) continue;
		struct stat entry;
		int renamedIn = (flags[i] & MS_FSE_ITEM_IS_FILE) && (flags[i] & MS_FSE_ITEM_RENAMED) && lstat(path, &entry) == 0;
		fsWatchAppend(w, renamedIn ? 'w' : 'c', rel);
	}
	int signal = wasEmpty && (w->used > 0 || w->overflow);
	pthread_mutex_unlock(&w->lock);
	if (signal) {
		char one = 1;
		(void)write(w->writeFd, &one, 1);
	}
}

static void fsWatchQueueDrained(void* context) {
	(void)context;
}

static void fsWatchStop(msFsWatcher* w) {
	if (w->stream != NULL) {
		msFse.stop(w->stream);
		msFse.invalidate(w->stream);
		msFse.release(w->stream);
		w->stream = NULL;
	}
	if (w->queue != NULL) {
		dispatch_sync_f(w->queue, NULL, fsWatchQueueDrained);
		dispatch_release(w->queue);
		w->queue = NULL;
	}
}

static void fsWatchRelease(int32_t handle) {
	msFsWatcher* w = _msFsWatchers[handle];
	fsWatchStop(w);
	if (w->readFd >= 0) close(w->readFd);
	if (w->writeFd >= 0) close(w->writeFd);
	pthread_mutex_destroy(&w->lock);
	free(w->root);
	free(w->batch);
	free(w);
	_msFsWatchers[handle] = NULL;
}

int32_t msFsWatchOpen(msIoEngine* e, msString path) {
	(void)e;
	_msFsWatchLastError = 0;
	char* given = (char*)malloc((size_t)path.len + 1);
	memcpy(given, path.p ? path.p->data : "", (size_t)path.len);
	given[path.len] = 0;
	struct stat info;
	char resolved[PATH_MAX];
	int err = 0;
	if (stat(given, &info) != 0) err = errno;
	else if (!S_ISDIR(info.st_mode)) err = ENOTDIR;
	else if (realpath(given, resolved) == NULL) err = errno;
	free(given);
	if (err != 0) {
		_msFsWatchLastError = fsWatchErrorCode(err);
		return -1;
	}
	pthread_once(&msFseOnce, fsEventsLoad);
	if (!msFseLoaded) {
		_msFsWatchLastError = ENOSYS;
		return -1;
	}
	int fds[2];
	if (pipe(fds) != 0) {
		_msFsWatchLastError = fsWatchErrorCode(errno);
		return -1;
	}
	for (int i = 0; i < 2; i++) {
		fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
		fcntl(fds[i], F_SETFD, FD_CLOEXEC);
	}
	msFsWatcher* w = (msFsWatcher*)calloc(1, sizeof(msFsWatcher));
	w->readFd = fds[0];
	w->writeFd = fds[1];
	w->open = 1;
	w->root = strdup(resolved);
	w->rootLen = strlen(resolved);
	pthread_mutex_init(&w->lock, NULL);
	int32_t handle = _msFsWatcherCount;
	for (int32_t i = 0; i < _msFsWatcherCount; i++) {
		if (_msFsWatchers[i] == NULL) { handle = i; break; }
	}
	if (handle == _msFsWatcherCount) {
		_msFsWatchers = (msFsWatcher**)realloc(_msFsWatchers, (size_t)(_msFsWatcherCount + 1) * sizeof(msFsWatcher*));
		_msFsWatcherCount++;
	}
	_msFsWatchers[handle] = w;
	const void* root = msFse.stringCreate(NULL, w->root, MS_CF_UTF8);
	const void* roots = root != NULL ? msFse.arrayCreate(NULL, &root, 1, NULL) : NULL;
	msFseContext context = { 0, w, NULL, NULL, NULL };
	if (roots != NULL) {
		w->stream = msFse.streamCreate(NULL, fsWatchCollect, &context, roots, MS_FSE_SINCE_NOW, MS_FS_WATCH_LATENCY,
			MS_FSE_CREATE_WATCH_ROOT | MS_FSE_CREATE_FILE_EVENTS);
		msFse.cfRelease(roots);
	}
	if (root != NULL) msFse.cfRelease(root);
	if (w->stream == NULL) {
		_msFsWatchLastError = ENOMEM;
		fsWatchRelease(handle);
		return -1;
	}
	w->queue = dispatch_queue_create("metascript.fs.watch", DISPATCH_QUEUE_SERIAL);
	msFse.setDispatchQueue(w->stream, w->queue);
	if (!msFse.start(w->stream)) {
		_msFsWatchLastError = EIO;
		fsWatchRelease(handle);
		return -1;
	}
	msFse.flushSync(w->stream);
	return handle;
}

static void fsWatchArm(msIoEngine* e, msFsWatcher* w, msIoRequest* req) {
	w->pending = req;
	growFdMap(e, w->readFd);
	e->fdMap[w->readFd] = req;
	msSelectorRegister(e->selector, w->readFd, MS_EVENT_READ, req);
}

void* msIoWatchNext(msIoEngine* e, int32_t handle, int32_t recursive) {
	msFuture_msString* fut = msFutureCreateT(msFuture_msString);
	if (handle < 0 || handle >= _msFsWatcherCount || _msFsWatchers[handle] == NULL || !_msFsWatchers[handle]->open) {
		msFutureCompleteT(fut, MS_EMPTY_STRING);
		return fut;
	}
	msFsWatcher* w = _msFsWatchers[handle];
	pthread_mutex_lock(&w->lock);
	w->recursive = recursive != 0;
	pthread_mutex_unlock(&w->lock);
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_WATCH;
	req->fd = w->readFd;
	req->offset = handle;
	req->fut = fut;
	fsWatchArm(e, w, req);
	return fut;
}

int32_t msFsWriteSettled(msString path) {
	char* name = (char*)malloc((size_t)path.len + 1);
	if (path.len > 0) memcpy(name, path.p->data, (size_t)path.len);
	name[path.len] = 0;
	int absent = access(name, F_OK) != 0;
	free(name);
	return absent ? 1 : 0;
}

void msFsWatchClose(int32_t handle) {
	if (handle < 0 || handle >= _msFsWatcherCount || _msFsWatchers[handle] == NULL) return;
	msFsWatcher* w = _msFsWatchers[handle];
	if (!w->open) return;
	w->open = 0;
	fsWatchStop(w);
	if (w->pending == NULL) {
		fsWatchRelease(handle);
		return;
	}
	char one = 1;
	(void)write(w->writeFd, &one, 1);
}

static void fsWatchDrainWakeBeforeTakingBatch(msFsWatcher* w) {
	char drained[64];
	while (read(w->readFd, drained, sizeof(drained)) > 0) {}
}

static int fsWatchComplete(msIoEngine* e, msIoRequest* req) {
	msFsWatcher* w = _msFsWatchers[req->offset];
	w->pending = NULL;
	fsWatchDrainWakeBeforeTakingBatch(w);
	if (!w->open) {
		fsWatchRelease((int32_t)req->offset);
		msFutureCompleteT((msFuture_msString*)req->fut, MS_EMPTY_STRING);
		return 0;
	}
	pthread_mutex_lock(&w->lock);
	int overflow = w->overflow;
	int empty = w->used == 0;
	msString changes = overflow ? msStringNew("*", 1) : empty ? MS_EMPTY_STRING : msStringNew(w->batch, (int64_t)w->used);
	w->overflow = 0;
	w->used = 0;
	pthread_mutex_unlock(&w->lock);
	if (!overflow && empty) {
		fsWatchArm(e, w, req);
		return 1;
	}
	msFutureCompleteT((msFuture_msString*)req->fut, changes);
	return 0;
}
#endif

int msIoEnginePoll(msIoEngine* e, int timeoutMs) {
	msReadyEvent readyBuf[64];
	int n = msSelectorPoll(e->selector, timeoutMs, readyBuf, 64);
	if (n <= 0) return n;

	for (int i = 0; i < n; i++) {
		int fd = readyBuf[i].fd;
		/* Look up request: prefer userdata (kqueue/poll), fall back to fdMap (epoll) */
		msIoRequest* req = (msIoRequest*)readyBuf[i].userdata;
		if (req == NULL && fd >= 0 && fd < e->fdMapCap) {
			req = e->fdMap[fd];
		}
		if (req == NULL) continue;

		/* Clear fdMap + unregister (one-shot) */
		if (fd >= 0 && fd < e->fdMapCap) e->fdMap[fd] = NULL;
		msSelectorUnregister(e->selector, fd);

		/* Perform syscall + complete future */
		switch (req->op) {
		case MS_IO_RECV:   completeRecv(req);   break;
		case MS_IO_ACCEPT: completeAccept(req); break;
		case MS_IO_SEND:   completeSend(req);   break;
		case MS_IO_CLOSE:
			close(fd);
			msFutureCompleteVoid(req->fut);
			break;
#if defined(__APPLE__) && TARGET_OS_OSX
		case MS_IO_WATCH:
			if (fsWatchComplete(e, req)) continue;
			break;
#endif
		}

		freeRequest(e, req);
	}

	return n;
}

/* end readiness backend */
