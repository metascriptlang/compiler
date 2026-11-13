#undef MSOS_BARE
#undef MS_HEAP_USE_MALLOC
#define MS_HEAP_USE_MALLOC 0
#undef MS_ALLOCATOR_H
#define msHeapAlloc msHeapIdleProbeAlloc
#define msHeapCalloc msHeapIdleProbeCalloc
#define msHeapRealloc msHeapIdleProbeRealloc
#define msHeapRealloc0 msHeapIdleProbeRealloc0
#define msHeapFree msHeapIdleProbeFree
#define msHeapReset msHeapIdleProbeReset
#define msHeapThreadRelease msHeapIdleProbeRelease
#define msHeapThreadFlush msHeapIdleProbeFlush
#define msHeapTryAllocPages msHeapIdleProbeTryAllocPages
#define msHeapDeallocPages msHeapIdleProbeDeallocPages
#define msHeapResetPages msHeapIdleProbeResetPages
#define msHeapOutOfMemory msHeapIdleProbeOutOfMemory
#define msHeapReturnIdle msHeapIdleProbeReturnIdle
#define msHeapReturnUnused msHeapIdleProbeReturnUnused
#define msHeapIdleWaitMs msHeapIdleProbeWaitMs
#define msHeapDiscardPages msHeapIdleProbeDiscardPages
#define msHeapReusePages msHeapIdleProbeReusePages
#define msThreadAttach msHeapIdleProbeAttach
#include <stdint.h>
static int64_t probeNowMs = 1000300;
#define MS_HEAP_NOW_MS() probeNowMs
#include "../../../../runtime/allocator.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !MS_HEAP_THREADS
#error "allocatorIdleChecks needs the threaded allocator"
#endif

static const char* phase;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "GUARD-FAIL allocator idle %s line %d: %s\n", phase, __LINE__, #x); abort(); } } while (0)

/* The strictest page source: one reservation carved front to back, whose discarded pages fault
 * on any access until reused and come back holding 0xa5, the bytes no OS promises to clear. */
enum { RESERVED = 256 << 20, UNCLEARED = 0xa5 };
static unsigned char* reserved;
static size_t carved;
static size_t discardedBytes, reusedBytes;

#if defined(_WIN32)
typedef HANDLE probeThread;
typedef struct { void (*fn)(void*); void* arg; } probeStart;
static DWORD WINAPI probeTrampoline(LPVOID raw) { probeStart s = *(probeStart*)raw; free(raw); s.fn(s.arg); return 0; }
static probeThread probeSpawn(void (*fn)(void*), void* arg) {
    probeStart* s = malloc(sizeof *s); s->fn = fn; s->arg = arg;
    probeThread t = CreateThread(NULL, 0, probeTrampoline, s, 0, NULL); CHECK(t != NULL); return t;
}
static void probeJoin(probeThread t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
static void reserve(void) { reserved = VirtualAlloc(NULL, RESERVED, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE); CHECK(reserved != NULL); }
static void protectNone(void* p, size_t n) { DWORD old; CHECK(VirtualProtect(p, n, PAGE_NOACCESS, &old)); }
static int protectRw(void* p, size_t n) { DWORD old; return VirtualProtect(p, n, PAGE_READWRITE, &old) != 0; }
#else
#include <sys/mman.h>
#include <unistd.h>
typedef pthread_t probeThread;
typedef struct { void (*fn)(void*); void* arg; } probeStart;
static void* probeTrampoline(void* raw) { probeStart s = *(probeStart*)raw; free(raw); s.fn(s.arg); return NULL; }
static probeThread probeSpawn(void (*fn)(void*), void* arg) {
    probeStart* s = malloc(sizeof *s); s->fn = fn; s->arg = arg;
    probeThread t; CHECK(pthread_create(&t, NULL, probeTrampoline, s) == 0); return t;
}
static void probeJoin(probeThread t) { pthread_join(t, NULL); }
static void reserve(void) {
    reserved = mmap(NULL, RESERVED, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(reserved != MAP_FAILED);
}
static int osPages(void** p, size_t* n, int touched) {
    uintptr_t page = (uintptr_t)sysconf(_SC_PAGESIZE), grow = touched ? page - 1 : 0;
    if (!*n) return 0;
    uintptr_t start = ((uintptr_t)*p + page - 1 - grow) & ~(page - 1), end = ((uintptr_t)*p + *n + grow) & ~(page - 1);
    if (end <= start) return 0;
    *p = (void*)start; *n = end - start;
    return 1;
}
static void protectNone(void* p, size_t n) { if (osPages(&p, &n, 0)) CHECK(mprotect(p, n, PROT_NONE) == 0); }
static int protectRw(void* p, size_t n) { return !osPages(&p, &n, 1) || mprotect(p, n, PROT_READ | PROT_WRITE) == 0; }
#endif

void* msHeapTryAllocPages(size_t bytes) {
    size_t at = __atomic_fetch_add(&carved, bytes, __ATOMIC_RELAXED);
    return at + bytes <= RESERVED ? reserved + at : NULL;
}
void msHeapDeallocPages(void* p, size_t bytes) { (void)p; (void)bytes; }
void msHeapResetPages(void) {}
_Noreturn void msHeapOutOfMemory(void) { fprintf(stderr, "GUARD-FAIL allocator idle %s: out of memory\n", phase); abort(); }
void msThreadAttach(void) {}

void msHeapDiscardPages(void* p, size_t bytes) {
    CHECK(((uintptr_t)p & (MS_HEAP_PAGE_SIZE - 1)) == 0);
    CHECK(msHeapContains(MS_HEAP_REGION(msHeapCurrent), (uintptr_t)p) == 0);
    memset(p, UNCLEARED, bytes);
    protectNone(p, bytes);
    __atomic_add_fetch(&discardedBytes, bytes, __ATOMIC_RELAXED);
}

int msHeapReusePages(void* p, size_t bytes) {
    __atomic_add_fetch(&reusedBytes, bytes, __ATOMIC_RELAXED);
    return protectRw(p, bytes);
}

static void checkZeroWritable(unsigned char* p, size_t n) {
    for (size_t i = 0; i < n; ++i) CHECK(p[i] == 0);
    memset(p, 0x5a, n);
}

enum { MIB = 1 << 20, AGE_MS = MS_HEAP_RETURN_AFTER_MS + MS_HEAP_RETURN_STEP_MS };
static msHeapRegion* region(void) { return MS_HEAP_REGION(msHeapCurrent); }

/* A free chunk without the discarded flag must be readable on every page: a flag lost while
 * its pages were still discarded faults here. */
static void freeChunksReadable(void) {
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    for (unsigned fl = 0; fl < MS_HEAP_FL_COUNT; ++fl)
        for (unsigned sl = 0; sl < MS_HEAP_SL_COUNT; ++sl)
            for (msHeapBig* chunk = a->matrix[fl][sl]; chunk; chunk = chunk->next) {
                if (chunk->zeroed & MS_HEAP_DISCARDED) continue;
                volatile unsigned char* bytes = (volatile unsigned char*)chunk;
                for (size_t at = 0; at < chunk->base.size; at += MS_HEAP_PAGE_SIZE) (void)bytes[at];
            }
}

static void dirtyChunkGoesBack(void) {
    phase = "a dirty free big chunk goes back, a fresh one stays";
    unsigned char* first = msHeapAlloc(100 * 1024);
    msHeapBig* fresh = (msHeapBig*)((uintptr_t)msHeapPage(first) + msHeapPage(first)->size);
    CHECK(!(fresh->base.prevSize & 1) && fresh->zeroed == MS_HEAP_ZEROED && fresh->base.size >= 2 * MS_HEAP_DISCARD_MIN_BYTES);
    unsigned char* p = msHeapAlloc(MIB);
    memset(p, 0x5a, MIB);
    msHeapFree(p);
    CHECK(region()->returnDue != 0);
    size_t before = discardedBytes;
    msHeapReturnIdle();
    CHECK(region()->returnDue == 0);
    CHECK(discardedBytes - before >= MIB - MS_HEAP_PAGE_SIZE);
    CHECK(fresh->zeroed == MS_HEAP_ZEROED);
    before = discardedBytes;
    msHeapReturnIdle();
    CHECK(discardedBytes == before);
    msHeapFree(first);
}

static void discardedChunkReadsZero(void) {
    phase = "calloc of a discarded chunk reads zero";
    size_t before = reusedBytes;
    checkZeroWritable(msHeapCalloc(1, MIB), MIB);
    CHECK(reusedBytes > before);
}

static void splitOfDiscardedChunk(void) {
    phase = "the parts of a split discarded chunk read zero";
    msHeapReturnIdle();
    unsigned char* small = msHeapCalloc(1, 64 * 1024);
    checkZeroWritable(small, 64 * 1024);
    unsigned char* large = msHeapCalloc(1, 200 * 1024);
    checkZeroWritable(large, 200 * 1024);
    msHeapFree(small);
    msHeapFree(large);
}

/* Two used chunks of exactly the sizes a take would give, side by side between two used
 * chunks, split by hand from one allocation: which free chunk a take picks, and what lies on
 * either side of it, depend on what earlier phases left free. */
static int adjacentPair(size_t leftSize, size_t rightSize, unsigned char** left, unsigned char** right) {
    unsigned fl, sl;
    size_t leftBytes = msHeapSearchMapping(msHeapRound(leftSize + sizeof(msHeapBig), MS_HEAP_PAGE_SIZE), &fl, &sl);
    size_t rightBytes = msHeapSearchMapping(msHeapRound(rightSize + sizeof(msHeapBig), MS_HEAP_PAGE_SIZE), &fl, &sl);
    unsigned char* all = msHeapCalloc(1, 2 * MS_HEAP_PAGE_SIZE + leftBytes + rightBytes - sizeof(msHeapBig));
    msHeapBig* l = msHeapSplit(region(), (msHeapBig*)msHeapPage(all), MS_HEAP_PAGE_SIZE);
    msHeapBig* r = msHeapSplit(region(), l, leftBytes);
    msHeapBig* behind = msHeapSplit(region(), r, rightBytes);
    l->base.prevSize |= 1;
    r->base.prevSize |= 1;
    behind->base.prevSize |= 1;
    l->zeroed = r->zeroed = behind->zeroed = MS_HEAP_BIG_IN_USE;
    memset(l->data, 0, leftSize);
    memset(r->data, 0, rightSize);
    *left = l->data;
    *right = r->data;
    return 1;
}

static void coalesceWithDiscardedNeighbour(void) {
    enum { SIDE = 200 * 1024 };
    unsigned char* left;
    unsigned char* right;
    phase = "a chunk freed beside a discarded left neighbour leaves it discarded until both are";
    CHECK(adjacentPair(SIDE, SIDE, &left, &right));
    msHeapChunk* leftChunk = msHeapPage(left);
    msHeapFree(left);
    enum { FRONT = SIDE / 2, TRIES = 32 };
    unsigned char* fronts[TRIES];
    int front = -1;
    for (int i = 0; i < TRIES && front < 0; ++i) {
        fronts[i] = msHeapAlloc(FRONT);
        if (msHeapPage(fronts[i]) == leftChunk) front = i;
    }
    CHECK(front >= 0);
    for (int i = 0; i < front; ++i) msHeapFree(fronts[i]);
    msHeapBig* rest = (msHeapBig*)((uintptr_t)leftChunk + leftChunk->size);
    CHECK((uintptr_t)rest < (uintptr_t)msHeapPage(right) && !(rest->base.prevSize & 1));
    CHECK((msHeapPage(right)->prevSize & ~(size_t)1) == rest->base.size);
    msHeapReturnIdle();
    CHECK(rest->zeroed & MS_HEAP_DISCARDED);
    size_t restSize = rest->base.size, reused = reusedBytes;
    msHeapFree(right);
    CHECK(reusedBytes == reused && (rest->zeroed & MS_HEAP_DISCARDED) && rest->base.size == restSize);
    freeChunksReadable();
    probeNowMs += AGE_MS;
    msHeapReturnUnused();
    CHECK((rest->zeroed & MS_HEAP_DISCARDED) && rest->base.size >= restSize + SIDE);
    freeChunksReadable();
    checkZeroWritable(msHeapCalloc(1, SIDE), SIDE);
    msHeapFree(fronts[front]);
    phase = "a chunk freed beside a discarded right neighbour reads zero";
    CHECK(adjacentPair(SIDE, SIDE, &left, &right));
    msHeapBig* rightChunk = (msHeapBig*)msHeapPage(right);
    msHeapFree(right);
    msHeapReturnIdle();
    CHECK(rightChunk->zeroed & MS_HEAP_DISCARDED);
    msHeapFree(left);
    freeChunksReadable();
    checkZeroWritable(msHeapCalloc(1, 2 * SIDE), 2 * SIDE);
}

static void growIntoDiscardedNeighbour(void) {
    phase = "growing in place into a discarded neighbour re-arms the part it takes and reads zero";
    enum { LEFT = 100 * 1024, RIGHT = 2 * MIB, GROWN = 250 * 1024 };
    unsigned char* r;
    unsigned char* rightCell;
    CHECK(adjacentPair(LEFT, RIGHT, &r, &rightCell));
    memset(r, 0x77, LEFT);
    msHeapBig* right = (msHeapBig*)msHeapPage(rightCell);
    msHeapFree(rightCell);
    msHeapReturnIdle();
    CHECK(right->zeroed & MS_HEAP_DISCARDED);
    size_t reused = reusedBytes;
    unsigned char* grown = msHeapRealloc0(r, LEFT, LEFT + GROWN);
    CHECK(grown == r);
    CHECK(reusedBytes - reused <= GROWN + 2 * MS_HEAP_PAGE_SIZE);
    msHeapBig* rest = (msHeapBig*)((uintptr_t)msHeapPage(grown) + msHeapPage(grown)->size);
    CHECK(!(rest->base.prevSize & 1) && (rest->zeroed & MS_HEAP_DISCARDED));
    for (size_t i = 0; i < LEFT; ++i) CHECK(grown[i] == 0x77);
    checkZeroWritable(grown + LEFT, GROWN);
    msHeapFree(grown);
}

enum { HANDED = 64, ROUNDS = 40 };
static void* handed[HANDED];
static volatile int handedReady;
static void freeHanded(void* arg) {
    (void)arg;
    for (int round = 0; round < ROUNDS; ++round) {
        while (!__atomic_load_n(&handedReady, __ATOMIC_ACQUIRE)) {}
        for (int i = 0; i < HANDED; ++i) msHeapFree(handed[i]);
        __atomic_store_n(&handedReady, 0, __ATOMIC_RELEASE);
    }
    msHeapThreadRelease();
}

static void remoteFreesRaceIdleReturns(void) {
    phase = "remote big frees racing idle returns";
    probeThread t = probeSpawn(freeHanded, NULL);
    for (int round = 0; round < ROUNDS; ++round) {
        for (int i = 0; i < HANDED; ++i) {
            size_t n = (size_t)(16 + (i * 7 + round) % 48) * 4096;
            unsigned char* p = msHeapCalloc(1, n);
            checkZeroWritable(p, n);
            handed[i] = p;
        }
        __atomic_store_n(&handedReady, 1, __ATOMIC_RELEASE);
        while (__atomic_load_n(&handedReady, __ATOMIC_ACQUIRE)) msHeapReturnIdle();
    }
    probeJoin(t);
    msHeapReturnIdle();
    CHECK(MS_HEAP_REGION(msHeapCurrent)->received == NULL && __atomic_load_n(&msHeapCurrent->inbox, __ATOMIC_ACQUIRE) == NULL);
    checkZeroWritable(msHeapCalloc(1, 2 * MIB), 2 * MIB);
}

static void allocateFreeRelease(void* arg) {
    (void)arg;
    unsigned char* p = msHeapAlloc(MIB);
    memset(p, 0x5a, MIB);
    msHeapFree(p);
    msHeapThreadRelease();
}

static void releasingThreadReturnsPages(void) {
    phase = "a thread that releases its region returns its free pages";
    size_t before = discardedBytes;
    probeJoin(probeSpawn(allocateFreeRelease, NULL));
    CHECK(discardedBytes - before >= MIB - MS_HEAP_PAGE_SIZE);
}

static void unusedChunkWaitsItsAge(void) {
    phase = "a free chunk goes back once it stayed unused for the return age, on a turn that never waits";
    msHeapReturnIdle();
    unsigned char* p = msHeapAlloc(MIB);
    memset(p, 0x5a, MIB);
    msHeapFree(p);
    size_t before = discardedBytes;
    CHECK(msHeapIdleWaitMs(0) == 0);
    int wait = msHeapIdleWaitMs(-1);
    CHECK(wait > MS_HEAP_RETURN_AFTER_MS && wait <= AGE_MS && msHeapIdleWaitMs(wait + 1) == wait && msHeapIdleWaitMs(5) == 5);
    probeNowMs += wait - 1;
    msHeapReturnUnused();
    CHECK(discardedBytes == before && msHeapIdleWaitMs(-1) == 1);
    probeNowMs += 1;
    msHeapReturnUnused();
    CHECK(discardedBytes - before >= MIB - MS_HEAP_PAGE_SIZE && msHeapIdleWaitMs(-1) == -1);
}

static void splitRestKeepsItsAge(void) {
    phase = "the rest of a split chunk goes back when the whole chunk's age is reached";
    enum { WHOLE = 4 * MIB, TRIES = 32 };
    msHeapReturnIdle();
    unsigned char* p = msHeapAlloc(WHOLE);
    memset(p, 0x5a, WHOLE);
    msHeapFree(p);
    probeNowMs += AGE_MS - 1000;
    unsigned char* takes[TRIES];
    int inside = -1;
    for (int i = 0; i < TRIES && inside < 0; ++i) {
        takes[i] = msHeapAlloc(MIB);
        if (takes[i] >= p && takes[i] < p + WHOLE) inside = i;
    }
    CHECK(inside >= 0);
    size_t before = discardedBytes;
    probeNowMs += 1000;
    msHeapReturnUnused();
    CHECK(discardedBytes - before >= 2 * MIB);
    for (int i = 0; i <= inside; ++i) msHeapFree(takes[i]);
}

static void joinedChunkKeepsTheOlderAge(void) {
    phase = "a chunk joined to an older free neighbour goes back when the older one's age is reached";
    unsigned char* left;
    unsigned char* right;
    CHECK(adjacentPair(MIB, MIB, &left, &right));
    msHeapReturnIdle();
    msHeapFree(right);
    probeNowMs += AGE_MS - 1000;
    msHeapFree(left);
    size_t before = discardedBytes;
    probeNowMs += 1000;
    msHeapReturnUnused();
    CHECK(discardedBytes - before >= 2 * MIB - MS_HEAP_PAGE_SIZE);
}

static void laterChunkJoinsTheOlderOneOnItsLeft(void) {
    phase = "a chunk freed to the right of an older free one of its size goes back with it";
    unsigned char* left;
    unsigned char* right;
    CHECK(adjacentPair(MIB, MIB, &left, &right));
    msHeapChunk* joined = msHeapPage(left);
    msHeapReturnIdle();
    msHeapFree(left);
    probeNowMs += 5000;
    msHeapFree(right);
    CHECK(joined->size >= 2 * MIB && !msHeapContains(region(), (uintptr_t)msHeapPage(right)));
    probeNowMs += AGE_MS - 5000;
    size_t before = discardedBytes;
    msHeapReturnUnused();
    CHECK(discardedBytes - before >= 2 * MIB - MS_HEAP_PAGE_SIZE && msHeapIdleWaitMs(-1) == -1);
}

static void youngerChunkWaitsItsOwnAge(void) {
    phase = "a chunk freed later stays when an older one that it does not touch goes back";
    unsigned char* keptLeft;
    unsigned char* older;
    unsigned char* keptRight;
    unsigned char* right;
    CHECK(adjacentPair(MIB, MIB, &keptLeft, &older));
    CHECK(adjacentPair(MIB, MIB, &keptRight, &right));
    msHeapBig* younger = (msHeapBig*)msHeapPage(right);
    msHeapReturnIdle();
    msHeapFree(older);
    probeNowMs += 5000;
    msHeapFree(right);
    probeNowMs += AGE_MS - 5000;
    size_t before = discardedBytes;
    msHeapReturnUnused();
    CHECK(discardedBytes - before >= MIB - MS_HEAP_PAGE_SIZE && !younger->zeroed && msHeapIdleWaitMs(-1) == 5000);
    probeNowMs += 5000;
    msHeapReturnUnused();
    CHECK(discardedBytes - before >= 2 * MIB - 2 * MS_HEAP_PAGE_SIZE && msHeapIdleWaitMs(-1) == -1);
}

/* Takes the front of a free chunk as msHeapGetBig does. */
static msHeapBig* takeFront(msHeapBig* chunk, size_t size) {
    msHeapRegion* a = region();
    msHeapRemoveBig(a, chunk);
    msHeapInsertUnused(a, msHeapSplit(a, chunk, size), *msHeapUnusedSince(chunk));
    chunk->base.prevSize |= 1;
    chunk->zeroed = MS_HEAP_BIG_IN_USE;
    return chunk;
}

/* Frees a chunk without joining it, as the size cap of a big chunk leaves two free neighbours. */
static void freeUnjoined(msHeapBig* chunk) {
    chunk->base.prevSize &= ~(size_t)1;
    chunk->zeroed = 0;
    msHeapInsertUnused(region(), chunk, msHeapUnusedNow());
}

static void largeChunkKeepsItsAgeBesideAnOlderSmallOne(void) {
    phase = "a large chunk joined to an older small one waits its own age";
    enum { SMALL = 2 * MS_HEAP_PAGE_SIZE };
    unsigned char* fence;
    unsigned char* right;
    CHECK(adjacentPair(MIB, 4 * MIB, &fence, &right));
    msHeapBig* large = (msHeapBig*)msHeapPage(right);
    msHeapReturnIdle();
    msHeapFree(right);
    takeFront(large, large->base.size - SMALL);
    probeNowMs += AGE_MS - 1000;
    msHeapReleaseBig(region(), large);
    size_t before = discardedBytes;
    probeNowMs += 1000;
    msHeapReturnUnused();
    CHECK(discardedBytes == before && !large->zeroed);
    probeNowMs += AGE_MS;
    msHeapReturnUnused();
    CHECK(large->zeroed & MS_HEAP_DISCARDED);
    msHeapFree(fence);
}

static void smallChunkJoinsANeighbourDiscardedInTheSameReturn(void) {
    phase = "a small free chunk joins a neighbour that the same return discards";
    enum { SMALL = 2 * MS_HEAP_PAGE_SIZE };
    unsigned char* fence;
    unsigned char* right;
    CHECK(adjacentPair(MIB, 4 * MIB, &fence, &right));
    msHeapBig* small = (msHeapBig*)msHeapPage(right);
    msHeapReturnIdle();
    msHeapFree(right);
    takeFront(small, SMALL);
    msHeapBig* large = takeFront((msHeapBig*)((uintptr_t)small + SMALL), 2 * MIB);
    freeUnjoined(small);
    freeUnjoined(large);
    CHECK(small->base.size == SMALL && !small->zeroed && !large->zeroed && large->base.size >= 2 * MIB);
    probeNowMs += AGE_MS;
    msHeapReturnUnused();
    CHECK((small->zeroed & MS_HEAP_DISCARDED) && small->base.size >= SMALL + 2 * MIB && !msHeapContains(region(), (uintptr_t)large));
    msHeapFree(fence);
}

static void smallChunkBesideDiscardedJoinsIt(void) {
    phase = "a free chunk too small to discard joins a discarded neighbour once its age is reached";
    unsigned char* left;
    unsigned char* right;
    CHECK(adjacentPair(MIB, 2 * MIB, &left, &right));
    msHeapBig* chunk = (msHeapBig*)msHeapPage(right);
    msHeapFree(right);
    msHeapReturnIdle();
    CHECK(chunk->zeroed & MS_HEAP_DISCARDED);
    size_t whole = chunk->base.size;
    msHeapRemoveBig(region(), chunk);
    msHeapRearm(region(), chunk, MS_HEAP_PAGE_SIZE);
    msHeapReleaseBig(region(), chunk);
    uintptr_t rest = (uintptr_t)chunk + chunk->base.size;
    CHECK(chunk->base.size - MS_HEAP_PAGE_SIZE < MS_HEAP_DISCARD_MIN_BYTES && !chunk->zeroed && region()->returnDue != 0);
    probeNowMs += AGE_MS;
    msHeapReturnUnused();
    CHECK((chunk->zeroed & MS_HEAP_DISCARDED) && chunk->base.size == whole && !msHeapContains(region(), rest));
    msHeapFree(left);
}

static msHeapBig* chunkHolding(void* p) {
    uintptr_t at = (uintptr_t)msHeapPage(p);
    while (!msHeapContains(region(), at)) at -= MS_HEAP_PAGE_SIZE;
    return (msHeapBig*)at;
}

static int isSmallChunkOf(void* p, size_t cell) {
    msHeapChunk* page = msHeapPage(p);
    return msHeapContains(region(), (uintptr_t)page) && (page->prevSize & 1) && page->size == cell;
}

enum { SMALL_CELL = 1008, SMALL_PER_PAGE = 4, SMALL_CELLS = 4096, SMALL_RETAKEN = 1024 };
static void* smallCells[SMALL_CELLS];
static void* retaken[SMALL_RETAKEN];

static void emptiedSmallChunksGoBack(void) {
    phase = "small chunks emptied in any order go back once they stayed empty for the return age; one taken again stays";
    for (int i = 0; i < SMALL_CELLS; ++i) {
        smallCells[i] = msHeapAlloc(SMALL_CELL);
        memset(smallCells[i], 0x5a, SMALL_CELL);
    }
    msHeapReturnIdle();
    CHECK(region()->returnDue == 0);
    enum { LATER = SMALL_CELLS - SMALL_RETAKEN };
    for (int i = 0; i < LATER; ++i) msHeapFree(smallCells[SMALL_RETAKEN + (i * 37) % LATER]);
    for (int i = 0; i < SMALL_RETAKEN; ++i) msHeapFree(smallCells[(i * 37) % SMALL_RETAKEN]);
    CHECK(region()->empties != NULL && region()->agedEmpties == NULL);
    int wait = msHeapIdleWaitMs(-1);
    CHECK(wait > MS_HEAP_RETURN_AFTER_MS && wait <= AGE_MS);
    CHECK(region()->empties == NULL && region()->agedEmpties != NULL);
    for (int i = 0; i < SMALL_CELLS; ++i) CHECK(isSmallChunkOf(smallCells[i], SMALL_CELL));
    size_t carvedBefore = carved;
    for (int i = 0; i < SMALL_RETAKEN; ++i) {
        retaken[i] = msHeapAlloc(SMALL_CELL);
        memset(retaken[i], 0x5a, SMALL_CELL);
    }
    CHECK(carved == carvedBefore);
    probeNowMs += wait - 1;
    msHeapReturn(region(), probeNowMs);
    for (int i = 0; i < SMALL_CELLS; ++i) CHECK(isSmallChunkOf(smallCells[i], SMALL_CELL));
    CHECK(msHeapIdleWaitMs(-1) == 1);
    size_t before = discardedBytes;
    probeNowMs += 1;
    msHeapReturnUnused();
    int kept = 0;
    for (int i = 0; i < SMALL_CELLS; ++i) {
        if (isSmallChunkOf(smallCells[i], SMALL_CELL)) { ++kept; continue; }
        msHeapBig* chunk = chunkHolding(smallCells[i]);
        CHECK(!(chunk->base.prevSize & 1) && ((chunk->zeroed & MS_HEAP_DISCARDED) || !msHeapReturnable(region(), chunk)));
    }
    CHECK(kept >= SMALL_RETAKEN && kept <= SMALL_RETAKEN + SMALL_PER_PAGE);
    for (int i = 0; i < SMALL_RETAKEN; ++i) CHECK(isSmallChunkOf(retaken[i], SMALL_CELL));
    CHECK(discardedBytes - before >= 2 * MIB);
    freeChunksReadable();
    for (int i = 0; i < SMALL_CELLS; ++i) {
        smallCells[i] = msHeapAlloc(SMALL_CELL);
        memset(smallCells[i], 0x5a, SMALL_CELL);
    }
    for (int i = 0; i < SMALL_CELLS; ++i) msHeapFree(smallCells[i]);
    for (int i = 0; i < SMALL_RETAKEN; ++i) msHeapFree(retaken[i]);
}

static void* awayCell;
static int awayStep;
static void awaitStep(int step) { while (__atomic_load_n(&awayStep, __ATOMIC_ACQUIRE) != step) {} }
static void holdInBatch(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    msHeapFree(awayCell);
    __atomic_store_n(&awayStep, 1, __ATOMIC_RELEASE);
    awaitStep(2);
    msHeapThreadFlush();
    __atomic_store_n(&awayStep, 3, __ATOMIC_RELEASE);
    awaitStep(4);
    msHeapThreadRelease();
}

static void chunkWaitsForACellInAnotherThreadsBatch(void) {
    phase = "a small chunk whose last cell sits in another thread's open batch stays, and joins the big chunks once the cell is home";
    enum { CELL = 2016 };
    unsigned char* kept = msHeapAlloc(CELL);
    unsigned char* mate = msHeapAlloc(CELL);
    unsigned char* other = msHeapAlloc(CELL);
    msHeapSmall* home = (msHeapSmall*)msHeapPage(kept);
    CHECK((msHeapSmall*)msHeapPage(mate) == home && (msHeapSmall*)msHeapPage(other) != home);
    awayCell = kept;
    __atomic_store_n(&awayStep, 0, __ATOMIC_RELEASE);
    probeThread t = probeSpawn(holdInBatch, NULL);
    awaitStep(1);
    msHeapFree(mate);
    msHeapReturnIdle();
    CHECK(isSmallChunkOf(kept, CELL) && home->free == MS_HEAP_SMALL_ROOM - CELL);
    __atomic_store_n(&awayStep, 2, __ATOMIC_RELEASE);
    awaitStep(3);
    CHECK(isSmallChunkOf(kept, CELL) && home->free == MS_HEAP_SMALL_ROOM - CELL);
    msHeapReturnIdle();
    CHECK(!(chunkHolding(kept)->base.prevSize & 1));
    __atomic_store_n(&awayStep, 4, __ATOMIC_RELEASE);
    probeJoin(t);
    msHeapFree(other);
}

/* M10: the owner receives at most a batch's worth of blocks at a class's slow path. A chunk with a
 * cell still waiting in the owner's inbox is not empty, and the next return receives the rest and
 * releases the chunk. */
enum { WAIT_PER_PAGE = MS_HEAP_SMALL_ROOM / 16, WAIT_CELLS = 3 * WAIT_PER_PAGE };
_Static_assert(WAIT_CELLS > MS_HEAP_BATCH_BLOCKS && WAIT_CELLS < 2 * MS_HEAP_BATCH_BLOCKS &&
               MS_HEAP_REMOTE_BATCH_BYTES / 16 > MS_HEAP_BATCH_BLOCKS,
               "the waiting-cell phase needs one full batch and a second one");
static void* waitCells[WAIT_CELLS];
static void freeWaitCells(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    for (int i = 0; i < WAIT_CELLS; ++i) msHeapFree(waitCells[i]);
    msHeapThreadRelease();
}

static void chunkWaitsForACellItsOwnerHasNotReceived(void) {
    phase = "a small chunk with a cell its owner has not received yet stays until a return receives it";
    msHeapReturnIdle();
    for (int i = 0; i < WAIT_CELLS; ++i) waitCells[i] = msHeapAlloc(16);
    void* extra[WAIT_PER_PAGE];
    int extras = 0;
    while (region()->small[1]) {
        CHECK(extras < WAIT_PER_PAGE);
        extra[extras++] = msHeapAlloc(16);
    }
    probeJoin(probeSpawn(freeWaitCells, NULL));
    unsigned char* again = msHeapAlloc(16);
    msHeapBatch* left = region()->received;
    CHECK(left && region()->receivedAt + (WAIT_CELLS - MS_HEAP_BATCH_BLOCKS) == left->count);
    void* waiting = left->blocks[region()->receivedAt];
    msHeapSmall* home = (msHeapSmall*)msHeapPage(waiting);
    CHECK(isSmallChunkOf(waiting, 16) && home->free < MS_HEAP_SMALL_ROOM);
    for (msHeapCell* cell = home->freeList; cell; cell = cell->next) CHECK(cell != waiting);
    msHeapFree(again);
    for (int i = 0; i < extras; ++i) msHeapFree(extra[i]);
    msHeapReturnIdle();
    CHECK(region()->received == NULL && __atomic_load_n(&msHeapCurrent->inbox, __ATOMIC_ACQUIRE) == NULL);
    CHECK(!(chunkHolding(waiting)->base.prevSize & 1));
}

enum { TURN_CHUNKS = MS_HEAP_TURN_PAGES + 64 };
static unsigned char* turnCells[TURN_CHUNKS];
static int turnChunksLeft(void) {
    int left = 0;
    for (int i = 0; i < TURN_CHUNKS; ++i) left += isSmallChunkOf(turnCells[i], MS_HEAP_SMALL_ROOM);
    return left;
}

static void agedChunksLeaveATurnsShareAtATime(void) {
    phase = "a timed return releases one turn's share of aged empty chunks and the next turn takes the rest";
    for (int i = 0; i < TURN_CHUNKS; ++i) {
        turnCells[i] = msHeapAlloc(MS_HEAP_SMALL_ROOM);
        turnCells[i][0] = 1;
    }
    msHeapReturnIdle();
    CHECK(region()->returnDue == 0 && turnChunksLeft() == TURN_CHUNKS);
    for (int i = 0; i < TURN_CHUNKS; ++i) msHeapFree(turnCells[i]);
    int wait = msHeapIdleWaitMs(-1);
    CHECK(region()->agedEmpties != NULL && wait > MS_HEAP_RETURN_AFTER_MS && wait <= AGE_MS);
    probeNowMs += wait;
    msHeapReturnUnused();
    CHECK(turnChunksLeft() == TURN_CHUNKS - MS_HEAP_TURN_PAGES);
    CHECK(msHeapIdleWaitMs(-1) == 1);
    probeNowMs += 1;
    msHeapReturnUnused();
    CHECK(turnChunksLeft() == 1 && region()->agedEmpties == NULL);
}

static size_t pagesToDiscard(unsigned char** blocks, int count) {
    size_t pages = 0;
    for (int i = 0; i < count; ++i) {
        msHeapBig* chunk = chunkHolding(blocks[i]);
        int counted = 0;
        for (int j = 0; j < i; ++j) counted |= chunkHolding(blocks[j]) == chunk;
        if (!counted) pages += chunk->base.size / MS_HEAP_PAGE_SIZE - 1;
    }
    return pages;
}

static int turnsUntilNothingIsDue(void) {
    int turns = 0;
    while (msHeapIdleWaitMs(-1) == 1) {
        probeNowMs += 1;
        size_t before = discardedBytes;
        msHeapReturnUnused();
        CHECK(discardedBytes - before <= (size_t)MS_HEAP_TURN_PAGES * MS_HEAP_PAGE_SIZE);
        CHECK(++turns < 64);
    }
    return turns;
}

static void dueChunksGoBackATurnsShareAtATime(void) {
    phase = "a timed return discards one turn's share of due chunks and later turns take the rest";
    enum { BIGS = 24, BIG_PAGES = 512 };
    unsigned char* bigs[BIGS];
    unsigned char* walls[BIGS];
    msHeapReturnIdle();
    for (int i = 0; i < BIGS; ++i) {
        bigs[i] = msHeapAlloc(BIG_PAGES * MS_HEAP_PAGE_SIZE - sizeof(msHeapBig));
        walls[i] = msHeapAlloc(2 * MS_HEAP_PAGE_SIZE);
    }
    for (int i = 0; i < BIGS; ++i) msHeapFree(bigs[i]);
    size_t due = pagesToDiscard(bigs, BIGS);
    CHECK(due > MS_HEAP_TURN_PAGES);
    probeNowMs += AGE_MS;
    size_t before = discardedBytes;
    msHeapReturnUnused();
    CHECK(discardedBytes - before == (size_t)MS_HEAP_TURN_PAGES * MS_HEAP_PAGE_SIZE);
    int turns = 1 + turnsUntilNothingIsDue();
    size_t gone = (discardedBytes - before) / MS_HEAP_PAGE_SIZE;
    CHECK(turns > 1 && gone + turns > due);
    CHECK(region()->returnDue == 0);
    for (int i = 0; i < BIGS; ++i) CHECK(chunkHolding(bigs[i])->zeroed & MS_HEAP_DISCARDED);
    for (int i = 0; i < BIGS; ++i) msHeapFree(walls[i]);
    msHeapReturnIdle();
}

static void chunkLargerThanATurnsShareGoesBackInParts(void) {
    phase = "a due chunk larger than one turn's share goes back a share per turn and is one discarded chunk at the end";
    enum { PAGES = MS_HEAP_TURN_PAGES + MS_HEAP_TURN_PAGES / 2 };
    msHeapReturnIdle();
    unsigned char* p = msHeapAlloc((size_t)PAGES * MS_HEAP_PAGE_SIZE - sizeof(msHeapBig));
    unsigned char* wall = msHeapAlloc(2 * MS_HEAP_PAGE_SIZE);
    msHeapFree(p);
    size_t due = pagesToDiscard(&p, 1);
    CHECK(due >= PAGES - 1);
    probeNowMs += AGE_MS;
    size_t before = discardedBytes;
    msHeapReturnUnused();
    CHECK(discardedBytes - before == (size_t)MS_HEAP_TURN_PAGES * MS_HEAP_PAGE_SIZE);
    int turns = 1 + turnsUntilNothingIsDue();
    size_t gone = (discardedBytes - before) / MS_HEAP_PAGE_SIZE;
    CHECK(turns > 1 && gone + turns > due);
    CHECK(region()->returnDue == 0);
    msHeapBig* chunk = chunkHolding(p);
    CHECK((chunk->zeroed & MS_HEAP_DISCARDED) && chunk->base.size >= (due + 1) * MS_HEAP_PAGE_SIZE);
    size_t bytes = (size_t)PAGES * MS_HEAP_PAGE_SIZE - sizeof(msHeapBig);
    unsigned char* again = msHeapCalloc(1, bytes);
    checkZeroWritable(again, bytes);
    msHeapFree(again);
    msHeapFree(wall);
    msHeapReturnIdle();
}

enum { AWAY_CELLS = MS_HEAP_TURN_CELLS + 4096 };
static void* awayCells[AWAY_CELLS];
static void freeAwayCells(void* arg) {
    (void)arg;
    for (int i = 0; i < AWAY_CELLS; ++i) msHeapFree(awayCells[i]);
}

static size_t blocksNotFreed(void) {
    msHeapBatch* batch = region()->received;
    size_t left = batch ? batch->count - region()->receivedAt : 0;
    if (batch) for (batch = batch->next; batch; batch = batch->next) left += batch->count;
    return left;
}

static void remoteCellsGoHomeATurnsShareAtATime(void) {
    phase = "a timed return frees one turn's share of blocks other threads sent and the next turn the rest";
    msHeapReturnIdle();
    for (int i = 0; i < AWAY_CELLS; ++i) awayCells[i] = msHeapAlloc(MS_HEAP_ALIGN);
    probeJoin(probeSpawn(freeAwayCells, NULL));
    CHECK(region()->received == NULL);
    msHeapReturn(region(), probeNowMs);
    CHECK(blocksNotFreed() == AWAY_CELLS - MS_HEAP_TURN_CELLS);
    CHECK(msHeapIdleWaitMs(-1) == 1);
    probeNowMs += 1;
    msHeapReturnUnused();
    CHECK(region()->received == NULL);
    msHeapReturnIdle();
    CHECK(region()->returnDue == 0);
}

int32_t msAllocatorIdleChecks(void) {
    reserve();
    dirtyChunkGoesBack();
    freeChunksReadable();
    discardedChunkReadsZero();
    freeChunksReadable();
    splitOfDiscardedChunk();
    freeChunksReadable();
    coalesceWithDiscardedNeighbour();
    freeChunksReadable();
    growIntoDiscardedNeighbour();
    freeChunksReadable();
    remoteFreesRaceIdleReturns();
    freeChunksReadable();
    releasingThreadReturnsPages();
    unusedChunkWaitsItsAge();
    freeChunksReadable();
    splitRestKeepsItsAge();
    freeChunksReadable();
    joinedChunkKeepsTheOlderAge();
    freeChunksReadable();
    laterChunkJoinsTheOlderOneOnItsLeft();
    freeChunksReadable();
    youngerChunkWaitsItsOwnAge();
    freeChunksReadable();
    smallChunkBesideDiscardedJoinsIt();
    freeChunksReadable();
    smallChunkJoinsANeighbourDiscardedInTheSameReturn();
    freeChunksReadable();
    largeChunkKeepsItsAgeBesideAnOlderSmallOne();
    freeChunksReadable();
    emptiedSmallChunksGoBack();
    freeChunksReadable();
    chunkWaitsForACellInAnotherThreadsBatch();
    freeChunksReadable();
    chunkWaitsForACellItsOwnerHasNotReceived();
    freeChunksReadable();
    agedChunksLeaveATurnsShareAtATime();
    freeChunksReadable();
    dueChunksGoBackATurnsShareAtATime();
    freeChunksReadable();
    chunkLargerThanATurnsShareGoesBackInParts();
    freeChunksReadable();
    remoteCellsGoHomeATurnsShareAtATime();
    freeChunksReadable();
    return 0;
}
