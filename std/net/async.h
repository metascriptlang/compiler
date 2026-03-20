/**
 * MetaScript Async Network Runtime — non-blocking socket I/O via selector
 *
 * Bridges msNet* blocking ops with the async dispatcher (kqueue/epoll).
 * Each async op: set non-blocking -> try immediate -> if EAGAIN register with selector -> complete future on ready.
 *
 * Value passing convention for Future<int32>:
 *   msFutureComplete(fut, (void*)(intptr_t)intVal)
 *   The .then callback receives void* which the C compiler implicitly converts to int32_t.
 *
 * Value passing convention for Future<string>:
 *   msString is 16 bytes (ptr+len) — pass as heap-allocated msString*.
 *   The .then callback receives msString* which needs dereferencing.
 */

#ifndef MS_STD_NET_ASYNC_H
#define MS_STD_NET_ASYNC_H

#include "native.h"
#include "std/core/promise/future.h"
#include "std/core/promise/dispatch.h"
#include "std/runtime/selector.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Set fd to non-blocking mode */
static inline int32_t msNetSetNonBlocking(int32_t fd) {
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0) return -1;
	return fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ? -1 : 0;
}

/* ===== Async Accept ===== */

typedef struct msAsyncAcceptCtx {
	int32_t listenFd;
	msFuture* fut;
} msAsyncAcceptCtx;

static void msAsyncAcceptReady(void* env);

/**
 * Async accept: returns Future<int32> resolving to client fd.
 * Listener fd must be non-blocking.
 */
static inline msFuture* msNetAcceptAsync(int32_t listenFd) {
	struct sockaddr_in client_addr;
	socklen_t client_len = sizeof(client_addr);
	int client_fd = accept(listenFd, (struct sockaddr*)&client_addr, &client_len);

	if (client_fd >= 0) {
		int flag = 1;
		setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
		msFuture* fut = msFutureCreate();
		msFutureComplete(fut, (void*)(intptr_t)client_fd);
		return fut;
	}

	if (errno != EAGAIN && errno != EWOULDBLOCK) {
		msFuture* fut = msFutureCreate();
		msFutureFail(fut, NULL);
		return fut;
	}

	/* EAGAIN — register with selector and wait */
	msFuture* readyFut = msFutureCreate();
	msDispatcher* d = msGetDispatcher();
	msSelectorRegister(d->selector, listenFd, MS_EVENT_READ, readyFut);

	msAsyncAcceptCtx* ctx = (msAsyncAcceptCtx*)malloc(sizeof(msAsyncAcceptCtx));
	ctx->listenFd = listenFd;
	ctx->fut = msFutureCreate();

	msFutureAddCallback(readyFut, (msClosure){
		.fn = (msClosureFn)msAsyncAcceptReady,
		.env = ctx
	});

	return ctx->fut;
}

static void msAsyncAcceptReady(void* env) {
	msAsyncAcceptCtx* ctx = (msAsyncAcceptCtx*)env;
	struct sockaddr_in client_addr;
	socklen_t client_len = sizeof(client_addr);
	int client_fd = accept(ctx->listenFd, (struct sockaddr*)&client_addr, &client_len);

	if (client_fd >= 0) {
		int flag = 1;
		setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
		msFutureComplete(ctx->fut, (void*)(intptr_t)client_fd);
	} else {
		msFutureFail(ctx->fut, NULL);
	}
	/* Re-register listener for next accept (edge-triggered needs re-arm) */
	free(ctx);
}

/* ===== Async Recv ===== */

typedef struct msAsyncRecvCtx {
	int32_t fd;
	int32_t maxBytes;
	msFuture* fut;
} msAsyncRecvCtx;

static void msAsyncRecvReady(void* env);

/**
 * Async recv: returns Future<string> resolving to received data.
 * fd must be non-blocking. Value is msString passed directly (16-byte struct as void*).
 */
static inline msFuture* msNetRecvAsync(int32_t fd, int32_t maxBytes) {
	if (maxBytes <= 0) {
		msFuture* fut = msFutureCreate();
		msFutureComplete(fut, NULL);
		return fut;
	}
	if (maxBytes > 16777216) maxBytes = 16777216;

	char* buf = (char*)malloc((size_t)maxBytes + 1);
	ssize_t received = recv(fd, buf, (size_t)maxBytes, 0);

	if (received > 0) {
		buf[received] = '\0';
		msString result = msStringNew(buf, (int64_t)received);
		free(buf);
		msFuture* fut = msFutureCreate();
		/* Store msString on heap — callback gets msString* */
		msString* boxed = (msString*)malloc(sizeof(msString));
		*boxed = result;
		msFutureComplete(fut, boxed);
		return fut;
	}

	free(buf);

	if (received == 0) {
		msFuture* fut = msFutureCreate();
		msFutureComplete(fut, NULL); /* connection closed */
		return fut;
	}

	if (errno != EAGAIN && errno != EWOULDBLOCK) {
		msFuture* fut = msFutureCreate();
		msFutureFail(fut, NULL);
		return fut;
	}

	/* EAGAIN — register with selector */
	msFuture* readyFut = msFutureCreate();
	msDispatcher* d = msGetDispatcher();
	msSelectorRegister(d->selector, fd, MS_EVENT_READ, readyFut);

	msAsyncRecvCtx* ctx = (msAsyncRecvCtx*)malloc(sizeof(msAsyncRecvCtx));
	ctx->fd = fd;
	ctx->maxBytes = maxBytes;
	ctx->fut = msFutureCreate();

	msFutureAddCallback(readyFut, (msClosure){
		.fn = (msClosureFn)msAsyncRecvReady,
		.env = ctx
	});

	return ctx->fut;
}

static void msAsyncRecvReady(void* env) {
	msAsyncRecvCtx* ctx = (msAsyncRecvCtx*)env;
	char* buf = (char*)malloc((size_t)ctx->maxBytes + 1);
	ssize_t received = recv(ctx->fd, buf, (size_t)ctx->maxBytes, 0);

	if (received > 0) {
		buf[received] = '\0';
		msString* boxed = (msString*)malloc(sizeof(msString));
		*boxed = msStringNew(buf, (int64_t)received);
		free(buf);
		msFutureComplete(ctx->fut, boxed);
	} else {
		free(buf);
		msFutureComplete(ctx->fut, NULL);
	}
	free(ctx);
}

/* ===== Async Send ===== */

static inline msFuture* msNetSendAsync(int32_t fd, msString data) {
	int32_t result = msNetSend(fd, data);
	msFuture* fut = msFutureCreate();
	msFutureComplete(fut, (void*)(intptr_t)result);
	return fut;
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_NET_ASYNC_H */
