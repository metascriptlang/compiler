/*
 * MetaScript Arena Allocator — Bump Allocation with Linked Pages
 *
 * O(1) allocation, O(1) bulk free. No per-object free, no refcount headers.
 * Design reference: Nim's gc_regions.nim MemRegion, yyjson's alc pool.
 *
 * Usage:
 *   msArena* a = msArenaCreate(65536);   // 64KB initial page
 *   void* p = msArenaAlloc(a, sizeof(Foo));
 *   msArenaDestroy(a);                   // frees everything
 */

#ifndef MS_ARENA_H
#define MS_ARENA_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* A single arena page (chunk). Data follows immediately after this header. */
typedef struct msArenaPage {
	struct msArenaPage* next;  /* linked list (newest first) */
	size_t capacity;           /* usable bytes in this page (excludes header) */
	size_t used;               /* bytes consumed so far */
} msArenaPage;

/* Arena: linked list of pages with bump allocation. */
typedef struct {
	msArenaPage* head;         /* current (most recent) page */
	size_t defaultPageSize;    /* size for new pages (doubles on growth) */
	size_t totalAllocated;     /* total bytes allocated across all pages */
} msArena;

/* Align size up to 8-byte boundary (natural alignment for pointers/doubles). */
static inline size_t msArenaAlign(size_t sz) {
	return (sz + 7) & ~(size_t)7;
}

/* Get pointer to page data (immediately after page header). */
static inline char* msArenaPageData(msArenaPage* page) {
	return (char*)(page + 1);
}

/* Create a new page with at least `minBytes` usable capacity. */
static inline msArenaPage* msArenaNewPage(size_t minBytes) {
	size_t total = sizeof(msArenaPage) + minBytes;
	msArenaPage* page = (msArenaPage*)malloc(total);
	page->next = NULL;
	page->capacity = minBytes;
	page->used = 0;
	return page;
}

/* Create arena with initial page. `pageSize` = default page capacity in bytes. */
static inline msArena* msArenaCreate(size_t pageSize) {
	if (pageSize < 256) pageSize = 256;
	msArena* a = (msArena*)malloc(sizeof(msArena));
	a->defaultPageSize = pageSize;
	a->totalAllocated = sizeof(msArena) + sizeof(msArenaPage) + pageSize;
	a->head = msArenaNewPage(pageSize);
	return a;
}

/*
 * Bump-allocate `size` bytes from the arena. Returns 8-byte aligned pointer.
 * If current page is full, allocates a new page (exponential growth).
 * Never returns NULL (aborts on OOM like malloc in practice).
 */
static inline void* msArenaAlloc(msArena* a, size_t size) {
	size_t aligned = msArenaAlign(size);
	msArenaPage* page = a->head;

	if (page->used + aligned <= page->capacity) {
		/* Fast path: bump within current page */
		void* ptr = msArenaPageData(page) + page->used;
		page->used += aligned;
		return ptr;
	}

	/* Slow path: new page with exponential growth */
	size_t newSize = a->defaultPageSize;
	if (newSize < aligned) newSize = aligned;
	a->defaultPageSize *= 2;  /* exponential growth (like Nim) */

	msArenaPage* newPage = msArenaNewPage(newSize);
	newPage->next = a->head;
	a->head = newPage;
	a->totalAllocated += sizeof(msArenaPage) + newSize;

	void* ptr = msArenaPageData(newPage) + newPage->used;
	newPage->used += aligned;
	return ptr;
}

/* Allocate and zero-initialize. */
static inline void* msArenaAllocZero(msArena* a, size_t size) {
	void* ptr = msArenaAlloc(a, size);
	memset(ptr, 0, size);
	return ptr;
}

/* Destroy arena: free all pages and the arena struct itself. */
static inline void msArenaDestroy(msArena* a) {
	if (a == NULL) return;
	msArenaPage* page = a->head;
	while (page != NULL) {
		msArenaPage* next = page->next;
		free(page);
		page = next;
	}
	free(a);
}

/* Reset arena: free all pages except the first, reset cursor.
 * Keeps the first page allocated for reuse (avoids malloc on next alloc). */
static inline void msArenaReset(msArena* a) {
	if (a == NULL) return;

	/* Walk to last page (the original first) */
	msArenaPage* page = a->head;
	msArenaPage* last = page;
	while (last->next != NULL) last = last->next;

	/* Free all pages except the last (original first) */
	while (page != last) {
		msArenaPage* next = page->next;
		free(page);
		page = next;
	}

	/* Reset the surviving page */
	last->next = NULL;
	last->used = 0;
	a->head = last;
	a->totalAllocated = sizeof(msArena) + sizeof(msArenaPage) + last->capacity;
}

#endif /* MS_ARENA_H */
