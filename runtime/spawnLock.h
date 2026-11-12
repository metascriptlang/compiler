#ifndef MS_SPAWN_LOCK_H
#define MS_SPAWN_LOCK_H

/* Defined once in runtime/core/system.c: every module that spawns must take the same lock. */
#ifdef _WIN32
#include <windows.h>
extern SRWLOCK _msSpawnCreateLock;
#else
#include <pthread.h>
extern pthread_mutex_t _msSpawnCreateLock;
#endif

#endif
