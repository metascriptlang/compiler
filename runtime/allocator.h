#ifndef MS_ALLOCATOR_H
#define MS_ALLOCATOR_H

#include <stddef.h>

#if defined(MSOS_BARE) && !defined(MSOS_SOLANA)

#ifndef MS_HEAP_USE_MALLOC
#if defined(__SANITIZE_ADDRESS__)
#define MS_HEAP_USE_MALLOC 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define MS_HEAP_USE_MALLOC 1
#else
#define MS_HEAP_USE_MALLOC 0
#endif
#else
#define MS_HEAP_USE_MALLOC 0
#endif
#endif

#ifndef MS_LIB_PRIVATE
#if defined(_WIN32)
#define MS_LIB_PRIVATE
#else
#define MS_LIB_PRIVATE __attribute__((visibility("hidden")))
#endif
#endif

#define MS_HEAP_PAGE_SIZE 4096
#ifndef MS_HEAP_MIN_PAGES
#define MS_HEAP_MIN_PAGES 16
#endif

MS_LIB_PRIVATE void* msHeapAlloc(size_t size);
MS_LIB_PRIVATE void* msHeapCalloc(size_t count, size_t size);
MS_LIB_PRIVATE void* msHeapRealloc(void* p, size_t oldSize, size_t newSize);
MS_LIB_PRIVATE void msHeapFree(void* p);
MS_LIB_PRIVATE void msHeapReset(void);

MS_LIB_PRIVATE void* msHeapTryAllocPages(size_t bytes);
MS_LIB_PRIVATE void msHeapDeallocPages(void* p, size_t bytes);
MS_LIB_PRIVATE void msHeapResetPages(void);
MS_LIB_PRIVATE _Noreturn void msHeapOutOfMemory(void);

#endif
#endif
