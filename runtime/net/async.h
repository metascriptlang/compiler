/*
 * MetaScript Async Socket I/O — Future-based non-blocking operations
 *
 * Registers fds with the dispatcher's selector, returns futures that
 * complete when I/O readiness is detected. Caller then performs the
 * actual non-blocking operation (guaranteed no EAGAIN after await).
 *
 * Pattern (reference parity: register + addRead):
 *   void* fut = msNetRegisterRead(fd);  // register + create future
 *   // ... event loop runs, selector detects READ ready ...
 *   // ... future completed automatically by msRunOnce ...
 *   // caller does: msNetRecvNonBlock(fd, maxBytes)
 */
#ifndef MS_NET_ASYNC_H
#define MS_NET_ASYNC_H

#include "runtime/promise/future.h"
#include "runtime/promise/dispatch.h"

/* Register fd for READ event. Returns Future completed when fd is readable.
 * One-shot: event loop unregisters fd after completing the future. */
static inline void* msNetRegisterRead(int fd) {
	msDispatcher* d = msGetDispatcher();
	msFuture_void* fut = msFutureCreateT(msFuture_void);
	msSelectorRegister(d->selector, fd, MS_EVENT_READ, fut);
	return fut;
}

/* Register fd for WRITE event. Returns Future completed when fd is writable.
 * One-shot: event loop unregisters fd after completing the future. */
static inline void* msNetRegisterWrite(int fd) {
	msDispatcher* d = msGetDispatcher();
	msFuture_void* fut = msFutureCreateT(msFuture_void);
	msSelectorRegister(d->selector, fd, MS_EVENT_WRITE, fut);
	return fut;
}

#endif /* MS_NET_ASYNC_H */
