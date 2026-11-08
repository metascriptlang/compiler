#define MSOS_BARE 1
#undef MS_HEAP_USE_MALLOC
#define MS_HEAP_USE_MALLOC 0
#define MS_HEAP_FRESH_PAGES_ZERO 1
#undef MS_ALLOCATOR_H
#define msHeapAlloc msHeapZeroProbeAlloc
#define msHeapCalloc msHeapZeroProbeCalloc
#define msHeapRealloc msHeapZeroProbeRealloc
#define msHeapRealloc0 msHeapZeroProbeRealloc0
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

	phase = "realloc0 grown into a fresh neighbour zeroes only the slack and the absorbed header";
	unsigned char* filler = msHeapAlloc(57344 - sizeof(msHeapBig));
	CHECK(filler == bigA + 4096);
	size_t onePage = 4096 - sizeof(msHeapBig);
	unsigned char* g = msHeapCalloc(1, onePage);
	checkBytes(g, onePage, UNTOUCHED);
	memset(g, 0x5c, onePage);
	size_t want = 4 * 4096 - sizeof(msHeapBig);
	unsigned char* gg = msHeapRealloc0(g, 100, want);
	CHECK(gg == g);
	checkBytes(gg, 100, 0x5c);
	checkBytes(gg + 100, 4096 - 100, 0);
	checkBytes(gg + 4096, want - 4096, UNTOUCHED);

	phase = "realloc0 moved to fresh memory leaves the fresh tail alone";
	unsigned char* m = msHeapCalloc(1, 96);
	memset(m, 0x5c, 96);
	unsigned char* mm = msHeapRealloc0(m, 40, 9000);
	CHECK((unsigned char*)msHeapPage(mm) == (unsigned char*)msHeapPage(gg) + 4 * 4096);
	checkBytes(mm, 40, 0x5c);
	checkBytes(mm + 40, 56, 0);
	checkBytes(mm + 96, 9000 - 96, UNTOUCHED);

	phase = "realloc0 moved to reused memory zeroes the tail";
	memset(mm, 0xf7, 9000);
	msHeapFree(mm);
	unsigned char* r = msHeapCalloc(1, 96);
	CHECK(r == m);
	checkBytes(r, 96, 0);
	memset(r, 0x5c, 96);
	unsigned char* rr = msHeapRealloc0(r, 96, 9000);
	CHECK(msHeapPage(rr) == msHeapPage(mm));
	checkBytes(rr, 96, 0x5c);
	checkBytes(rr + 96, 9000 - 96, 0);

	phase = "realloc0 grown into a dirty neighbour zeroes the whole tail";
	unsigned char* d = msHeapAlloc(onePage);
	unsigned char* dn = msHeapAlloc(3 * 4096 - sizeof(msHeapBig));
	CHECK((unsigned char*)msHeapPage(d) == (unsigned char*)msHeapPage(rr) + 3 * 4096 && dn == d + 4096);
	memset(dn, 0xf7, 3 * 4096 - sizeof(msHeapBig));
	msHeapFree(dn);
	memset(d, 0x5c, onePage);
	unsigned char* dd = msHeapRealloc0(d, onePage, want);
	CHECK(dd == d);
	checkBytes(dd, onePage, 0x5c);
	checkBytes(dd + onePage, want - onePage, 0);
	msHeapFree(dd);
	msHeapFree(rr);
	msHeapFree(gg);
	msHeapFree(filler);

	phase = "consecutive big payloads with room to spare start at different page offsets";
	unsigned char* spreadA = msHeapAlloc(9000);
	unsigned char* spreadB = msHeapAlloc(9000);
	CHECK((uintptr_t)spreadA % 4096 != (uintptr_t)spreadB % 4096);
	CHECK((uintptr_t)spreadA % 64 == 48 && (uintptr_t)spreadB % 64 == 48);
	msHeapFree(spreadB);
	msHeapFree(spreadA);
	return 0;
}
