#include "runtime/allocator.h"

#if MS_HEAP_ENABLED

#include <stdint.h>
#include <stdbool.h>

#if !MS_HEAP_USE_MALLOC

_Static_assert((MS_HEAP_PAGE_SIZE & (MS_HEAP_PAGE_SIZE - 1)) == 0,
	"heap page size must be a power of two");

#if MS_HEAP_THREADS && defined(_WIN32)

#include <windows.h>

void* msHeapTryAllocPages(size_t bytes) {
	return VirtualAlloc(NULL, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
}

void msHeapDeallocPages(void* p, size_t bytes) {
	(void)bytes;
	if (!VirtualFree(p, 0, MEM_RELEASE)) __builtin_trap();
}

void msHeapResetPages(void) {}

#elif MS_HEAP_THREADS

#include <sys/mman.h>

void* msHeapTryAllocPages(size_t bytes) {
	void* p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	return p == MAP_FAILED ? NULL : p;
}

void msHeapDeallocPages(void* p, size_t bytes) {
	if (munmap(p, bytes) != 0) __builtin_trap();
}

void msHeapResetPages(void) {}

#elif defined(__wasm__)

extern unsigned char __heap_base;
static uintptr_t msHeapPageBase;
static uintptr_t msHeapPageEnd;

static bool msHeapPageStart(void) {
	if (msHeapPageBase != 0) return true;
	uintptr_t start = (uintptr_t)&__heap_base;
	if (start > UINTPTR_MAX - (MS_HEAP_PAGE_SIZE - 1)) return false;
	start = (start + MS_HEAP_PAGE_SIZE - 1) &
		~(uintptr_t)(MS_HEAP_PAGE_SIZE - 1);
	if (start == 0) start = MS_HEAP_PAGE_SIZE;
	msHeapPageBase = start;
	msHeapPageEnd = start;
	return true;
}

void* msHeapTryAllocPages(size_t bytes) {
	if (bytes == 0 || bytes > SIZE_MAX - (MS_HEAP_PAGE_SIZE - 1)) return NULL;
	bytes = (bytes + MS_HEAP_PAGE_SIZE - 1) & ~(size_t)(MS_HEAP_PAGE_SIZE - 1);
	if (!msHeapPageStart() || bytes > UINTPTR_MAX - msHeapPageEnd) return NULL;
	uintptr_t end = msHeapPageEnd + bytes;
	uint64_t capacity = (uint64_t)__builtin_wasm_memory_size(0) * 65536;
	if ((uint64_t)end > capacity) {
		size_t pages = (size_t)(((uint64_t)end - capacity + 65535) / 65536);
		if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) return NULL;
	}
	void* p = (void*)msHeapPageEnd;
	msHeapPageEnd = end;
	return p;
}

void msHeapDeallocPages(void* p, size_t bytes) {
	if (bytes > SIZE_MAX - (MS_HEAP_PAGE_SIZE - 1)) __builtin_trap();
	bytes = (bytes + MS_HEAP_PAGE_SIZE - 1) & ~(size_t)(MS_HEAP_PAGE_SIZE - 1);
	uintptr_t start = (uintptr_t)p;
	if (start >= msHeapPageBase && start <= msHeapPageEnd &&
		bytes == msHeapPageEnd - start) msHeapPageEnd = start;
}

void msHeapResetPages(void) {
	if (!msHeapPageStart()) msHeapOutOfMemory();
	msHeapPageEnd = msHeapPageBase;
}

#else

#ifndef MS_ARENA_SIZE
#define MS_ARENA_SIZE (256 * 1024)
#endif

_Static_assert(MS_ARENA_SIZE / MS_HEAP_PAGE_SIZE >= MS_HEAP_MIN_PAGES + 1,
	"MS_ARENA_SIZE must hold MS_HEAP_MIN_PAGES and allocator metadata");

_Alignas(MS_HEAP_PAGE_SIZE) static unsigned char msHeapPageStorage[MS_ARENA_SIZE];
static size_t msHeapPagePosition;

void* msHeapTryAllocPages(size_t bytes) {
	if (bytes == 0 || bytes > SIZE_MAX - (MS_HEAP_PAGE_SIZE - 1)) return NULL;
	bytes = (bytes + MS_HEAP_PAGE_SIZE - 1) & ~(size_t)(MS_HEAP_PAGE_SIZE - 1);
	if (bytes > sizeof(msHeapPageStorage) - msHeapPagePosition) return NULL;
	void* p = msHeapPageStorage + msHeapPagePosition;
	msHeapPagePosition += bytes;
	return p;
}

void msHeapDeallocPages(void* p, size_t bytes) {
	if (bytes > SIZE_MAX - (MS_HEAP_PAGE_SIZE - 1)) __builtin_trap();
	bytes = (bytes + MS_HEAP_PAGE_SIZE - 1) & ~(size_t)(MS_HEAP_PAGE_SIZE - 1);
	uintptr_t base = (uintptr_t)msHeapPageStorage;
	uintptr_t start = (uintptr_t)p;
	if (start >= base && start - base <= msHeapPagePosition &&
		bytes == msHeapPagePosition - (start - base)) {
		msHeapPagePosition = start - base;
	}
}

void msHeapResetPages(void) {
	msHeapPagePosition = 0;
}

#endif
#endif

#if MS_HEAP_THREADS
_Noreturn void msRaiseOutOfMemory(void);
_Noreturn void msHeapOutOfMemory(void) {
	msRaiseOutOfMemory();
}
#else
_Noreturn void msHeapOutOfMemory(void) {
	__builtin_trap();
}
#endif

#endif
