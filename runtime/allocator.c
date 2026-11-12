#include "allocator.h"
#include "runtime/core/errorf.h"

#if MS_HEAP_ENABLED

#include <stdint.h>

static size_t msHeapProduct(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) msHeapOutOfMemory();
    return count * size;
}

#if MS_HEAP_USE_MALLOC && MS_HEAP_THREADS

#include <stdlib.h>
#include <stdio.h>

typedef struct { uint64_t tag; uint64_t size; } msHeapPairing;
#define MS_HEAP_PAIRING_TAG 0x6d734865617054aaull

static void* msHeapTag(msHeapPairing* block, size_t size) {
    if (!block) msHeapOutOfMemory();
    block->tag = MS_HEAP_PAIRING_TAG;
    block->size = size;
    return block + 1;
}

static msHeapPairing* msHeapUntag(void* p) {
    msHeapPairing* block = (msHeapPairing*)p - 1;
    if (block->tag != MS_HEAP_PAIRING_TAG) {
        msErrorf("Error: msHeapFree of %p, which the managed allocator did not allocate\n", p);
        abort();
    }
    block->tag = 0;
    return block;
}

extern void msThreadAttach(void);
static _Thread_local int msHeapAttached;

static void* msHeapTagHere(msHeapPairing* block, size_t size) {
    if (!msHeapAttached) {
        msHeapAttached = 1;
        msThreadAttach();
    }
    return msHeapTag(block, size);
}

void* msHeapAlloc(size_t size) {
    if (size > SIZE_MAX - sizeof(msHeapPairing)) msHeapOutOfMemory();
    return msHeapTagHere(malloc(sizeof(msHeapPairing) + size), size);
}

void* msHeapCalloc(size_t count, size_t size) {
    size_t bytes = msHeapProduct(count, size);
    if (bytes > SIZE_MAX - sizeof(msHeapPairing)) msHeapOutOfMemory();
    return msHeapTagHere(calloc(sizeof(msHeapPairing) + bytes, 1), bytes);
}

void* msHeapRealloc(void* p, size_t oldSize, size_t newSize) {
    (void)oldSize;
    if (!newSize) {
        if (p) free(msHeapUntag(p));
        return NULL;
    }
    if (newSize > SIZE_MAX - sizeof(msHeapPairing)) msHeapOutOfMemory();
    msHeapPairing* block = p ? msHeapUntag(p) : NULL;
    return msHeapTagHere(realloc(block, sizeof(msHeapPairing) + newSize), newSize);
}

void* msHeapRealloc0(void* p, size_t oldSize, size_t newSize) {
    unsigned char* result = msHeapRealloc(p, oldSize, newSize);
    if (newSize > oldSize) __builtin_memset(result + oldSize, 0, newSize - oldSize);
    return result;
}

void msHeapFree(void* p) { if (p) free(msHeapUntag(p)); }
void msHeapReset(void) {}
void msHeapThreadRelease(void) { msHeapAttached = 0; }
void msHeapThreadFlush(void) {}
#if MS_HEAP_THREADS
void msHeapReturnIdle(void) {}
void msHeapReturnUnused(void) {}
int msHeapIdleWaitMs(int waitMs) { return waitMs; }
#endif

#elif MS_HEAP_USE_MALLOC

#include <stdlib.h>

void* msHeapAlloc(size_t size) {
    void* p = malloc(size);
    if (!p && size) msHeapOutOfMemory();
    return p;
}

void* msHeapCalloc(size_t count, size_t size) {
    size_t bytes = msHeapProduct(count, size);
    void* p = calloc(bytes, 1);
    if (!p && bytes) msHeapOutOfMemory();
    return p;
}

void* msHeapRealloc(void* p, size_t oldSize, size_t newSize) {
    (void)oldSize;
    void* result = realloc(p, newSize);
    if (!result && newSize) msHeapOutOfMemory();
    return result;
}

void* msHeapRealloc0(void* p, size_t oldSize, size_t newSize) {
    unsigned char* result = msHeapRealloc(p, oldSize, newSize);
    if (newSize > oldSize) __builtin_memset(result + oldSize, 0, newSize - oldSize);
    return result;
}

void msHeapFree(void* p) { free(p); }
void msHeapReset(void) {}
void msHeapThreadRelease(void) {}
void msHeapThreadFlush(void) {}
#if MS_HEAP_THREADS
void msHeapReturnIdle(void) {}
void msHeapReturnUnused(void) {}
int msHeapIdleWaitMs(int waitMs) { return waitMs; }
#endif

#else

#if MS_HEAP_THREADS
#include <string.h>
#define msHeapZero(p, size) memset((p), 0, (size))
#define msHeapCopy(dest, source, size) memcpy((dest), (source), (size))
#else
static void msHeapZero(void* p, size_t size) {
    unsigned char* out = p;
    for (size_t i = 0; i < size; ++i) out[i] = 0;
}

static void msHeapCopy(void* dest, const void* source, size_t size) {
    unsigned char* out = dest;
    const unsigned char* in = source;
    for (size_t i = 0; i < size; ++i) out[i] = in[i];
}
#endif

enum {
    MS_HEAP_ALIGN = 16,
    MS_HEAP_FL_OFFSET = 6,
    MS_HEAP_FL_COUNT = 24,
    MS_HEAP_SL_COUNT = 32,
    MS_HEAP_TRUNK_SHIFT = 9,
    MS_HEAP_TRUNK_BITS = 512,
    MS_HEAP_WORD_BITS = sizeof(uintptr_t) * 8,
    MS_HEAP_SMALL_CLASSES = MS_HEAP_PAGE_SIZE / MS_HEAP_ALIGN,
    MS_HEAP_MAX_REMOTE_BIG_STEPS = 20,
    MS_HEAP_REMOTE_BATCH_BYTES = 16384,
    MS_HEAP_DISCARD_MIN_BYTES = 65536,
    MS_HEAP_RETURN_AFTER_MS = 10000,
    MS_HEAP_RETURN_STEP_MS = 1000,
    MS_HEAP_TURN_CELLS = 16384,
    MS_HEAP_TURN_PAGES = 4096
};

#define MS_HEAP_MAX_BIG (((size_t)1 << 30) - ((size_t)1 << 24))
#define MS_HEAP_SPREAD_STEP 64u
#define MS_HEAP_SPREAD_SLOTS 64u
#define MS_HEAP_SPREAD_STRIDE 27u

_Static_assert(MS_HEAP_MIN_PAGES > 0, "MS_HEAP_MIN_PAGES must be positive");
_Static_assert(MS_HEAP_MIN_PAGES <= MS_HEAP_MAX_BIG / MS_HEAP_PAGE_SIZE,
               "MS_HEAP_MIN_PAGES exceeds the chunk matrix");

typedef struct msHeapRegion msHeapRegion;
typedef struct msHeapHandle msHeapHandle;
typedef struct msHeapBig msHeapBig;
typedef struct msHeapSmall msHeapSmall;
typedef struct msHeapCell msHeapCell;
typedef struct msHeapTrunk msHeapTrunk;
typedef struct msHeapSlab msHeapSlab;

typedef struct {
    size_t prevSize;
    size_t size;
    msHeapHandle* owner;
} msHeapChunk;

/* A big chunk's state: MS_HEAP_ZEROED when every byte past its header reads zero;
 * MS_HEAP_DISCARDED when a free chunk's pages past its first went back to the OS and must be
 * reused before they are touched. A discarded chunk is never zeroed, and joins only discarded
 * chunks: joined to a dirty one, either the dirty pages stay resident or the discarded ones are
 * accounted again (macOS charges every reused page, touched or not). */
enum { MS_HEAP_ZEROED = 1, MS_HEAP_DISCARDED = 2 };

struct msHeapBig {
    msHeapChunk base;
    msHeapBig* next;
    msHeapBig* prev;
    size_t zeroed;
    _Alignas(16) unsigned char data[];
};

struct msHeapCell {
    msHeapCell* next;
    uintptr_t run;
#if UINTPTR_MAX == 0xffffffffu
    msHeapCell* runTail;
#endif
};

_Static_assert(sizeof(msHeapCell) <= MS_HEAP_ALIGN, "a remote run's header must fit the smallest cell");
_Static_assert(MS_HEAP_REMOTE_BATCH_BYTES / MS_HEAP_ALIGN < 0x10000, "a remote run's length must fit its 16 bits");

struct msHeapSmall {
    msHeapChunk base;
    msHeapSmall* next;
    msHeapSmall* prev;
    msHeapCell* freeList;
    uint32_t free;
    uint32_t acc;
    uint16_t alignOffset;
    uint16_t bumpZeroed;
    _Alignas(16) unsigned char data[];
};

#define MS_HEAP_SMALL_ROOM (MS_HEAP_PAGE_SIZE - sizeof(msHeapSmall))

struct msHeapTrunk {
    msHeapTrunk* next;
    uintptr_t key;
    uintptr_t bits[MS_HEAP_TRUNK_BITS / MS_HEAP_WORD_BITS];
};

struct msHeapSlab {
    size_t remaining;
    size_t acc;
    msHeapSlab* next;
};

struct msHeapRegion {
    msHeapSmall* small[MS_HEAP_SMALL_CLASSES];
    msHeapSmall* empties;
    msHeapSmall* agedEmpties;
    uint32_t flBitmap;
    uint32_t slBitmap[MS_HEAP_FL_COUNT];
    msHeapBig* matrix[MS_HEAP_FL_COUNT][MS_HEAP_SL_COUNT];
    msHeapSlab* metadata;
    msHeapTrunk* starts[256];
    msHeapBig* pendingBig;
    size_t occupied;
    size_t nextChunkSize;
    size_t lastSize;
    int blockChunkGrowth;
    uint32_t spreadSeq;
#if MS_HEAP_THREADS
    int64_t returnDue;
    int64_t agedSince;
    msHeapCell* remoteCells[MS_HEAP_SMALL_CLASSES];
#endif
};

typedef struct {
    msHeapHandle* owner;
    msHeapCell* head;
    msHeapCell* tail;
    uintptr_t count;
} msHeapRemoteRun;

struct msHeapHandle {
    msHeapCell* sharedCells[MS_HEAP_SMALL_CLASSES];
    msHeapRemoteRun runs[MS_HEAP_SMALL_CLASSES];
    uint64_t openRuns[MS_HEAP_SMALL_CLASSES / 64];
    size_t runBytes;
    msHeapBig* sharedBig;
    msHeapHandle* nextRetired;
    msHeapRegion region;
};

#define MS_HEAP_REGION(handle) (&(handle)->region)

_Static_assert(offsetof(msHeapBig, data) + (MS_HEAP_SPREAD_SLOTS - 1) * MS_HEAP_SPREAD_STEP < MS_HEAP_PAGE_SIZE,
               "a spread big payload must start in its chunk's first page, where msHeapPage finds the header");

static msHeapHandle* msHeapOwnerOf(msHeapRegion* a) {
    return (msHeapHandle*)((unsigned char*)a - offsetof(msHeapHandle, region));
}

static size_t msHeapRound(size_t size, size_t alignment) {
    if (size > SIZE_MAX - (alignment - 1)) msHeapOutOfMemory();
    return (size + alignment - 1) & ~(alignment - 1);
}

static void* msHeapAllocPages(size_t bytes) {
    void* p = msHeapTryAllocPages(bytes);
    if (!p) msHeapOutOfMemory();
    return p;
}

#if MS_HEAP_THREADS

#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <windows.h>
static SRWLOCK msHeapRetiredLock = SRWLOCK_INIT;
#define msHeapRetiredAcquire() AcquireSRWLockExclusive(&msHeapRetiredLock)
#define msHeapRetiredReleaseLock() ReleaseSRWLockExclusive(&msHeapRetiredLock)
#else
#include <pthread.h>
static pthread_mutex_t msHeapRetiredLock = PTHREAD_MUTEX_INITIALIZER;
#define msHeapRetiredAcquire() pthread_mutex_lock(&msHeapRetiredLock)
#define msHeapRetiredReleaseLock() pthread_mutex_unlock(&msHeapRetiredLock)
#endif

static msHeapHandle* msHeapRetired;
static _Thread_local msHeapHandle* msHeapCurrent;

extern void msThreadAttach(void);

static msHeapHandle* msHeapAcquire(void) {
    msHeapRetiredAcquire();
    msHeapHandle* handle = msHeapRetired;
    if (handle) msHeapRetired = handle->nextRetired;
    msHeapRetiredReleaseLock();
    if (!handle) {
        handle = msHeapAllocPages(msHeapRound(sizeof(msHeapHandle), MS_HEAP_PAGE_SIZE));
        msHeapZero(handle, sizeof(*handle));
    }
    handle->nextRetired = NULL;
    msHeapCurrent = handle;
    msThreadAttach();
    return handle;
}

static inline msHeapRegion* msHeapHere(void) {
    msHeapHandle* handle = msHeapCurrent;
    if (__builtin_expect(handle == NULL, 0)) handle = msHeapAcquire();
    return MS_HEAP_REGION(handle);
}

static void msHeapCloseRuns(msHeapHandle* here);

void msHeapThreadFlush(void) {
    if (msHeapCurrent) msHeapCloseRuns(msHeapCurrent);
}

void msHeapThreadRelease(void) {
    msHeapHandle* handle = msHeapCurrent;
    if (!handle) return;
    msHeapReturnIdle();
    msHeapCurrent = NULL;
    msHeapRetiredAcquire();
    handle->nextRetired = msHeapRetired;
    msHeapRetired = handle;
    msHeapRetiredReleaseLock();
}

static void msHeapMarkRun(msHeapCell* head, msHeapCell* tail, uintptr_t count) {
#if UINTPTR_MAX == 0xffffffffu
    head->run = count;
    head->runTail = tail;
#else
    intptr_t span = (intptr_t)tail - (intptr_t)head;
    head->run = ((uintptr_t)span << 16) | count;
    if (((intptr_t)head->run >> 16) != span) {
        msErrorf("msHeapFree: a remote run spans %p..%p, beyond the 48-bit distance its header holds\n",
                 (void*)head, (void*)tail);
        abort();
    }
#endif
}

static uintptr_t msHeapRunLength(msHeapCell* head) { return head->run & 0xffff; }

static msHeapCell* msHeapRunTail(msHeapCell* head) {
#if UINTPTR_MAX == 0xffffffffu
    return head->runTail;
#else
    return (msHeapCell*)((intptr_t)head + ((intptr_t)head->run >> 16));
#endif
}

static void msHeapPushRemoteRun(msHeapHandle* owner, size_t slot, msHeapCell* head, msHeapCell* tail, uintptr_t count) {
    msHeapMarkRun(head, tail, count);
    msHeapCell* shared = __atomic_load_n(&owner->sharedCells[slot], __ATOMIC_RELAXED);
    do {
        tail->next = shared;
    } while (!__atomic_compare_exchange_n(&owner->sharedCells[slot], &shared, head, 1,
                                          __ATOMIC_RELEASE, __ATOMIC_RELAXED));
}

static void msHeapCloseRun(msHeapHandle* here, size_t slot) {
    msHeapRemoteRun* run = &here->runs[slot];
    msHeapPushRemoteRun(run->owner, slot, run->head, run->tail, run->count);
    *run = (msHeapRemoteRun){0};
}

static void msHeapCloseRuns(msHeapHandle* here) {
    for (size_t word = 0; word < MS_HEAP_SMALL_CLASSES / 64; ++word) {
        for (uint64_t open = here->openRuns[word]; open; open &= open - 1)
            msHeapCloseRun(here, word * 64 + (size_t)__builtin_ctzll(open));
        here->openRuns[word] = 0;
    }
    here->runBytes = 0;
}

static void msHeapAddToRun(msHeapHandle* here, msHeapHandle* owner, size_t slot, size_t size, msHeapCell* cell) {
    msHeapRemoteRun* run = &here->runs[slot];
    if (run->head && run->owner != owner) msHeapCloseRun(here, slot);
    if (!run->head) {
        run->owner = owner;
        run->tail = cell;
        here->openRuns[slot / 64] |= (uint64_t)1 << (slot % 64);
    }
    cell->next = run->head;
    run->head = cell;
    ++run->count;
    here->runBytes += size;
    if (here->runBytes >= MS_HEAP_REMOTE_BATCH_BYTES) msHeapCloseRuns(here);
}

static void msHeapPushRemoteBig(msHeapHandle* owner, msHeapBig* chunk) {
    msHeapBig* head = __atomic_load_n(&owner->sharedBig, __ATOMIC_RELAXED);
    do {
        chunk->next = head;
    } while (!__atomic_compare_exchange_n(&owner->sharedBig, &head, chunk, 1,
                                          __ATOMIC_RELEASE, __ATOMIC_RELAXED));
}

#else

static msHeapHandle msHeapOnly;
#define msHeapHere() MS_HEAP_REGION(&msHeapOnly)
void msHeapThreadRelease(void) {}
void msHeapThreadFlush(void) {}

#endif

static void* msHeapMetadata(msHeapRegion* a, size_t size) {
    msHeapSlab* slab = a->metadata;
    if (!slab || size > slab->remaining) {
        slab = msHeapAllocPages(MS_HEAP_PAGE_SIZE);
        slab->next = a->metadata;
        slab->remaining = MS_HEAP_PAGE_SIZE - sizeof(*slab);
        slab->acc = sizeof(*slab);
        a->metadata = slab;
    }
    void* result = (unsigned char*)slab + slab->acc;
    slab->acc += size;
    slab->remaining -= size;
    msHeapZero(result, size);
    return result;
}

static msHeapTrunk* msHeapFindTrunk(msHeapRegion* a, uintptr_t key) {
    msHeapTrunk* trunk = a->starts[key & 255];
    while (trunk && trunk->key != key) trunk = trunk->next;
    return trunk;
}

static int msHeapContains(msHeapRegion* a, uintptr_t address) {
    uintptr_t page = address / MS_HEAP_PAGE_SIZE;
    msHeapTrunk* trunk = msHeapFindTrunk(a, page >> MS_HEAP_TRUNK_SHIFT);
    size_t bit = page & (MS_HEAP_TRUNK_BITS - 1);
    return trunk && (trunk->bits[bit / MS_HEAP_WORD_BITS] &
                     ((uintptr_t)1 << (bit % MS_HEAP_WORD_BITS))) != 0;
}

static void msHeapInclude(msHeapRegion* a, uintptr_t address) {
    uintptr_t page = address / MS_HEAP_PAGE_SIZE;
    uintptr_t key = page >> MS_HEAP_TRUNK_SHIFT;
    msHeapTrunk* trunk = msHeapFindTrunk(a, key);
    if (!trunk) {
        trunk = msHeapMetadata(a, sizeof(*trunk));
        trunk->key = key;
        trunk->next = a->starts[key & 255];
        a->starts[key & 255] = trunk;
    }
    size_t bit = page & (MS_HEAP_TRUNK_BITS - 1);
    trunk->bits[bit / MS_HEAP_WORD_BITS] |= (uintptr_t)1 << (bit % MS_HEAP_WORD_BITS);
}

static void msHeapExclude(msHeapRegion* a, uintptr_t address) {
    uintptr_t page = address / MS_HEAP_PAGE_SIZE;
    msHeapTrunk* trunk = msHeapFindTrunk(a, page >> MS_HEAP_TRUNK_SHIFT);
    size_t bit = page & (MS_HEAP_TRUNK_BITS - 1);
    if (trunk) trunk->bits[bit / MS_HEAP_WORD_BITS] &=
        ~((uintptr_t)1 << (bit % MS_HEAP_WORD_BITS));
}

static unsigned msHeapMsBit(uint32_t bits) {
    unsigned result = 0;
    while (bits >>= 1) ++result;
    return result;
}

static unsigned msHeapLsBit(uint32_t bits) {
    return msHeapMsBit(bits & (0u - bits));
}

static void msHeapMapping(size_t size, unsigned* fl, unsigned* sl) {
    unsigned high = msHeapMsBit((uint32_t)size);
    *sl = (unsigned)(size >> (high - 5)) - MS_HEAP_SL_COUNT;
    *fl = high - MS_HEAP_FL_OFFSET;
}

static size_t msHeapSearchMapping(size_t size, unsigned* fl, unsigned* sl) {
    unsigned high = msHeapMsBit((uint32_t)size);
    size_t step = msHeapRound((size_t)1 << (high - 5), MS_HEAP_PAGE_SIZE);
    size = msHeapRound(size, step);
    if (size > MS_HEAP_MAX_BIG) size = MS_HEAP_MAX_BIG;
    msHeapMapping(size, fl, sl);
    return size;
}

static void msHeapInsertBig(msHeapRegion* a, msHeapBig* chunk) {
    unsigned fl, sl;
    msHeapMapping(chunk->base.size, &fl, &sl);
    chunk->prev = NULL;
    chunk->next = a->matrix[fl][sl];
    if (chunk->next) chunk->next->prev = chunk;
    a->matrix[fl][sl] = chunk;
    a->slBitmap[fl] |= (uint32_t)1 << sl;
    a->flBitmap |= (uint32_t)1 << fl;
}

static void msHeapRemoveBig(msHeapRegion* a, msHeapBig* chunk) {
    unsigned fl, sl;
    msHeapMapping(chunk->base.size, &fl, &sl);
    if (chunk->next) chunk->next->prev = chunk->prev;
    if (chunk->prev) chunk->prev->next = chunk->next;
    else a->matrix[fl][sl] = chunk->next;
    if (!a->matrix[fl][sl]) {
        a->slBitmap[fl] &= ~((uint32_t)1 << sl);
        if (!a->slBitmap[fl]) a->flBitmap &= ~((uint32_t)1 << fl);
    }
    chunk->next = chunk->prev = NULL;
}

static msHeapBig* msHeapFindBig(msHeapRegion* a, unsigned fl, unsigned sl) {
    uint32_t bits = a->slBitmap[fl] & (UINT32_MAX << sl);
    if (!bits) {
        bits = a->flBitmap & (UINT32_MAX << (fl + 1));
        if (!bits) return NULL;
        fl = msHeapLsBit(bits);
        bits = a->slBitmap[fl];
    }
    return a->matrix[fl][msHeapLsBit(bits)];
}

static void msHeapUpdateNext(msHeapRegion* a, msHeapBig* chunk) {
    uintptr_t address = (uintptr_t)chunk + chunk->base.size;
    if (msHeapContains(a, address)) {
        msHeapChunk* next = (msHeapChunk*)address;
        next->prevSize = chunk->base.size | (next->prevSize & 1);
    }
}

static msHeapBig* msHeapSplit(msHeapRegion* a, msHeapBig* chunk, size_t size) {
    msHeapBig* rest = (msHeapBig*)((unsigned char*)chunk + size);
    rest->base.size = chunk->base.size - size;
    rest->base.prevSize = size;
    rest->base.owner = msHeapOwnerOf(a);
    rest->next = rest->prev = NULL;
    rest->zeroed = chunk->zeroed;
    chunk->base.size = size;
    msHeapInclude(a, (uintptr_t)rest);
    msHeapUpdateNext(a, rest);
    return rest;
}

#if MS_HEAP_THREADS
#ifndef MS_HEAP_NOW_MS
#if defined(_WIN32)
static int64_t msHeapNowMs(void) { return (int64_t)GetTickCount64(); }
#else
#include <time.h>
#if defined(CLOCK_MONOTONIC_COARSE)
#define MS_HEAP_CLOCK CLOCK_MONOTONIC_COARSE
#elif defined(CLOCK_MONOTONIC_RAW_APPROX)
#define MS_HEAP_CLOCK CLOCK_MONOTONIC_RAW_APPROX
#else
#define MS_HEAP_CLOCK CLOCK_MONOTONIC
#endif
static int64_t msHeapNowMs(void) {
    struct timespec t;
    clock_gettime(MS_HEAP_CLOCK, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
#endif
#define MS_HEAP_NOW_MS() msHeapNowMs()
#endif

static int64_t* msHeapUnusedSince(msHeapBig* chunk) { return (int64_t*)chunk->data; }

static int64_t msHeapUnusedNow(void) {
    int64_t now = MS_HEAP_NOW_MS();
    return now - now % MS_HEAP_RETURN_STEP_MS;
}

/* Two free chunks joined keep the age of the larger: a small one neither renews a large chunk
 * that stayed unused nor sends back a large one just freed. */
static int64_t msHeapJoinedSince(msHeapBig* joined, size_t size, int64_t since) {
    return !joined->zeroed && joined->base.size >= size ? *msHeapUnusedSince(joined) : since;
}

static int msHeapFreeDiscarded(msHeapRegion* a, uintptr_t address) {
    if (!msHeapContains(a, address)) return 0;
    msHeapBig* chunk = (msHeapBig*)address;
    return !(chunk->base.prevSize & 1) && (chunk->zeroed & MS_HEAP_DISCARDED);
}

static int msHeapNearDiscarded(msHeapRegion* a, msHeapBig* chunk) {
    size_t prevSize = chunk->base.prevSize & ~(size_t)1;
    return (prevSize && msHeapFreeDiscarded(a, (uintptr_t)chunk - prevSize)) ||
           msHeapFreeDiscarded(a, (uintptr_t)chunk + chunk->base.size);
}

static int msHeapReturnable(msHeapRegion* a, msHeapBig* chunk) {
    return chunk->base.size - MS_HEAP_PAGE_SIZE >= MS_HEAP_DISCARD_MIN_BYTES || msHeapNearDiscarded(a, chunk);
}

static void msHeapInsertUnused(msHeapRegion* a, msHeapBig* chunk, int64_t since) {
    *msHeapUnusedSince(chunk) = since;
    msHeapInsertBig(a, chunk);
    int64_t due = since + MS_HEAP_RETURN_AFTER_MS + MS_HEAP_RETURN_STEP_MS;
    if ((!a->returnDue || due < a->returnDue) && msHeapReturnable(a, chunk)) a->returnDue = due;
}

static void msHeapReturnOld(msHeapRegion* a);
#else
#define msHeapUnusedNow() 0
#define msHeapJoinedSince(joined, size, since) (since)
#define msHeapInsertUnused(a, chunk, since) msHeapInsertBig(a, chunk)
#define msHeapReturnOld(a) ((void)0)
#endif

static int msHeapReleaseEmpty(msHeapRegion* a);

static msHeapBig* msHeapRequest(msHeapRegion* a, size_t size) {
    if (!a->blockChunkGrowth) {
        if (a->occupied < 64 * 1024) a->nextChunkSize = MS_HEAP_PAGE_SIZE * 4;
        else {
            size_t next = msHeapRound(a->occupied >> 2, MS_HEAP_PAGE_SIZE);
            if (next > a->nextChunkSize * 2) next = a->nextChunkSize * 2;
            if (next > MS_HEAP_MAX_BIG) next = MS_HEAP_MAX_BIG;
            a->nextChunkSize = next;
        }
    }
    msHeapBig* chunk;
    if (size > a->nextChunkSize) chunk = msHeapAllocPages(size);
    else {
        chunk = msHeapTryAllocPages(a->nextChunkSize);
        if (chunk) size = a->nextChunkSize;
        else {
            chunk = msHeapAllocPages(size);
            a->blockChunkGrowth = 1;
        }
    }
    chunk->base.size = size;
    chunk->base.owner = msHeapOwnerOf(a);
    chunk->base.prevSize = 0;
    chunk->next = chunk->prev = NULL;
    chunk->zeroed = MS_HEAP_FRESH_PAGES_ZERO ? MS_HEAP_ZEROED : 0;
    size_t lastSize = a->lastSize ? a->lastSize : MS_HEAP_PAGE_SIZE;
    uintptr_t left = (uintptr_t)chunk - lastSize;
    if (msHeapContains(a, left) && ((msHeapChunk*)left)->size == lastSize)
        chunk->base.prevSize = lastSize;
    a->lastSize = size;
    msHeapUpdateNext(a, chunk);
    return chunk;
}

#if MS_HEAP_THREADS
/* Re-arms the front of a discarded chunk taken off the free lists, `bytes` or a discard's least
 * size, and leaves the rest discarded and free: one syscall then serves many page-sized takes. */
static void msHeapRearm(msHeapRegion* a, msHeapBig* chunk, size_t bytes) {
    if (!(chunk->zeroed & MS_HEAP_DISCARDED)) return;
    size_t front = bytes < MS_HEAP_DISCARD_MIN_BYTES ? MS_HEAP_DISCARD_MIN_BYTES : bytes;
    int keepsRest = chunk->base.size >= front + MS_HEAP_PAGE_SIZE + MS_HEAP_DISCARD_MIN_BYTES;
    if (!keepsRest) front = chunk->base.size - MS_HEAP_PAGE_SIZE;
    if (!msHeapReusePages((unsigned char*)chunk + MS_HEAP_PAGE_SIZE, front)) msHeapOutOfMemory();
    if (keepsRest) msHeapInsertBig(a, msHeapSplit(a, chunk, front));
    chunk->zeroed = 0;
    *msHeapUnusedSince(chunk) = msHeapUnusedNow();
}
#else
#define msHeapRearm(a, chunk, bytes) ((void)0)
#endif

static msHeapBig* msHeapGetBig(msHeapRegion* a, size_t size) {
    unsigned fl, sl;
    msHeapReturnOld(a);
    size = msHeapSearchMapping(size, &fl, &sl);
    msHeapBig* chunk = msHeapFindBig(a, fl, sl);
    if (!chunk && msHeapReleaseEmpty(a)) chunk = msHeapFindBig(a, fl, sl);
    if (chunk) {
        msHeapRemoveBig(a, chunk);
        msHeapRearm(a, chunk, size);
    } else {
        size_t request = MS_HEAP_MIN_PAGES * (size_t)MS_HEAP_PAGE_SIZE;
        if (request < size) request = size;
        chunk = msHeapRequest(a, request);
    }
    if (chunk->base.size >= size + MS_HEAP_PAGE_SIZE) {
        msHeapBig* rest = msHeapSplit(a, chunk, size);
        if (rest->zeroed) msHeapInsertBig(a, rest);
        else msHeapInsertUnused(a, rest, *msHeapUnusedSince(chunk));
    }
    chunk->base.prevSize |= 1;
    msHeapInclude(a, (uintptr_t)chunk);
    return chunk;
}

static void msHeapReleaseBigSince(msHeapRegion* a, msHeapBig* chunk, int64_t since) {
    (void)since;
    chunk->base.prevSize &= ~(size_t)1;
    chunk->zeroed = 0;
    if (chunk->base.size > MS_HEAP_MAX_BIG) {
        msHeapExclude(a, (uintptr_t)chunk);
        msHeapDeallocPages(chunk, chunk->base.size);
        return;
    }
    size_t prevSize = chunk->base.prevSize;
    if (prevSize) {
        uintptr_t address = (uintptr_t)chunk - prevSize;
        if (msHeapContains(a, address)) {
            msHeapBig* left = (msHeapBig*)address;
            if (!(left->base.prevSize & 1) && left->base.size == prevSize && !(left->zeroed & MS_HEAP_DISCARDED) &&
                left->base.size < MS_HEAP_MAX_BIG) {
                msHeapRemoveBig(a, left);
                since = msHeapJoinedSince(left, chunk->base.size, since);
                left->base.size += chunk->base.size;
                msHeapExclude(a, (uintptr_t)chunk);
                chunk = left;
                chunk->zeroed = 0;
                if (chunk->base.size > MS_HEAP_MAX_BIG) {
                    msHeapBig* rest = msHeapSplit(a, chunk, MS_HEAP_MAX_BIG);
                    msHeapInsertUnused(a, chunk, since);
                    chunk = rest;
                }
            }
        }
    }
    uintptr_t address = (uintptr_t)chunk + chunk->base.size;
    if (msHeapContains(a, address)) {
        msHeapBig* right = (msHeapBig*)address;
        if (!(right->base.prevSize & 1) && !(right->zeroed & MS_HEAP_DISCARDED) && chunk->base.size < MS_HEAP_MAX_BIG) {
            msHeapRemoveBig(a, right);
            since = msHeapJoinedSince(right, chunk->base.size, since);
            chunk->base.size += right->base.size;
            msHeapExclude(a, address);
            if (chunk->base.size > MS_HEAP_MAX_BIG)
                msHeapInsertUnused(a, msHeapSplit(a, chunk, MS_HEAP_MAX_BIG), since);
        }
    }
    msHeapUpdateNext(a, chunk);
    msHeapInsertUnused(a, chunk, since);
}

static void msHeapReleaseBig(msHeapRegion* a, msHeapBig* chunk) {
    msHeapReleaseBigSince(a, chunk, msHeapUnusedNow());
}

static void msHeapDeallocBig(msHeapRegion* a, msHeapBig* chunk) {
    if (!(chunk->base.prevSize & 1)) msHeapFreedTwice(chunk->data);
    a->occupied -= chunk->base.size;
    msHeapReleaseBig(a, chunk);
}

static void msHeapInsertSmall(msHeapRegion* a, msHeapSmall* chunk) {
    size_t slot = chunk->base.size / MS_HEAP_ALIGN;
    chunk->prev = NULL;
    chunk->next = a->small[slot];
    if (chunk->next) chunk->next->prev = chunk;
    a->small[slot] = chunk;
}

static void msHeapRemoveSmall(msHeapRegion* a, msHeapSmall* chunk) {
    size_t slot = chunk->base.size / MS_HEAP_ALIGN;
    if (chunk->next) chunk->next->prev = chunk->prev;
    if (chunk->prev) chunk->prev->next = chunk->next;
    else a->small[slot] = chunk->next;
    chunk->next = chunk->prev = NULL;
}

static msHeapChunk* msHeapPage(void* p) {
    return (msHeapChunk*)((uintptr_t)p & ~((uintptr_t)MS_HEAP_PAGE_SIZE - 1));
}

static void msHeapShelveSmall(msHeapRegion* a, msHeapSmall* chunk) {
    msHeapRemoveSmall(a, chunk);
    chunk->next = a->empties;
    a->empties = chunk;
}

static void msHeapRelistSmall(msHeapRegion* a, msHeapSmall* chunk) {
    msHeapSmall* head = a->small[chunk->base.size / MS_HEAP_ALIGN];
    msHeapInsertSmall(a, chunk);
    if (head && head->free == MS_HEAP_SMALL_ROOM) msHeapShelveSmall(a, head);
}

static uintptr_t msHeapHomeMark(msHeapSmall* chunk) {
    return (uintptr_t)chunk ^ (uintptr_t)0x9e3779b97f4a7c15u;
}

static int msHeapIsHome(msHeapSmall* chunk, msHeapCell* cell) {
    for (msHeapCell* home = chunk->freeList; home; home = home->next)
        if (home == cell) return 1;
    return 0;
}

static inline void msHeapPutHome(msHeapRegion* a, msHeapSmall* chunk, msHeapCell* cell, size_t size) {
    uintptr_t mark = msHeapHomeMark(chunk);
    if (__builtin_expect(cell->run == mark, 0) && msHeapIsHome(chunk, cell)) msHeapFreedTwice(cell);
    cell->run = mark;
    cell->next = chunk->freeList;
    chunk->freeList = cell;
    uint32_t before = chunk->free;
    chunk->free = before + (uint32_t)size;
    if (before < size) msHeapRelistSmall(a, chunk);
    else if (chunk->free == MS_HEAP_SMALL_ROOM && chunk != a->small[size / MS_HEAP_ALIGN]) msHeapShelveSmall(a, chunk);
}

static __attribute__((noinline)) msHeapSmall* msHeapOpenSmall(msHeapRegion* a, size_t cellSize) {
    msHeapSmall** list = a->empties ? &a->empties : &a->agedEmpties;
    msHeapSmall* chunk = *list;
    uint16_t zeroed = 0;
    if (chunk) *list = chunk->next;
    else {
        msHeapBig* page = msHeapGetBig(a, MS_HEAP_PAGE_SIZE);
        zeroed = (page->zeroed & MS_HEAP_ZEROED) != 0;
        chunk = (msHeapSmall*)page;
    }
    chunk->base.size = cellSize;
    chunk->freeList = NULL;
    chunk->alignOffset = 0;
    chunk->acc = 0;
    chunk->free = (uint32_t)MS_HEAP_SMALL_ROOM;
    chunk->bumpZeroed = zeroed;
    msHeapRelistSmall(a, chunk);
    return chunk;
}

#if MS_HEAP_THREADS
static msHeapCell* msHeapFetchRemoteCells(msHeapRegion* a, size_t slot) {
    msHeapCell** head = &msHeapOwnerOf(a)->sharedCells[slot];
    if (!__atomic_load_n(head, __ATOMIC_RELAXED)) return NULL;
    msHeapCell* cells = __atomic_exchange_n(head, NULL, __ATOMIC_ACQUIRE);
    size_t count = 0;
    for (msHeapCell* run = cells; run; run = msHeapRunTail(run)->next) count += msHeapRunLength(run);
    a->occupied -= count * slot * MS_HEAP_ALIGN;
    return cells;
}

static inline msHeapCell* msHeapTakeRemoteCell(msHeapRegion* a, size_t slot) {
    msHeapCell* cell = a->remoteCells[slot];
    if (!cell && !(cell = msHeapFetchRemoteCells(a, slot))) return NULL;
    a->remoteCells[slot] = cell->next;
    return cell;
}

static int msHeapRouteRemoteCells(msHeapRegion* a, size_t most) {
    for (size_t slot = 1; slot < MS_HEAP_SMALL_CLASSES; ++slot) {
        msHeapCell* cell;
        while ((cell = msHeapTakeRemoteCell(a, slot))) {
            if (!most--) {
                a->remoteCells[slot] = cell;
                return 1;
            }
            msHeapPutHome(a, (msHeapSmall*)msHeapPage(cell), cell, slot * MS_HEAP_ALIGN);
        }
    }
    return 0;
}

static void msHeapDrainRemoteBig(msHeapRegion* a) {
    for (int step = 0; step <= MS_HEAP_MAX_REMOTE_BIG_STEPS; ++step) {
        if (!a->pendingBig) {
            msHeapBig** head = &msHeapOwnerOf(a)->sharedBig;
            if (!__atomic_load_n(head, __ATOMIC_RELAXED)) return;
            a->pendingBig = __atomic_exchange_n(head, NULL, __ATOMIC_ACQUIRE);
        }
        msHeapBig* chunk = a->pendingBig;
        a->pendingBig = chunk->next;
        chunk->next = NULL;
        msHeapDeallocBig(a, chunk);
    }
}
#else
#define msHeapTakeRemoteCell(a, slot) NULL
#define msHeapRouteRemoteCells(a, most) 0
#define msHeapDrainRemoteBig(a) ((void)0)
#endif

static int msHeapReleaseSmalls(msHeapRegion* a, msHeapSmall** list, int64_t since, size_t most) {
    int released = *list != NULL;
    while (*list && most--) {
        msHeapSmall* chunk = *list;
        *list = chunk->next;
        chunk->base.size = MS_HEAP_PAGE_SIZE;
        msHeapReleaseBigSince(a, (msHeapBig*)chunk, since);
    }
    return released;
}

static int msHeapReleaseEmpty(msHeapRegion* a) {
    msHeapRouteRemoteCells(a, SIZE_MAX);
    for (size_t slot = 1; slot < MS_HEAP_SMALL_CLASSES; ++slot) {
        msHeapSmall* head = a->small[slot];
        if (!head || head->free != MS_HEAP_SMALL_ROOM) continue;
        msHeapRemoveSmall(a, head);
        head->next = a->empties;
        a->empties = head;
    }
    int64_t since = msHeapUnusedNow();
    return msHeapReleaseSmalls(a, &a->empties, since, SIZE_MAX) | msHeapReleaseSmalls(a, &a->agedEmpties, since, SIZE_MAX);
}

#if MS_HEAP_THREADS
static int64_t msHeapAgedDue(msHeapRegion* a) {
    return a->agedSince + MS_HEAP_RETURN_AFTER_MS + MS_HEAP_RETURN_STEP_MS;
}

static void msHeapNoteAgedDue(msHeapRegion* a) {
    if (a->agedEmpties && (!a->returnDue || msHeapAgedDue(a) < a->returnDue)) a->returnDue = msHeapAgedDue(a);
}

static void msHeapAgeEmpties(msHeapRegion* a, int64_t now) {
    if (!a->empties || a->agedEmpties) return;
    a->agedEmpties = a->empties;
    a->empties = NULL;
    a->agedSince = now - now % MS_HEAP_RETURN_STEP_MS;
    msHeapNoteAgedDue(a);
}

static int msHeapReleaseAged(msHeapRegion* a, int64_t now) {
    int cellsLeft = msHeapRouteRemoteCells(a, MS_HEAP_TURN_CELLS);
    if (a->agedEmpties && now >= msHeapAgedDue(a)) msHeapReleaseSmalls(a, &a->agedEmpties, a->agedSince, MS_HEAP_TURN_PAGES);
    msHeapAgeEmpties(a, now);
    return cellsLeft;
}
#endif

static inline __attribute__((always_inline)) void* msHeapTake(size_t size, int* zeroed) {
    msHeapRegion* a = msHeapHere();
    size_t cellSize = msHeapRound(size ? size : 1, MS_HEAP_ALIGN);
    if (cellSize <= MS_HEAP_SMALL_ROOM) {
        size_t slot = cellSize / MS_HEAP_ALIGN;
        msHeapSmall* chunk = a->small[slot];
        void* result;
        if (!chunk) {
            result = msHeapTakeRemoteCell(a, slot);
            if (result) {
                *zeroed = 0;
                a->occupied += cellSize;
                return result;
            }
            chunk = msHeapOpenSmall(a, cellSize);
        }
        if (chunk->freeList) {
            result = chunk->freeList;
            chunk->freeList = chunk->freeList->next;
            *zeroed = 0;
        } else {
            result = chunk->data + chunk->acc;
            *zeroed = chunk->bumpZeroed;
            chunk->acc += (uint32_t)cellSize;
        }
        if (!*zeroed) ((msHeapCell*)result)->run = 0;
        chunk->free -= (uint32_t)cellSize;
        if (chunk->free < cellSize) msHeapRemoveSmall(a, chunk);
        a->occupied += cellSize;
        return result;
    }
    msHeapDrainRemoteBig(a);
    if (size > SIZE_MAX - sizeof(msHeapBig)) msHeapOutOfMemory();
    size_t bytes = msHeapRound(size + sizeof(msHeapBig), MS_HEAP_PAGE_SIZE);
    msHeapBig* chunk;
    if (bytes > MS_HEAP_MAX_BIG) {
        chunk = msHeapAllocPages(bytes);
        chunk->base.size = bytes;
        chunk->base.prevSize = 1;
        chunk->base.owner = msHeapOwnerOf(a);
        chunk->next = chunk->prev = NULL;
        chunk->zeroed = MS_HEAP_FRESH_PAGES_ZERO ? MS_HEAP_ZEROED : 0;
        msHeapInclude(a, (uintptr_t)chunk);
    } else chunk = msHeapGetBig(a, bytes);
    a->occupied += chunk->base.size;
    *zeroed = (chunk->zeroed & MS_HEAP_ZEROED) != 0;
    size_t slots = (chunk->base.size - offsetof(msHeapBig, data) - size) / MS_HEAP_SPREAD_STEP + 1;
    if (slots > MS_HEAP_SPREAD_SLOTS) slots = MS_HEAP_SPREAD_SLOTS;
    return chunk->data + (size_t)(a->spreadSeq++ * MS_HEAP_SPREAD_STRIDE % slots) * MS_HEAP_SPREAD_STEP;
}

void* msHeapAlloc(size_t size) {
    int zeroed;
    return msHeapTake(size, &zeroed);
}

static __attribute__((noinline)) void* msHeapTakeTracked(size_t size, int* zeroed) {
    return msHeapTake(size, zeroed);
}

void* msHeapCalloc(size_t count, size_t size) {
    size_t bytes = msHeapProduct(count, size);
    int zeroed;
    void* p = msHeapTakeTracked(bytes, &zeroed);
    if (!zeroed) msHeapZero(p, bytes);
    return p;
}

void msHeapFree(void* p) {
    if (!p) return;
    msHeapChunk* base = msHeapPage(p);
    msHeapHandle* owner = base->owner;
#if MS_HEAP_THREADS
    msHeapHandle* here = msHeapCurrent;
#else
    msHeapHandle* here = &msHeapOnly;
    (void)owner;
#endif
    if (base->size <= MS_HEAP_SMALL_ROOM) {
        size_t size = base->size;
        if (!size || size % MS_HEAP_ALIGN) msHeapFreedTwice(p);
#if MS_HEAP_THREADS
        if (owner != here) {
            if (here) msHeapAddToRun(here, owner, size / MS_HEAP_ALIGN, size, p);
            else msHeapPushRemoteRun(owner, size / MS_HEAP_ALIGN, p, p, 1);
            return;
        }
#endif
        msHeapRegion* a = MS_HEAP_REGION(here);
        msHeapPutHome(a, (msHeapSmall*)base, p, size);
        a->occupied -= size;
    } else {
#if MS_HEAP_THREADS
        if (owner != here) {
            msHeapPushRemoteBig(owner, (msHeapBig*)base);
            return;
        }
#endif
        msHeapDeallocBig(MS_HEAP_REGION(here), (msHeapBig*)base);
#if MS_HEAP_THREADS && MS_HEAP_DISCARD_STRICT
        static _Thread_local unsigned strictFrees;
        if (++strictFrees % 8 == 0) msHeapReturnIdle();
#endif
    }
}

#if MS_HEAP_THREADS
/* Pages of a free chunk that was never handed out were never touched, so only dirty chunks go
 * back. A chunk too small to discard goes with a discarded neighbour, which a second sweep sees. */
static int msHeapDiscardDue(msHeapRegion* a, int64_t now, size_t* pagesLeft) {
    int discarded = 0;
    a->returnDue = 0;
    for (unsigned fl = 0; fl < MS_HEAP_FL_COUNT; ++fl) {
        for (unsigned sl = 0; sl < MS_HEAP_SL_COUNT; ++sl) {
            for (msHeapBig* chunk = a->matrix[fl][sl]; chunk; chunk = chunk->next) {
                if (chunk->zeroed || !msHeapReturnable(a, chunk)) continue;
                int64_t since = *msHeapUnusedSince(chunk);
                int64_t due = since + MS_HEAP_RETURN_AFTER_MS + MS_HEAP_RETURN_STEP_MS;
                if (now < due || !*pagesLeft) {
                    if (!a->returnDue || due < a->returnDue) a->returnDue = due;
                    continue;
                }
                size_t pages = chunk->base.size / MS_HEAP_PAGE_SIZE - 1;
                int cut = pages > *pagesLeft;
                if (cut) {
                    pages = *pagesLeft;
                    msHeapRemoveBig(a, chunk);
                    msHeapInsertUnused(a, msHeapSplit(a, chunk, (pages + 1) * MS_HEAP_PAGE_SIZE), since);
                    msHeapInsertBig(a, chunk);
                }
                if (pages) msHeapDiscardPages((unsigned char*)chunk + MS_HEAP_PAGE_SIZE, pages * MS_HEAP_PAGE_SIZE);
                *pagesLeft -= pages;
                chunk->zeroed = MS_HEAP_DISCARDED;
                if (cut) return 1;
                discarded = 1;
            }
        }
    }
    return discarded;
}

static void msHeapJoinDiscarded(msHeapRegion* a) {
    for (unsigned fl = 0; fl < MS_HEAP_FL_COUNT; ++fl) {
        for (unsigned sl = 0; sl < MS_HEAP_SL_COUNT; ++sl) {
            msHeapBig* chunk = a->matrix[fl][sl];
            while (chunk) {
                uintptr_t address = (uintptr_t)chunk + chunk->base.size;
                msHeapBig* right = (msHeapBig*)address;
                if (!(chunk->zeroed & MS_HEAP_DISCARDED) || !msHeapFreeDiscarded(a, address) ||
                    chunk->base.size + right->base.size > MS_HEAP_MAX_BIG) {
                    chunk = chunk->next;
                    continue;
                }
                msHeapRemoveBig(a, right);
                msHeapRemoveBig(a, chunk);
                msHeapExclude(a, address);
                chunk->base.size += right->base.size;
                msHeapUpdateNext(a, chunk);
                msHeapInsertBig(a, chunk);
                chunk = a->matrix[fl][sl];
            }
        }
    }
}

static void msHeapReturn(msHeapRegion* a, int64_t now) {
    msHeapHandle* here = msHeapOwnerOf(a);
    msHeapCloseRuns(here);
    while (a->pendingBig || __atomic_load_n(&here->sharedBig, __ATOMIC_RELAXED)) msHeapDrainRemoteBig(a);
    int cellsLeft = 0;
    size_t pagesLeft = MS_HEAP_TURN_PAGES;
    if (now == INT64_MAX) {
        msHeapReleaseEmpty(a);
        pagesLeft = SIZE_MAX;
    } else cellsLeft = msHeapReleaseAged(a, now);
    if (msHeapDiscardDue(a, now, &pagesLeft)) {
        while (msHeapDiscardDue(a, now, &pagesLeft)) {}
        msHeapJoinDiscarded(a);
    }
    msHeapNoteAgedDue(a);
    if (cellsLeft) a->returnDue = now;
}

static void msHeapReturnOld(msHeapRegion* a) {
    if (!a->returnDue && !a->empties) return;
    int64_t now = MS_HEAP_NOW_MS();
    msHeapAgeEmpties(a, now);
    if (a->returnDue && now >= a->returnDue) msHeapReturn(a, now);
}

void msHeapReturnIdle(void) {
    if (msHeapCurrent) msHeapReturn(MS_HEAP_REGION(msHeapCurrent), INT64_MAX);
}

void msHeapReturnUnused(void) {
    if (msHeapCurrent) msHeapReturnOld(MS_HEAP_REGION(msHeapCurrent));
}

int msHeapIdleWaitMs(int waitMs) {
    msHeapHandle* here = msHeapCurrent;
    if (waitMs == 0 || !here) return waitMs;
    msHeapRegion* a = MS_HEAP_REGION(here);
    if (!a->returnDue && !a->empties) return waitMs;
    int64_t now = MS_HEAP_NOW_MS();
    msHeapAgeEmpties(a, now);
    if (!a->returnDue) return waitMs;
    int64_t left = a->returnDue - now;
    if (left < 1) left = 1;
    return waitMs < 0 || waitMs > left ? (int)left : waitMs;
}
#endif

static size_t msHeapUsable(void* p) {
    msHeapChunk* base = msHeapPage(p);
    if (base->size <= MS_HEAP_SMALL_ROOM) return base->size;
    return (uintptr_t)base + base->size - (uintptr_t)p;
}

static int msHeapGrowInPlace(void* p, size_t newSize, size_t* zeroFrom) {
    msHeapChunk* base = msHeapPage(p);
    if (base->size <= MS_HEAP_SMALL_ROOM || base->size > MS_HEAP_MAX_BIG) return 0;
#if MS_HEAP_THREADS
    if (base->owner != msHeapCurrent) return 0;
#endif
    size_t lead = (uintptr_t)p - (uintptr_t)base;
    if (newSize > MS_HEAP_MAX_BIG - lead) return 0;
    size_t bytes = msHeapRound(newSize + lead, MS_HEAP_PAGE_SIZE);
    msHeapBig* chunk = (msHeapBig*)base;
    msHeapRegion* a = MS_HEAP_REGION(base->owner);
    size_t oldBytes = chunk->base.size;
    uintptr_t address = (uintptr_t)chunk + oldBytes;
    if (!msHeapContains(a, address)) return 0;
    msHeapBig* right = (msHeapBig*)address;
    if ((right->base.prevSize & 1) || oldBytes + right->base.size < bytes) return 0;
    msHeapRemoveBig(a, right);
    msHeapRearm(a, right, bytes - oldBytes);
    size_t rightZeroed = right->zeroed & MS_HEAP_ZEROED;
    msHeapExclude(a, address);
    chunk->base.size = oldBytes + right->base.size;
    if (chunk->base.size >= bytes + MS_HEAP_PAGE_SIZE) {
        msHeapBig* rest = msHeapSplit(a, chunk, bytes);
        rest->zeroed = rightZeroed;
        if (rightZeroed) msHeapInsertBig(a, rest);
        else msHeapInsertUnused(a, rest, *msHeapUnusedSince(right));
    } else msHeapUpdateNext(a, chunk);
    a->occupied += chunk->base.size - oldBytes;
    *zeroFrom = rightZeroed ? oldBytes + offsetof(msHeapBig, data) - lead : newSize;
    return 1;
}

static void* msHeapResize(void* p, size_t newSize, size_t* zeroFrom) {
    *zeroFrom = newSize;
    if (!newSize) {
        msHeapFree(p);
        return NULL;
    }
    int zeroed;
    if (!p) {
        void* fresh = msHeapTakeTracked(newSize, &zeroed);
        if (zeroed) *zeroFrom = 0;
        return fresh;
    }
    size_t usable = msHeapUsable(p);
    if (newSize <= usable && newSize >= usable / 2) return p;
    if (newSize > usable && msHeapGrowInPlace(p, newSize, zeroFrom)) return p;
    void* result = msHeapTakeTracked(newSize, &zeroed);
    size_t kept = usable < newSize ? usable : newSize;
    msHeapCopy(result, p, kept);
    msHeapFree(p);
    if (zeroed) *zeroFrom = kept;
    return result;
}

void* msHeapRealloc(void* p, size_t oldSize, size_t newSize) {
    (void)oldSize;
    size_t zeroFrom;
    return msHeapResize(p, newSize, &zeroFrom);
}

void* msHeapRealloc0(void* p, size_t oldSize, size_t newSize) {
    size_t zeroFrom;
    void* result = msHeapResize(p, newSize, &zeroFrom);
    if (newSize > oldSize) {
        size_t end = zeroFrom < newSize ? zeroFrom : newSize;
        if (end > oldSize) msHeapZero((unsigned char*)result + oldSize, end - oldSize);
    }
    return result;
}

void msHeapReset(void) {
#if MS_HEAP_THREADS
    msHeapOutOfMemory();
#else
    msHeapZero(&msHeapOnly, sizeof(msHeapOnly));
    msHeapResetPages();
#endif
}

#endif
#endif
