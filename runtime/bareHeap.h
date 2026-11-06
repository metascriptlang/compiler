#ifndef MS_BARE_HEAP_H
#define MS_BARE_HEAP_H

#include <stdlib.h>
#include "runtime/allocator.h"

#if defined(MSOS_BARE) && !defined(MSOS_SOLANA) && !defined(MS_FREESTANDING_LIBC) && !MS_HEAP_USE_MALLOC
#define MS_BARE_HEAP_REDIRECT 1
void* msReallocNeedsOldSize(void* old, size_t size)
    __attribute__((error("realloc requires its old size in a bare build: call msRealloc(old, oldSize, newSize)")));
#define malloc(s)     msHeapAlloc(s)
#define calloc(n, s)  msHeapCalloc((n), (s))
#define realloc(p, s) msReallocNeedsOldSize((p), (s))
#define free(p)       msHeapFree(p)
#else
#define MS_BARE_HEAP_REDIRECT 0
#endif

#endif
