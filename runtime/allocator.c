#include "allocator.h"

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
        fprintf(stderr, "Error: msHeapFree of %p, which the managed allocator did not allocate\n", p);
        abort();
    }
    block->tag = 0;
    return block;
}

void* msHeapAlloc(size_t size) {
    if (size > SIZE_MAX - sizeof(msHeapPairing)) msHeapOutOfMemory();
    return msHeapTag(malloc(sizeof(msHeapPairing) + size), size);
}

void* msHeapCalloc(size_t count, size_t size) {
    size_t bytes = msHeapProduct(count, size);
    if (bytes > SIZE_MAX - sizeof(msHeapPairing)) msHeapOutOfMemory();
    return msHeapTag(calloc(sizeof(msHeapPairing) + bytes, 1), bytes);
}

void* msHeapRealloc(void* p, size_t oldSize, size_t newSize) {
    (void)oldSize;
    if (!newSize) {
        if (p) free(msHeapUntag(p));
        return NULL;
    }
    if (newSize > SIZE_MAX - sizeof(msHeapPairing)) msHeapOutOfMemory();
    msHeapPairing* block = p ? msHeapUntag(p) : NULL;
    return msHeapTag(realloc(block, sizeof(msHeapPairing) + newSize), newSize);
}

void msHeapFree(void* p) { if (p) free(msHeapUntag(p)); }
void msHeapReset(void) {}
void msHeapThreadRelease(void) {}

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

void msHeapFree(void* p) { free(p); }
void msHeapReset(void) {}
void msHeapThreadRelease(void) {}

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
    MS_HEAP_MAX_REMOTE_BIG_STEPS = 20
};

#define MS_HEAP_MAX_BIG (((size_t)1 << 30) - ((size_t)1 << 24))

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

struct msHeapBig {
    msHeapChunk base;
    msHeapBig* next;
    msHeapBig* prev;
    _Alignas(16) unsigned char data[];
};

struct msHeapCell { msHeapCell* next; };

struct msHeapSmall {
    msHeapChunk base;
    msHeapSmall* next;
    msHeapSmall* prev;
    msHeapCell* freeList;
    uint32_t free;
    uint32_t acc;
    uint32_t foreignCells;
    uint32_t alignOffset;
    _Alignas(16) unsigned char data[];
};

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
};

struct msHeapHandle {
    msHeapCell* sharedCells[MS_HEAP_SMALL_CLASSES];
    msHeapBig* sharedBig;
    msHeapHandle* nextRetired;
    msHeapRegion region;
};

#define MS_HEAP_REGION(handle) (&(handle)->region)

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
    return handle;
}

static inline msHeapRegion* msHeapHere(void) {
    msHeapHandle* handle = msHeapCurrent;
    if (__builtin_expect(handle == NULL, 0)) handle = msHeapAcquire();
    return MS_HEAP_REGION(handle);
}

void msHeapThreadRelease(void) {
    msHeapHandle* handle = msHeapCurrent;
    if (!handle) return;
    msHeapCurrent = NULL;
    msHeapRetiredAcquire();
    handle->nextRetired = msHeapRetired;
    msHeapRetired = handle;
    msHeapRetiredReleaseLock();
}

static void msHeapPushRemoteCell(msHeapHandle* owner, size_t slot, msHeapCell* cell) {
    msHeapCell* head = __atomic_load_n(&owner->sharedCells[slot], __ATOMIC_RELAXED);
    do {
        cell->next = head;
    } while (!__atomic_compare_exchange_n(&owner->sharedCells[slot], &head, cell, 1,
                                          __ATOMIC_RELEASE, __ATOMIC_RELAXED));
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
    chunk->base.size = size;
    msHeapInclude(a, (uintptr_t)rest);
    msHeapUpdateNext(a, rest);
    return rest;
}

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
    size_t lastSize = a->lastSize ? a->lastSize : MS_HEAP_PAGE_SIZE;
    uintptr_t left = (uintptr_t)chunk - lastSize;
    if (msHeapContains(a, left) && ((msHeapChunk*)left)->size == lastSize)
        chunk->base.prevSize = lastSize;
    a->lastSize = size;
    msHeapUpdateNext(a, chunk);
    return chunk;
}

static msHeapBig* msHeapGetBig(msHeapRegion* a, size_t size) {
    unsigned fl, sl;
    size = msHeapSearchMapping(size, &fl, &sl);
    msHeapBig* chunk = msHeapFindBig(a, fl, sl);
    if (chunk) msHeapRemoveBig(a, chunk);
    else {
        size_t request = MS_HEAP_MIN_PAGES * (size_t)MS_HEAP_PAGE_SIZE;
        if (request < size) request = size;
        chunk = msHeapRequest(a, request);
    }
    if (chunk->base.size >= size + MS_HEAP_PAGE_SIZE)
        msHeapInsertBig(a, msHeapSplit(a, chunk, size));
    chunk->base.prevSize = 1;
    msHeapInclude(a, (uintptr_t)chunk);
    return chunk;
}

static void msHeapReleaseBig(msHeapRegion* a, msHeapBig* chunk) {
    chunk->base.prevSize &= ~(size_t)1;
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
            if (!(left->base.prevSize & 1) && left->base.size < MS_HEAP_MAX_BIG) {
                msHeapRemoveBig(a, left);
                left->base.size += chunk->base.size;
                msHeapExclude(a, (uintptr_t)chunk);
                chunk = left;
                if (chunk->base.size > MS_HEAP_MAX_BIG) {
                    msHeapBig* rest = msHeapSplit(a, chunk, MS_HEAP_MAX_BIG);
                    msHeapInsertBig(a, chunk);
                    chunk = rest;
                }
            }
        }
    }
    uintptr_t address = (uintptr_t)chunk + chunk->base.size;
    if (msHeapContains(a, address)) {
        msHeapBig* right = (msHeapBig*)address;
        if (!(right->base.prevSize & 1) && chunk->base.size < MS_HEAP_MAX_BIG) {
            msHeapRemoveBig(a, right);
            chunk->base.size += right->base.size;
            msHeapExclude(a, address);
            if (chunk->base.size > MS_HEAP_MAX_BIG)
                msHeapInsertBig(a, msHeapSplit(a, chunk, MS_HEAP_MAX_BIG));
        }
    }
    msHeapInsertBig(a, chunk);
}

static void msHeapDeallocBig(msHeapRegion* a, msHeapBig* chunk) {
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

#if MS_HEAP_THREADS
static void msHeapFetchRemoteCells(msHeapRegion* a, msHeapSmall* chunk) {
    if (chunk->freeList) return;
    msHeapCell** head = &msHeapOwnerOf(a)->sharedCells[chunk->base.size / MS_HEAP_ALIGN];
    if (!__atomic_load_n(head, __ATOMIC_RELAXED)) return;
    chunk->freeList = __atomic_exchange_n(head, NULL, __ATOMIC_ACQUIRE);
    size_t total = 0;
    for (msHeapCell* cell = chunk->freeList; cell; cell = cell->next) {
        total += chunk->base.size;
        if (msHeapPage(cell) != &chunk->base) ++chunk->foreignCells;
    }
    chunk->free += (uint32_t)total;
    a->occupied -= total;
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
#define msHeapFetchRemoteCells(a, chunk) ((void)0)
#define msHeapDrainRemoteBig(a) ((void)0)
#endif

void* msHeapAlloc(size_t size) {
    msHeapRegion* a = msHeapHere();
    size_t cellSize = msHeapRound(size ? size : 1, MS_HEAP_ALIGN);
    if (cellSize <= MS_HEAP_PAGE_SIZE - sizeof(msHeapSmall)) {
        msHeapSmall* chunk = a->small[cellSize / MS_HEAP_ALIGN];
        void* result;
        if (!chunk) {
            chunk = (msHeapSmall*)msHeapGetBig(a, MS_HEAP_PAGE_SIZE);
            chunk->base.size = cellSize;
            chunk->next = chunk->prev = NULL;
            chunk->freeList = NULL;
            chunk->foreignCells = chunk->alignOffset = 0;
            chunk->acc = (uint32_t)cellSize;
            chunk->free = (uint32_t)(MS_HEAP_PAGE_SIZE - sizeof(*chunk) - cellSize);
            msHeapFetchRemoteCells(a, chunk);
            if (chunk->free >= cellSize) msHeapInsertSmall(a, chunk);
            result = chunk->data;
        } else {
            if (chunk->freeList) {
                result = chunk->freeList;
                chunk->freeList = chunk->freeList->next;
                if (msHeapPage(result) != &chunk->base) --chunk->foreignCells;
            } else {
                result = chunk->data + chunk->acc;
                chunk->acc += (uint32_t)cellSize;
            }
            chunk->free -= (uint32_t)cellSize;
            msHeapFetchRemoteCells(a, chunk);
            if (chunk->free < cellSize) msHeapRemoveSmall(a, chunk);
        }
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
        msHeapInclude(a, (uintptr_t)chunk);
    } else chunk = msHeapGetBig(a, bytes);
    a->occupied += chunk->base.size;
    return chunk->data;
}

void* msHeapCalloc(size_t count, size_t size) {
    size_t bytes = msHeapProduct(count, size);
    void* p = msHeapAlloc(bytes);
    msHeapZero(p, bytes);
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
    if (base->size <= MS_HEAP_PAGE_SIZE - sizeof(msHeapSmall)) {
        size_t size = base->size;
#if MS_HEAP_THREADS
        if (owner != here) {
            msHeapPushRemoteCell(owner, size / MS_HEAP_ALIGN, p);
            return;
        }
#endif
        msHeapRegion* a = MS_HEAP_REGION(here);
        msHeapSmall* chunk = (msHeapSmall*)base;
        a->occupied -= size;
        msHeapCell* cell = p;
        msHeapSmall* active = a->small[size / MS_HEAP_ALIGN];
        if (active && active != chunk) {
            cell->next = active->freeList;
            active->freeList = cell;
            active->free += (uint32_t)size;
            ++active->foreignCells;
        } else {
            cell->next = chunk->freeList;
            chunk->freeList = cell;
            if (chunk->free < size) msHeapInsertSmall(a, chunk);
            chunk->free += (uint32_t)size;
        }
    } else {
#if MS_HEAP_THREADS
        if (owner != here) {
            msHeapPushRemoteBig(owner, (msHeapBig*)base);
            return;
        }
#endif
        msHeapDeallocBig(MS_HEAP_REGION(here), (msHeapBig*)base);
    }
}

void* msHeapRealloc(void* p, size_t oldSize, size_t newSize) {
    if (!newSize) {
        msHeapFree(p);
        return NULL;
    }
    void* result = msHeapAlloc(newSize);
    if (p) {
        msHeapCopy(result, p, oldSize < newSize ? oldSize : newSize);
        msHeapFree(p);
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
