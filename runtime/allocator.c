#include "allocator.h"

#if defined(MSOS_BARE) && !defined(MSOS_SOLANA)

#include <stdint.h>

static size_t msHeapProduct(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) msHeapOutOfMemory();
    return count * size;
}

#if MS_HEAP_USE_MALLOC

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

enum {
    MS_HEAP_ALIGN = 16,
    MS_HEAP_FL_OFFSET = 6,
    MS_HEAP_FL_COUNT = 24,
    MS_HEAP_SL_COUNT = 32,
    MS_HEAP_TRUNK_SHIFT = 9,
    MS_HEAP_TRUNK_BITS = 512,
    MS_HEAP_WORD_BITS = sizeof(uintptr_t) * 8,
    MS_HEAP_SMALL_CLASSES = MS_HEAP_PAGE_SIZE / MS_HEAP_ALIGN
};

#define MS_HEAP_MAX_BIG (((size_t)1 << 30) - ((size_t)1 << 24))

_Static_assert(MS_HEAP_MIN_PAGES > 0, "MS_HEAP_MIN_PAGES must be positive");
_Static_assert(MS_HEAP_MIN_PAGES <= MS_HEAP_MAX_BIG / MS_HEAP_PAGE_SIZE,
               "MS_HEAP_MIN_PAGES exceeds the chunk matrix");

typedef struct msHeapRegion msHeapRegion;
typedef struct msHeapBig msHeapBig;
typedef struct msHeapSmall msHeapSmall;
typedef struct msHeapCell msHeapCell;
typedef struct msHeapTrunk msHeapTrunk;
typedef struct msHeapSlab msHeapSlab;

typedef struct {
    size_t prevSize;
    size_t size;
    msHeapRegion* owner;
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
    size_t occupied;
    size_t nextChunkSize;
    size_t lastSize;
    int blockChunkGrowth;
};

static msHeapRegion msHeap;

static size_t msHeapRound(size_t size, size_t alignment) {
    if (size > SIZE_MAX - (alignment - 1)) msHeapOutOfMemory();
    return (size + alignment - 1) & ~(alignment - 1);
}

static void* msHeapAllocPages(size_t bytes) {
    void* p = msHeapTryAllocPages(bytes);
    if (!p) msHeapOutOfMemory();
    return p;
}

static void* msHeapMetadata(size_t size) {
    msHeapSlab* slab = msHeap.metadata;
    if (!slab || size > slab->remaining) {
        slab = msHeapAllocPages(MS_HEAP_PAGE_SIZE);
        slab->next = msHeap.metadata;
        slab->remaining = MS_HEAP_PAGE_SIZE - sizeof(*slab);
        slab->acc = sizeof(*slab);
        msHeap.metadata = slab;
    }
    void* result = (unsigned char*)slab + slab->acc;
    slab->acc += size;
    slab->remaining -= size;
    msHeapZero(result, size);
    return result;
}

static msHeapTrunk* msHeapFindTrunk(uintptr_t key) {
    msHeapTrunk* trunk = msHeap.starts[key & 255];
    while (trunk && trunk->key != key) trunk = trunk->next;
    return trunk;
}

static int msHeapContains(uintptr_t address) {
    uintptr_t page = address / MS_HEAP_PAGE_SIZE;
    msHeapTrunk* trunk = msHeapFindTrunk(page >> MS_HEAP_TRUNK_SHIFT);
    size_t bit = page & (MS_HEAP_TRUNK_BITS - 1);
    return trunk && (trunk->bits[bit / MS_HEAP_WORD_BITS] &
                     ((uintptr_t)1 << (bit % MS_HEAP_WORD_BITS))) != 0;
}

static void msHeapInclude(uintptr_t address) {
    uintptr_t page = address / MS_HEAP_PAGE_SIZE;
    uintptr_t key = page >> MS_HEAP_TRUNK_SHIFT;
    msHeapTrunk* trunk = msHeapFindTrunk(key);
    if (!trunk) {
        trunk = msHeapMetadata(sizeof(*trunk));
        trunk->key = key;
        trunk->next = msHeap.starts[key & 255];
        msHeap.starts[key & 255] = trunk;
    }
    size_t bit = page & (MS_HEAP_TRUNK_BITS - 1);
    trunk->bits[bit / MS_HEAP_WORD_BITS] |= (uintptr_t)1 << (bit % MS_HEAP_WORD_BITS);
}

static void msHeapExclude(uintptr_t address) {
    uintptr_t page = address / MS_HEAP_PAGE_SIZE;
    msHeapTrunk* trunk = msHeapFindTrunk(page >> MS_HEAP_TRUNK_SHIFT);
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

static void msHeapInsertBig(msHeapBig* chunk) {
    unsigned fl, sl;
    msHeapMapping(chunk->base.size, &fl, &sl);
    chunk->prev = NULL;
    chunk->next = msHeap.matrix[fl][sl];
    if (chunk->next) chunk->next->prev = chunk;
    msHeap.matrix[fl][sl] = chunk;
    msHeap.slBitmap[fl] |= (uint32_t)1 << sl;
    msHeap.flBitmap |= (uint32_t)1 << fl;
}

static void msHeapRemoveBig(msHeapBig* chunk) {
    unsigned fl, sl;
    msHeapMapping(chunk->base.size, &fl, &sl);
    if (chunk->next) chunk->next->prev = chunk->prev;
    if (chunk->prev) chunk->prev->next = chunk->next;
    else msHeap.matrix[fl][sl] = chunk->next;
    if (!msHeap.matrix[fl][sl]) {
        msHeap.slBitmap[fl] &= ~((uint32_t)1 << sl);
        if (!msHeap.slBitmap[fl]) msHeap.flBitmap &= ~((uint32_t)1 << fl);
    }
    chunk->next = chunk->prev = NULL;
}

static msHeapBig* msHeapFindBig(unsigned fl, unsigned sl) {
    uint32_t bits = msHeap.slBitmap[fl] & (UINT32_MAX << sl);
    if (!bits) {
        bits = msHeap.flBitmap & (UINT32_MAX << (fl + 1));
        if (!bits) return NULL;
        fl = msHeapLsBit(bits);
        bits = msHeap.slBitmap[fl];
    }
    return msHeap.matrix[fl][msHeapLsBit(bits)];
}

static void msHeapUpdateNext(msHeapBig* chunk) {
    uintptr_t address = (uintptr_t)chunk + chunk->base.size;
    if (msHeapContains(address)) {
        msHeapChunk* next = (msHeapChunk*)address;
        next->prevSize = chunk->base.size | (next->prevSize & 1);
    }
}

static msHeapBig* msHeapSplit(msHeapBig* chunk, size_t size) {
    msHeapBig* rest = (msHeapBig*)((unsigned char*)chunk + size);
    rest->base.size = chunk->base.size - size;
    rest->base.prevSize = size;
    rest->base.owner = &msHeap;
    rest->next = rest->prev = NULL;
    chunk->base.size = size;
    msHeapInclude((uintptr_t)rest);
    msHeapUpdateNext(rest);
    return rest;
}

static msHeapBig* msHeapRequest(size_t size) {
    if (!msHeap.blockChunkGrowth) {
        if (msHeap.occupied < 64 * 1024) msHeap.nextChunkSize = MS_HEAP_PAGE_SIZE * 4;
        else {
            size_t next = msHeapRound(msHeap.occupied >> 2, MS_HEAP_PAGE_SIZE);
            if (next > msHeap.nextChunkSize * 2) next = msHeap.nextChunkSize * 2;
            if (next > MS_HEAP_MAX_BIG) next = MS_HEAP_MAX_BIG;
            msHeap.nextChunkSize = next;
        }
    }
    msHeapBig* chunk;
    if (size > msHeap.nextChunkSize) chunk = msHeapAllocPages(size);
    else {
        chunk = msHeapTryAllocPages(msHeap.nextChunkSize);
        if (chunk) size = msHeap.nextChunkSize;
        else {
            chunk = msHeapAllocPages(size);
            msHeap.blockChunkGrowth = 1;
        }
    }
    chunk->base.size = size;
    chunk->base.owner = &msHeap;
    chunk->base.prevSize = 0;
    chunk->next = chunk->prev = NULL;
    size_t lastSize = msHeap.lastSize ? msHeap.lastSize : MS_HEAP_PAGE_SIZE;
    uintptr_t left = (uintptr_t)chunk - lastSize;
    if (msHeapContains(left) && ((msHeapChunk*)left)->size == lastSize)
        chunk->base.prevSize = lastSize;
    msHeap.lastSize = size;
    msHeapUpdateNext(chunk);
    return chunk;
}

static msHeapBig* msHeapGetBig(size_t size) {
    unsigned fl, sl;
    size = msHeapSearchMapping(size, &fl, &sl);
    msHeapBig* chunk = msHeapFindBig(fl, sl);
    if (chunk) msHeapRemoveBig(chunk);
    else {
        size_t request = MS_HEAP_MIN_PAGES * (size_t)MS_HEAP_PAGE_SIZE;
        if (request < size) request = size;
        chunk = msHeapRequest(request);
    }
    if (chunk->base.size >= size + MS_HEAP_PAGE_SIZE)
        msHeapInsertBig(msHeapSplit(chunk, size));
    chunk->base.prevSize = 1;
    msHeapInclude((uintptr_t)chunk);
    return chunk;
}

static void msHeapReleaseBig(msHeapBig* chunk) {
    chunk->base.prevSize &= ~(size_t)1;
    if (chunk->base.size > MS_HEAP_MAX_BIG) {
        msHeapExclude((uintptr_t)chunk);
        msHeapDeallocPages(chunk, chunk->base.size);
        return;
    }
    size_t prevSize = chunk->base.prevSize;
    if (prevSize) {
        uintptr_t address = (uintptr_t)chunk - prevSize;
        if (msHeapContains(address)) {
            msHeapBig* left = (msHeapBig*)address;
            if (!(left->base.prevSize & 1) && left->base.size < MS_HEAP_MAX_BIG) {
                msHeapRemoveBig(left);
                left->base.size += chunk->base.size;
                msHeapExclude((uintptr_t)chunk);
                chunk = left;
                if (chunk->base.size > MS_HEAP_MAX_BIG) {
                    msHeapBig* rest = msHeapSplit(chunk, MS_HEAP_MAX_BIG);
                    msHeapInsertBig(chunk);
                    chunk = rest;
                }
            }
        }
    }
    uintptr_t address = (uintptr_t)chunk + chunk->base.size;
    if (msHeapContains(address)) {
        msHeapBig* right = (msHeapBig*)address;
        if (!(right->base.prevSize & 1) && chunk->base.size < MS_HEAP_MAX_BIG) {
            msHeapRemoveBig(right);
            chunk->base.size += right->base.size;
            msHeapExclude(address);
            if (chunk->base.size > MS_HEAP_MAX_BIG)
                msHeapInsertBig(msHeapSplit(chunk, MS_HEAP_MAX_BIG));
        }
    }
    msHeapInsertBig(chunk);
}

static void msHeapInsertSmall(msHeapSmall* chunk) {
    size_t slot = chunk->base.size / MS_HEAP_ALIGN;
    chunk->prev = NULL;
    chunk->next = msHeap.small[slot];
    if (chunk->next) chunk->next->prev = chunk;
    msHeap.small[slot] = chunk;
}

static void msHeapRemoveSmall(msHeapSmall* chunk) {
    size_t slot = chunk->base.size / MS_HEAP_ALIGN;
    if (chunk->next) chunk->next->prev = chunk->prev;
    if (chunk->prev) chunk->prev->next = chunk->next;
    else msHeap.small[slot] = chunk->next;
    chunk->next = chunk->prev = NULL;
}

static msHeapChunk* msHeapPage(void* p) {
    return (msHeapChunk*)((uintptr_t)p & ~((uintptr_t)MS_HEAP_PAGE_SIZE - 1));
}

void* msHeapAlloc(size_t size) {
    size_t cellSize = msHeapRound(size ? size : 1, MS_HEAP_ALIGN);
    if (cellSize <= MS_HEAP_PAGE_SIZE - sizeof(msHeapSmall)) {
        msHeapSmall* chunk = msHeap.small[cellSize / MS_HEAP_ALIGN];
        void* result;
        if (!chunk) {
            chunk = (msHeapSmall*)msHeapGetBig(MS_HEAP_PAGE_SIZE);
            chunk->base.size = cellSize;
            chunk->next = chunk->prev = NULL;
            chunk->freeList = NULL;
            chunk->foreignCells = chunk->alignOffset = 0;
            chunk->acc = (uint32_t)cellSize;
            chunk->free = (uint32_t)(MS_HEAP_PAGE_SIZE - sizeof(*chunk) - cellSize);
            if (chunk->free >= cellSize) msHeapInsertSmall(chunk);
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
            if (chunk->free < cellSize) msHeapRemoveSmall(chunk);
        }
        msHeap.occupied += cellSize;
        return result;
    }
    if (size > SIZE_MAX - sizeof(msHeapBig)) msHeapOutOfMemory();
    size_t bytes = msHeapRound(size + sizeof(msHeapBig), MS_HEAP_PAGE_SIZE);
    msHeapBig* chunk;
    if (bytes > MS_HEAP_MAX_BIG) {
        chunk = msHeapAllocPages(bytes);
        chunk->base.size = bytes;
        chunk->base.prevSize = 1;
        chunk->base.owner = &msHeap;
        chunk->next = chunk->prev = NULL;
        msHeapInclude((uintptr_t)chunk);
    } else chunk = msHeapGetBig(bytes);
    msHeap.occupied += chunk->base.size;
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
    if (base->size <= MS_HEAP_PAGE_SIZE - sizeof(msHeapSmall)) {
        msHeapSmall* chunk = (msHeapSmall*)base;
        size_t size = base->size;
        msHeap.occupied -= size;
        msHeapCell* cell = p;
        msHeapSmall* active = msHeap.small[size / MS_HEAP_ALIGN];
        if (active && active != chunk) {
            cell->next = active->freeList;
            active->freeList = cell;
            active->free += (uint32_t)size;
            ++active->foreignCells;
        } else {
            cell->next = chunk->freeList;
            chunk->freeList = cell;
            if (chunk->free < size) msHeapInsertSmall(chunk);
            chunk->free += (uint32_t)size;
        }
    } else {
        msHeap.occupied -= base->size;
        msHeapReleaseBig((msHeapBig*)base);
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
    msHeapZero(&msHeap, sizeof(msHeap));
    msHeapResetPages();
}

#endif
#endif
