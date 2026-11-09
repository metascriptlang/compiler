#ifndef MS_ALLOCATOR_H
#define MS_ALLOCATOR_H

#include <stddef.h>

#if defined(MSOS_BARE) && !defined(MSOS_SOLANA)
#define MS_HEAP_ENABLED 1
#define MS_HEAP_THREADS 0
#elif !defined(MSOS_BARE) && !defined(MSOS_SOLANA) && !defined(MSOS_WASM) && !defined(MSOS_EMCC) && !defined(__EMSCRIPTEN__) && !defined(__wasm__)
#define MS_HEAP_ENABLED 1
#define MS_HEAP_THREADS 1
#else
#define MS_HEAP_ENABLED 0
#define MS_HEAP_THREADS 0
#endif

#if MS_HEAP_ENABLED

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

#if defined(MS_HCR_CORE) || defined(MS_HCR_MODULE)
#define MS_HEAP_API
#else
#define MS_HEAP_API MS_LIB_PRIVATE
#endif

#define MS_HEAP_PAGE_SIZE 4096
#ifndef MS_HEAP_MIN_PAGES
#if MS_HEAP_THREADS
#define MS_HEAP_MIN_PAGES 128
#else
#define MS_HEAP_MIN_PAGES 16
#endif
#endif

#ifndef MS_HEAP_FRESH_PAGES_ZERO
#define MS_HEAP_FRESH_PAGES_ZERO MS_HEAP_THREADS
#endif

MS_HEAP_API void* msHeapAlloc(size_t size);
MS_HEAP_API void* msHeapCalloc(size_t count, size_t size);
MS_HEAP_API void* msHeapRealloc(void* p, size_t oldSize, size_t newSize);
MS_HEAP_API void* msHeapRealloc0(void* p, size_t oldSize, size_t newSize);
MS_HEAP_API void msHeapFree(void* p);
MS_HEAP_API void msHeapReset(void);
MS_HEAP_API void msHeapThreadRelease(void);
MS_HEAP_API void msHeapThreadFlush(void);

MS_HEAP_API void* msHeapTryAllocPages(size_t bytes);
MS_HEAP_API void msHeapDeallocPages(void* p, size_t bytes);
#if MS_HEAP_THREADS
MS_HEAP_API void msHeapReturnIdle(void);
MS_HEAP_API int msHeapIdlePending(void);
/* A thread about to block for waitMs (negative: until woken) caps the wait so it wakes when it
 * has idled long enough to return memory; it then calls msHeapReturnIdle while it holds no lock. */
MS_HEAP_API int msHeapIdleWaitMs(int waitMs);
MS_HEAP_API int msHeapIdleDue(void);
MS_HEAP_API void msHeapIdleBusy(void);
MS_HEAP_API void msHeapDiscardPages(void* p, size_t bytes);
MS_HEAP_API int msHeapReusePages(void* p, size_t bytes);
#endif
MS_HEAP_API void msHeapResetPages(void);
MS_HEAP_API _Noreturn void msHeapOutOfMemory(void);

#endif
#endif
