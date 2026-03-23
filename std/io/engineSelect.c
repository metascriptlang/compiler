/*
 * MetaScript I/O Engine — Backend Selection
 *
 * Compile-time selection:
 *   -DMS_USE_IO_URING (Linux only): native io_uring via raw syscalls (zero dependency)
 *   Default: readiness simulation (epoll/kqueue/poll → syscall → complete)
 */

#include "engine.h"

#if defined(__linux__) && defined(MS_USE_IO_URING)
  #include "engineUring.c"
#else
  #include "engineReadiness.c"
#endif
