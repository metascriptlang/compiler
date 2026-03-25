/*
 * MetaScript I/O Engine — Backend Selection
 *
 * Linux: io_uring by default (raw syscalls, zero dependency).
 * macOS/BSD: readiness simulation (kqueue).
 * Fallback: -DMS_USE_EPOLL forces epoll on Linux.
 */

#include "engine.h"

#if defined(__linux__) && !defined(MS_USE_EPOLL)
  #include "engineUring.c"
#elif defined(_WIN32)
  #include "engineIOCP.c"
#else
  #include "engineReadiness.c"
#endif
