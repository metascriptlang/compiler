#define MSOS_BARE 1
#undef MS_HEAP_USE_MALLOC
#define MS_HEAP_USE_MALLOC 0
#define MS_HEAP_FRESH_PAGES_ZERO 1
#undef MS_ALLOCATOR_H
#define msHeapAlloc msHeapZeroProbeAlloc
#define msHeapCalloc msHeapZeroProbeCalloc
#define msHeapRealloc msHeapZeroProbeRealloc
#define msHeapFree msHeapZeroProbeFree
#define msHeapReset msHeapZeroProbeReset
#define msHeapThreadRelease msHeapZeroProbeThreadRelease
#define msHeapTryAllocPages msHeapZeroProbeTryAllocPages
#define msHeapDeallocPages msHeapZeroProbeDeallocPages
#define msHeapResetPages msHeapZeroProbeResetPages
#define msHeapOutOfMemory msHeapZeroProbeOutOfMemory
#include "../../../../runtime/allocator.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char* phase;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "GUARD-FAIL allocator zero %s line %d: %s\n", phase, __LINE__, #x); abort(); } } while (0)

enum { UNTOUCHED = 0xa5 };

_Alignas(4096) static unsigned char ram[256 * 1024];
static size_t position;

void* msHeapTryAllocPages(size_t bytes) {
	if (bytes > sizeof(ram) - position) return NULL;
	void* p = ram + position;
	memset(p, UNTOUCHED, bytes);
	position += bytes;
	return p;
}

void msHeapDeallocPages(void* p, size_t bytes) { (void)p; (void)bytes; }
void msHeapResetPages(void) { position = 0; }

_Noreturn void msHeapOutOfMemory(void) {
	fprintf(stderr, "GUARD-FAIL allocator zero %s: unexpected OOM\n", phase);
	abort();
}

static void checkBytes(const unsigned char* p, size_t size, unsigned char value) {
	for (size_t i = 0; i < size; ++i) CHECK(p[i] == value);
}

int32_t msAllocatorZeroChecks(void) {
	phase = "a fresh small cell keeps the page source's bytes";
	unsigned char* first = msHeapCalloc(1, 96);
	checkBytes(first, 96, UNTOUCHED);
	unsigned char* second = msHeapCalloc(1, 96);
	CHECK(second == first + 96);
	checkBytes(second, 96, UNTOUCHED);

	phase = "a freed small cell is zeroed on reuse";
	memset(first, 0xf7, 96);
	msHeapFree(first);
	unsigned char* again = msHeapCalloc(1, 96);
	CHECK(again == first);
	checkBytes(again, 96, 0);

	phase = "a fresh big chunk and its split remainder keep the page source's bytes";
	size_t bigSize = 3 * 4096 - sizeof(msHeapBig);
	unsigned char* bigA = msHeapCalloc(1, bigSize);
	checkBytes(bigA, bigSize, UNTOUCHED);
	unsigned char* bigB = msHeapCalloc(1, bigSize);
	CHECK(bigB == bigA + 3 * 4096);
	checkBytes(bigB, bigSize, UNTOUCHED);

	phase = "a freed big chunk is zeroed on reuse";
	memset(bigA, 0xf7, bigSize);
	msHeapFree(bigA);
	unsigned char* bigAgain = msHeapCalloc(1, bigSize);
	CHECK(bigAgain == bigA);
	checkBytes(bigAgain, bigSize, 0);

	phase = "a coalesced chunk is zeroed whole, the absorbed header included";
	memset(bigAgain, 0xf7, bigSize);
	memset(bigB, 0xf7, bigSize);
	msHeapFree(bigB);
	msHeapFree(bigAgain);
	size_t mergedSize = 6 * 4096 - sizeof(msHeapBig);
	unsigned char* merged = msHeapCalloc(1, mergedSize);
	CHECK(merged == bigA);
	checkBytes(merged, mergedSize, 0);

	phase = "a small chunk carved from a reused page zeroes its first and later cells";
	msHeapFree(merged);
	unsigned char* page = msHeapAlloc(4096 - sizeof(msHeapBig));
	CHECK(page == bigA);
	memset(page, 0xf7, 4096 - sizeof(msHeapBig));
	msHeapFree(page);
	unsigned char* cell = msHeapCalloc(1, 208);
	CHECK(msHeapPage(cell) == msHeapPage(page));
	checkBytes(cell, 208, 0);
	unsigned char* next = msHeapCalloc(1, 208);
	CHECK(next == cell + 208);
	checkBytes(next, 208, 0);

	phase = "plain allocation leaves memory as it is";
	unsigned char* plain = msHeapAlloc(96);
	CHECK(plain == second + 96);
	checkBytes(plain, 96, UNTOUCHED);
	return 0;
}
