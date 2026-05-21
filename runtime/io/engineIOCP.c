/*
 * MetaScript I/O Engine — IOCP Backend (Windows)
 *
 * Native completion-based I/O via Windows I/O Completion Ports.
 * Mirrors io_uring backend: submit overlapped I/O → poll completions → complete futures.
 * No selector needed — IOCP is inherently completion-based.
 *
 * Included from engineSelect.c on Windows (automatic — no flags needed).
 */

/* Included from engineSelect.c — engine.h already included by parent */
#include <winsock2.h>
#include <mswsock.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#include <string.h>

/* AcceptEx function pointer (loaded dynamically via WSAIoctl) */
static LPFN_ACCEPTEX _fnAcceptEx = NULL;

static LPFN_ACCEPTEX getAcceptEx(SOCKET s) {
	if (_fnAcceptEx) return _fnAcceptEx;
	GUID guid = WSAID_ACCEPTEX;
	DWORD bytes;
	WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER,
	         &guid, sizeof(guid), &_fnAcceptEx, sizeof(_fnAcceptEx),
	         &bytes, NULL, NULL);
	return _fnAcceptEx;
}

/* ===== OVERLAPPED Wrapper ===== */
/* Embeds OVERLAPPED as first field so Windows can cast back.
 * Back-pointer to msIoRequest carries the request through the kernel. */

typedef struct msIocpOv {
	OVERLAPPED ov;         /* MUST be first field */
	msIoRequest* req;      /* back-pointer to our request */
	WSABUF wsaBuf;         /* buffer descriptor for WSARecv/WSASend */
	SOCKET acceptSocket;   /* pre-created socket for AcceptEx */
	char acceptBuf[128];   /* address buffer for AcceptEx */
} msIocpOv;

#define ENGINE_INIT_POOL 64

/* ===== Engine State ===== */

struct msIoEngine {
	HANDLE iocp;
	msIoRequest* freeList;
	int freeCount;
	msIocpOv* ovFreeList;
	int ovFreeCount;
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

/* ===== OVERLAPPED Wrapper Pool ===== */

static msIocpOv* allocOv(msIoEngine* e, msIoRequest* req) {
	msIocpOv* iov;
	if (e->ovFreeList != NULL) {
		iov = e->ovFreeList;
		e->ovFreeList = *(msIocpOv**)iov;  /* reuse first pointer-sized bytes as next */
		e->ovFreeCount--;
		memset(iov, 0, sizeof(msIocpOv));
	} else {
		iov = (msIocpOv*)calloc(1, sizeof(msIocpOv));
	}
	iov->req = req;
	return iov;
}

static void freeOv(msIoEngine* e, msIocpOv* iov) {
	*(msIocpOv**)iov = e->ovFreeList;  /* reuse first pointer-sized bytes as next */
	e->ovFreeList = iov;
	e->ovFreeCount++;
}

/* ===== IOCP Socket Association ===== */
/* A socket can only be associated with one IOCP port.
 * Calling CreateIoCompletionPort on an already-associated socket
 * returns NULL with ERROR_INVALID_PARAMETER — we treat that as success. */

static void iocpAssociate(msIoEngine* e, SOCKET s) {
	HANDLE h = CreateIoCompletionPort((HANDLE)s, e->iocp, 0, 0);
	(void)h; /* NULL is OK if socket was already associated */
}

/* ===== Create / Destroy ===== */

/* WSAStartup — ensure Winsock is initialized */
static void ensureWsa(void) {
	static int _wsaReady = 0;
	if (!_wsaReady) {
		WSADATA d;
		WSAStartup(MAKEWORD(2, 2), &d);
		_wsaReady = 1;
	}
}

msIoEngine* msIoEngineCreate(void) {
	ensureWsa();
	msIoEngine* e = (msIoEngine*)calloc(1, sizeof(msIoEngine));
	e->iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
	if (e->iocp == NULL) { free(e); return NULL; }
	/* Pre-allocate request + OVERLAPPED pools */
	for (int i = 0; i < ENGINE_INIT_POOL; i++) {
		msIoRequest* r = (msIoRequest*)calloc(1, sizeof(msIoRequest));
		r->next = e->freeList;
		e->freeList = r;
		e->freeCount++;

		msIocpOv* iov = (msIocpOv*)calloc(1, sizeof(msIocpOv));
		*(msIocpOv**)iov = e->ovFreeList;
		e->ovFreeList = iov;
		e->ovFreeCount++;
	}
	return e;
}

void msIoEngineDestroy(msIoEngine* e) {
	if (e == NULL) return;
	CloseHandle(e->iocp);
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
	SOCKET listenSock = (SOCKET)(intptr_t)listenFd;
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_ACCEPT;
	req->fd = listenFd;
	msFuture_int32* fut = msFutureCreateT(msFuture_int32);
	req->fut = fut;

	/* Allocate OVERLAPPED wrapper */
	msIocpOv* iov = allocOv(e, req);

	/* Associate listen socket with IOCP */
	iocpAssociate(e, listenSock);

	/* Pre-create accept socket (AcceptEx requirement) */
	iov->acceptSocket = WSASocketW(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED);
	if (iov->acceptSocket == INVALID_SOCKET) {
		msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1);
		freeRequest(e, req);
		freeOv(e, iov);
		return fut;
	}

	/* Load AcceptEx function pointer */
	LPFN_ACCEPTEX fnAcceptEx = getAcceptEx(listenSock);
	if (fnAcceptEx == NULL) {
		closesocket(iov->acceptSocket);
		msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1);
		freeRequest(e, req);
		freeOv(e, iov);
		return fut;
	}

	DWORD bytes = 0;
	DWORD addrLen = sizeof(struct sockaddr_in) + 16;
	BOOL ok = fnAcceptEx(listenSock, iov->acceptSocket,
	                     iov->acceptBuf, 0,
	                     addrLen, addrLen,
	                     &bytes, &iov->ov);
	if (!ok && WSAGetLastError() != ERROR_IO_PENDING) {
		closesocket(iov->acceptSocket);
		msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1);
		freeRequest(e, req);
		freeOv(e, iov);
		return fut;
	}

	return fut;
}

void* msIoRecv(msIoEngine* e, int fd, int32_t maxBytes) {
	SOCKET sock = (SOCKET)(intptr_t)fd;
	if (maxBytes <= 0) maxBytes = 4096;
	if (maxBytes > 16777216) maxBytes = 16777216;

	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_RECV;
	req->fd = fd;
	req->buf = (char*)malloc((size_t)maxBytes + 1);
	req->len = maxBytes;
	msFuture_msString* fut = msFutureCreateT(msFuture_msString);
	req->fut = fut;

	msIocpOv* iov = allocOv(e, req);
	iov->wsaBuf.buf = req->buf;
	iov->wsaBuf.len = (ULONG)maxBytes;

	iocpAssociate(e, sock);

	DWORD flags = 0;
	int rc = WSARecv(sock, &iov->wsaBuf, 1, NULL, &flags, &iov->ov, NULL);
	if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
		free(req->buf);
		req->buf = NULL;
		msFutureCompleteT(fut, MS_EMPTY_STRING);
		freeRequest(e, req);
		freeOv(e, iov);
		return fut;
	}

	return fut;
}

void* msIoSend(msIoEngine* e, int fd, const char* data, int32_t len) {
	SOCKET sock = (SOCKET)(intptr_t)fd;
	msIoRequest* req = allocRequest(e);
	req->op = MS_IO_SEND;
	req->fd = fd;
	req->buf = (char*)data;
	req->len = len;
	msFuture_int32* fut = msFutureCreateT(msFuture_int32);
	req->fut = fut;

	msIocpOv* iov = allocOv(e, req);
	iov->wsaBuf.buf = (char*)data;
	iov->wsaBuf.len = (ULONG)len;

	iocpAssociate(e, sock);

	int rc = WSASend(sock, &iov->wsaBuf, 1, NULL, 0, &iov->ov, NULL);
	if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
		msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1);
		freeRequest(e, req);
		freeOv(e, iov);
		return fut;
	}

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

	msIocpOv* iov = allocOv(e, req);
	iov->wsaBuf.buf = req->buf;
	iov->wsaBuf.len = (ULONG)req->len;

	iocpAssociate(e, (SOCKET)(intptr_t)fd);

	int rc = WSASend((SOCKET)(intptr_t)fd, &iov->wsaBuf, 1, NULL, 0, &iov->ov, NULL);
	if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
		if (data.p) msStringDecref(data);
		msFutureCompleteT((msFuture_int32*)fut, (int32_t)-1);
		freeRequest(e, req);
		freeOv(e, iov);
		return fut;
	}

	return fut;
}

/* ===== Process Completions ===== */

/* No-op: closesocket() queues ABORTED packet to the IOCP. */
void msIoEngineCancelFd(msIoEngine* e, int fd) {
	(void)e; (void)fd;
}

int msIoEnginePoll(msIoEngine* e, int timeoutMs) {
	OVERLAPPED_ENTRY entries[64];
	ULONG count = 0;

	BOOL ok = GetQueuedCompletionStatusEx(e->iocp, entries, 64, &count,
	                                       (DWORD)(timeoutMs >= 0 ? timeoutMs : INFINITE), FALSE);
	if (!ok || count == 0) return 0;

	int processed = 0;
	for (ULONG i = 0; i < count; i++) {
		OVERLAPPED* lpOv = entries[i].lpOverlapped;
		if (lpOv == NULL) continue;

		msIocpOv* iov = CONTAINING_RECORD(lpOv, msIocpOv, ov);
		msIoRequest* req = iov->req;
		DWORD bytes = entries[i].dwNumberOfBytesTransferred;

		switch (req->op) {
		case MS_IO_RECV: {
			msString recvResult;
			if (bytes == 0) {
				recvResult = MS_EMPTY_STRING;
			} else {
				req->buf[bytes] = '\0';
				recvResult = msStringNew(req->buf, (int64_t)bytes);
			}
			msFutureCompleteT((msFuture_msString*)req->fut, recvResult);
			free(req->buf);
			req->buf = NULL;
			break;
		}
		case MS_IO_ACCEPT: {
			SOCKET accepted = iov->acceptSocket;
			/* Finalize accepted socket — inherit listen socket properties */
			setsockopt(accepted, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
			           (const char*)&req->fd, sizeof(req->fd));
			/* Set TCP_NODELAY for low latency */
			int flag = 1;
			setsockopt(accepted, IPPROTO_TCP, TCP_NODELAY,
			           (const char*)&flag, sizeof(flag));
			msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)(intptr_t)accepted);
			break;
		}
		case MS_IO_SEND: {
			if (req->strRef.p) msStringDecref(req->strRef);
			req->strRef = MS_EMPTY_STRING;
			msFutureCompleteT((msFuture_int32*)req->fut, (int32_t)bytes);
			break;
		}
		case MS_IO_CLOSE: {
			closesocket((SOCKET)(intptr_t)req->fd);
			msFutureCompleteVoid(req->fut);
			break;
		}
		}

		freeRequest(e, req);
		freeOv(e, iov);
		processed++;
	}

	return processed;
}

/* end IOCP backend */
