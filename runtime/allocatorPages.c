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

/* Chunks from two reservations can coalesce, and VirtualFree and VirtualAlloc refuse a range
 * that crosses a reservation, so both walk the range one reservation at a time. A failed
 * decommit leaves pages committed, which reuse commits again harmlessly. */
void msHeapDiscardPages(void* p, size_t bytes) {
	unsigned char* at = p;
	unsigned char* end = at + bytes;
	while (at < end) {
		MEMORY_BASIC_INFORMATION info;
		if (!VirtualQuery(at, &info, sizeof info)) return;
		unsigned char* stop = (unsigned char*)info.BaseAddress + info.RegionSize;
		if (stop > end) stop = end;
		if (info.State == MEM_COMMIT) VirtualFree(at, (size_t)(stop - at), MEM_DECOMMIT);
		at = stop;
	}
}

int msHeapReusePages(void* p, size_t bytes) {
	unsigned char* at = p;
	unsigned char* end = at + bytes;
	while (at < end) {
		MEMORY_BASIC_INFORMATION info;
		if (!VirtualQuery(at, &info, sizeof info)) return 0;
		unsigned char* stop = (unsigned char*)info.BaseAddress + info.RegionSize;
		if (stop > end) stop = end;
		if (info.State != MEM_COMMIT && !VirtualAlloc(at, (size_t)(stop - at), MEM_COMMIT, PAGE_READWRITE)) return 0;
		at = stop;
	}
	return 1;
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

#include <unistd.h>

/* The OS page can be larger than the heap's (16 KiB on Apple silicon), and madvise and mprotect
 * refuse a range that is not aligned to it, so a discard covers only the whole OS pages inside,
 * and a reuse every OS page the range touches: one a discard could not cover was never discarded. */
static int msHeapOsPages(void** p, size_t* bytes, int touched) {
	static uintptr_t cached;
	uintptr_t osPage = __atomic_load_n(&cached, __ATOMIC_RELAXED);
	if (!osPage) __atomic_store_n(&cached, osPage = (uintptr_t)sysconf(_SC_PAGESIZE), __ATOMIC_RELAXED);
	if (!*bytes) return 0;
	uintptr_t grow = touched ? osPage - 1 : 0;
	uintptr_t start = ((uintptr_t)*p + osPage - 1 - grow) & ~(osPage - 1);
	uintptr_t end = ((uintptr_t)*p + *bytes + grow) & ~(osPage - 1);
	if (end <= start) return 0;
	*p = (void*)start;
	*bytes = end - start;
	return 1;
}

#if MS_HEAP_DISCARD_STRICT
#include <string.h>
/* The strictest page source a discard can meet: discarded pages fault on any access until
 * reused, and come back holding bytes nobody wrote. */
void msHeapDiscardPages(void* p, size_t bytes) {
	memset(p, 0xa5, bytes);
	if (msHeapOsPages(&p, &bytes, 0) && mprotect(p, bytes, PROT_NONE) != 0) __builtin_trap();
}

int msHeapReusePages(void* p, size_t bytes) {
	return !msHeapOsPages(&p, &bytes, 1) || mprotect(p, bytes, PROT_READ | PROT_WRITE) == 0;
}
#elif defined(__APPLE__)
/* Only MADV_FREE_REUSABLE lowers a macOS task's footprint; MADV_FREE_REUSE accounts the pages
 * again before they are written, as libmalloc does. The contents are not cleared. */
void msHeapDiscardPages(void* p, size_t bytes) {
	if (msHeapOsPages(&p, &bytes, 0)) (void)madvise(p, bytes, MADV_FREE_REUSABLE);
}

int msHeapReusePages(void* p, size_t bytes) {
	if (msHeapOsPages(&p, &bytes, 1)) (void)madvise(p, bytes, MADV_FREE_REUSE);
	return 1;
}
#else
void msHeapDiscardPages(void* p, size_t bytes) {
	if (msHeapOsPages(&p, &bytes, 0)) (void)madvise(p, bytes, MADV_DONTNEED);
}

int msHeapReusePages(void* p, size_t bytes) {
	(void)p;
	(void)bytes;
	return 1;
}
#endif

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
#include <stdlib.h>
#include "runtime/core/errorf.h"
_Noreturn void msRaiseOutOfMemory(void);
_Noreturn void msHeapOutOfMemory(void) {
	msRaiseOutOfMemory();
}
_Noreturn void msHeapFreedTwice(void* p) {
	msErrorf("Error: msHeapFree of a block that is not allocated, at %p: it was freed before, or never came from this allocator\n", p);
	abort();
}
#else
_Noreturn void msHeapOutOfMemory(void) {
	__builtin_trap();
}
_Noreturn void msHeapFreedTwice(void* p) {
	(void)p;
	__builtin_trap();
}
#endif

#endif
