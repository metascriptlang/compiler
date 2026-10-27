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

#if !MS_IO_HAS_ENGINE
#elif defined(__linux__) && !defined(MS_USE_EPOLL)
  #include "engineUring.c"
#elif defined(_WIN32)
  #include "engineIOCP.c"
#else
  #include "engineReadiness.c"
#endif

#if MS_IO_HAS_ENGINE && !defined(_WIN32)
#include "runtime/promise/dispatch.h"

static _Thread_local int tlEngineWatchedFd = -1;

static int msIoPollThreadEngine(int timeoutMs, int wakeFd) {
	msIoEngine* e = msGetIoEngineIfExists();
	if (e == NULL) return 0;
	if (tlEngineWatchedFd != wakeFd) {
		msIoEngineAddWakeFd(e, wakeFd);
		tlEngineWatchedFd = wakeFd;
	}
	return msIoEnginePoll(e, timeoutMs);
}

__attribute__((constructor)) static void msIoInstallPollHook(void) { msSetIoPollHook(msIoPollThreadEngine); }
#endif
