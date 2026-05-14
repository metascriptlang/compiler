/*
 * MetaScript I/O Engine — Readiness Simulation Backend
 *
 * Wraps epoll/kqueue/poll selector to present completion-based semantics.
 * For each submitted I/O op: register fd → poll for readiness → perform syscall → complete future.
 *
 * Used on all platforms except when MS_USE_IO_URING is defined on Linux.
 */
/* Included from engineSelect.c — engine.h already included by parent */
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
	if (n <= 0) {
		result = MS_EMPTY_STRING;
	} else {
		req->buf[n] = '\0';
		result = msStringNew(req->buf, (int64_t)n);
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

	/* Decref the msString that msIoSendString incref'd */
	if (req->strRef.p) msStringDecref(req->strRef);
	req->strRef = MS_EMPTY_STRING;

	msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)bytesSent);
}

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
		}

		freeRequest(e, req);
	}

	return n;
}

/* end readiness backend */
