/*
 * MetaScript I/O Engine — Backend Selection
 *
 * Linux: io_uring by default (raw syscalls, zero dependency).
 * macOS/BSD: readiness simulation (kqueue).
 * Fallback: -DMS_USE_EPOLL forces epoll on Linux.
 * Emscripten/WASI: no engine; std/fs/watch reports unsupported.
 */

#include "engine.h"
#include "runtime/promise/pool.h"

#if MS_IO_HAS_ENGINE && !defined(_WIN32)
#include "runtime/promise/dispatch.h"

static int msIoPollThreadEngine(void) {
	msIoEngine* e = msGetIoEngineIfExists();
	return e == NULL ? 0 : msIoEnginePoll(e, 0);
}

static void msIoEngineCreated(int engineFd) { msDispatcherWatchIoEngine(engineFd, msIoPollThreadEngine); }
#endif


#if !MS_IO_HAS_ENGINE
#elif defined(__linux__) && !defined(MS_USE_EPOLL)
  #include "engineUring.c"
#elif defined(_WIN32)
  #include "engineIOCP.c"
#else
  #include "engineReadiness.c"
#endif
