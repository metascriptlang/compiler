#define MSOS_BARE 1
#undef MS_HEAP_USE_MALLOC
#define MS_HEAP_USE_MALLOC 0
#undef MS_ALLOCATOR_H
#define msHeapAlloc msHeapProbeAlloc
#define msHeapCalloc msHeapProbeCalloc
#define msHeapRealloc msHeapProbeRealloc
#define msHeapRealloc0 msHeapProbeRealloc0
#define msHeapFree msHeapProbeFree
#define msHeapReset msHeapProbeReset
#define msHeapThreadRelease msHeapProbeThreadRelease
#define msHeapThreadFlush msHeapProbeThreadFlush
#define msHeapTryAllocPages msHeapProbeTryAllocPages
#define msHeapDeallocPages msHeapProbeDeallocPages
#define msHeapResetPages msHeapProbeResetPages
#define msHeapOutOfMemory msHeapProbeOutOfMemory
#include "../../../../runtime/allocator.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

static const char* phase;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "GUARD-FAIL allocator %s line %d: %s\n", phase, __LINE__, #x); abort(); } } while (0)

_Alignas(4096) static unsigned char ram[256 * 1024];
static unsigned char used[64];
static size_t requests;
static unsigned fatals;
static int expectingOOM;
static jmp_buf oom;

_Noreturn void msHeapOutOfMemory(void) {
	++fatals;
	if (expectingOOM) longjmp(oom, 1);
	fprintf(stderr, "GUARD-FAIL allocator %s: unexpected OOM\n", phase);
	abort();
}

void* msHeapTryAllocPages(size_t bytes) {
	++requests;
	CHECK(bytes && bytes % 4096 == 0);
	size_t pages = bytes / 4096;
	for (size_t i = 0; pages <= 64 && i <= 64 - pages; ++i) {
		size_t j = 0;
		while (j < pages && !used[i + j]) ++j;
		if (j == pages) {
			memset(used + i, 1, pages);
			memset(ram + i * 4096, 0xa5, bytes);
			return ram + i * 4096;
		}
	}
	return NULL;
}

void msHeapDeallocPages(void* p, size_t bytes) {
	size_t page = ((unsigned char*)p - ram) / 4096;
	CHECK(page + bytes / 4096 <= 64);
	memset(used + page, 0, bytes / 4096);
}

void msHeapResetPages(void) { memset(used, 0, sizeof(used)); }

static void checkBytes(const unsigned char* p, size_t size, unsigned char value) {
	for (size_t i = 0; i < size; ++i) CHECK(p[i] == value);
}

int32_t msAllocatorCoreChecks(void) {
	phase = "bootstrap";
	unsigned char* boot = msHeapAlloc(16);
	CHECK(boot && (uintptr_t)boot % 16 == 0);
	msHeapFree(boot);
	size_t pages = 0;
	for (size_t i = 0; i < 64; ++i) pages += used[i] != 0;
	CHECK(pages == 17 && requests == 2);

	phase = "right coalescing chain";
	unsigned char* a = msHeapAlloc(12000);
	unsigned char* b = msHeapAlloc(12000);
	unsigned char* c = msHeapAlloc(12000);
	size_t before = requests;
	msHeapFree(c);
	msHeapFree(b);
	msHeapFree(a);
	size_t mergedSize = 14 * 4096 - sizeof(msHeapBig);
	unsigned char* merged = msHeapAlloc(mergedSize);
	CHECK(merged == a && requests == before);
	memset(merged, 0x33, mergedSize);
	checkBytes(merged, mergedSize, 0x33);
	msHeapFree(merged);

	phase = "frees in rising address order join";
	msHeapChunk* home = msHeapPage(merged);
	unsigned char* ra = msHeapAlloc(12000);
	unsigned char* rb = msHeapAlloc(12000);
	unsigned char* rc = msHeapAlloc(12000);
	CHECK(msHeapPage(ra) == home && (unsigned char*)msHeapPage(rb) == (unsigned char*)home + 3 * 4096);
	CHECK((unsigned char*)msHeapPage(rc) == (unsigned char*)home + 6 * 4096);
	msHeapFree(ra);
	msHeapFree(rb);
	msHeapFree(rc);
	unsigned char* joined = msHeapAlloc(mergedSize);
	CHECK(joined == merged && requests == before);
	msHeapFree(joined);

	phase = "a join tells the right neighbour its new left size";
	ra = msHeapAlloc(12000);
	rb = msHeapAlloc(12000);
	rc = msHeapAlloc(12000);
	msHeapFree(rb);
	msHeapFree(ra);
	CHECK((msHeapPage(rc)->prevSize & ~(size_t)1) == 6 * 4096);
	msHeapFree(rc);
	joined = msHeapAlloc(mergedSize);
	CHECK(joined == merged && requests == before);
	msHeapFree(joined);

	phase = "a left size that is not the left chunk's joins nothing";
	ra = msHeapAlloc(12000);
	rb = msHeapAlloc(12000);
	rc = msHeapAlloc(12000);
	msHeapFree(ra);
	msHeapPage(rc)->prevSize = 6 * 4096 | 1;
	msHeapFree(rc);
	CHECK(home->size == 3 * 4096);
	msHeapFree(rb);
	joined = msHeapAlloc(mergedSize);
	CHECK(joined == merged && requests == before);
	msHeapFree(joined);

	phase = "left coalescing after a split names the neighbour";
	unsigned char* x = msHeapAlloc(2 * 4096 - sizeof(msHeapBig));
	unsigned char* y = msHeapAlloc(2 * 4096 - sizeof(msHeapBig));
	CHECK(x == a && y == a + 2 * 4096);
	msHeapFree(x);
	unsigned char* z = msHeapAlloc(4096 - sizeof(msHeapBig));
	CHECK(z == a);
	msHeapFree(y);
	unsigned char* w = msHeapAlloc(mergedSize);
	CHECK(w == a + 4096 && requests == before);
	msHeapFree(w);
	msHeapFree(z);
	CHECK(msHeapAlloc(mergedSize) == a && requests == before);
	msHeapFree(a);

	phase = "class and page boundaries";
	const size_t sizes[] = {0,1,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512,513,1007,1008,1009,1023,1024,1025,2015,2016,2017,2031,2032,2033,4015,4016,4017,4031,4032,4033,4047,4048,4049,4095,4096,4097,8191,8192,8193,16335,16336,16337};
	for (size_t i = 0; i < sizeof(sizes) / sizeof(*sizes); ++i) {
		unsigned char* p = msHeapAlloc(sizes[i]);
		CHECK(p && (uintptr_t)p % 16 == 0);
		memset(p, 0x71, sizes[i]);
		checkBytes(p, sizes[i], 0x71);
		msHeapFree(p);
	}

	phase = "arbitrary-order reuse";
	void* cells[128];
	for (unsigned round = 0; round < 20; ++round) {
		for (unsigned i = 0; i < 128; ++i) {
			cells[i] = msHeapAlloc(96);
			CHECK(cells[i]);
			memset(cells[i], (int)i, 96);
		}
		size_t reuseRequests = requests;
		for (unsigned i = 0; i < 128; ++i) {
			unsigned at = (i * 37) % 128;
			checkBytes(cells[at], 96, (unsigned char)at);
			msHeapFree(cells[at]);
		}
		for (unsigned i = 0; i < 128; ++i) cells[i] = msHeapAlloc(96);
		CHECK(requests == reuseRequests);
		for (unsigned i = 0; i < 128; ++i) msHeapFree(cells[(i * 53) % 128]);
	}

	phase = "dirty reuse is zeroed";
	unsigned char* dirty = msHeapAlloc(15);
	memset(dirty, 0xf7, 15);
	msHeapFree(dirty);
	unsigned char* clean = msHeapCalloc(3, 5);
	CHECK(clean == dirty);
	checkBytes(clean, 15, 0);
	msHeapFree(clean);

	phase = "realloc copies the block, not the caller's old size";
	unsigned char* whole = msHeapAlloc(100);
	for (unsigned i = 0; i < 100; ++i) whole[i] = (unsigned char)(i + 1);
	whole = msHeapRealloc(whole, 10, 5000);
	for (unsigned i = 0; i < 100; ++i) CHECK(whole[i] == (unsigned char)(i + 1));
	msHeapFree(whole);

	phase = "realloc keeps a block that still fits with at most half of it unused";
	unsigned char* fit = msHeapAlloc(100);
	CHECK(msHeapRealloc(fit, 100, 112) == fit);
	CHECK(msHeapRealloc(fit, 112, 56) == fit);
	unsigned char* moved = msHeapRealloc(fit, 56, 40);
	CHECK(moved != fit);
	msHeapFree(moved);

	phase = "realloc grows a big chunk into its free right neighbour";
	size_t twoPages = 2 * 4096 - sizeof(msHeapBig);
	unsigned char* grow = msHeapAlloc(twoPages);
	for (size_t i = 0; i < twoPages; ++i) grow[i] = (unsigned char)i;
	size_t growRequests = requests;
	unsigned char* grown = msHeapRealloc(grow, twoPages, 5 * 4096 - sizeof(msHeapBig));
	CHECK(grown == grow && requests == growRequests);
	CHECK(msHeapPage(grown)->size == 5 * 4096);
	for (size_t i = 0; i < twoPages; ++i) CHECK(grown[i] == (unsigned char)i);
	unsigned char* after = msHeapAlloc(4096 - sizeof(msHeapBig));
	CHECK(after == grown + 5 * 4096);
	msHeapFree(after);
	msHeapFree(grown);

	phase = "realloc prefix and zero-size";
	unsigned char* p = msHeapAlloc(512);
	for (unsigned i = 0; i < 512; ++i) p[i] = (unsigned char)i;
	p = msHeapRealloc(p, 512, 4097);
	for (unsigned i = 0; i < 512; ++i) CHECK(p[i] == (unsigned char)i);
	p = msHeapRealloc(p, 4097, 17);
	for (unsigned i = 0; i < 17; ++i) CHECK(p[i] == (unsigned char)i);
	CHECK(msHeapRealloc(p, 17, 0) == NULL);
	p = msHeapRealloc(NULL, 0, 32);
	memset(p, 0xb7, 32);
	expectingOOM = 1;

	phase = "calloc overflow";
	if (!setjmp(oom)) { msHeapCalloc(SIZE_MAX, 2); abort(); }
	phase = "allocation overflow";
	if (!setjmp(oom)) { msHeapAlloc(SIZE_MAX); abort(); }
	phase = "realloc overflow preserves original";
	if (!setjmp(oom)) { msHeapRealloc(p, 32, SIZE_MAX); abort(); }
	checkBytes(p, 32, 0xb7);
	phase = "realloc exhaustion preserves original";
	if (!setjmp(oom)) { msHeapRealloc(p, 32, sizeof(ram)); abort(); }
	checkBytes(p, 32, 0xb7);
	phase = "bounded exhaustion";
	if (!setjmp(oom)) { msHeapAlloc(sizeof(ram)); abort(); }
	CHECK(fatals == 5);
	expectingOOM = 0;
	msHeapFree(p);
	msHeapFree(NULL);

	phase = "reset";
	msHeapReset();
	CHECK(msHeapAlloc(16) == boot);
	msHeapReset();
	return 0;
}
