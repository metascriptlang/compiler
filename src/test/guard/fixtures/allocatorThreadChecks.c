#undef MSOS_BARE
#undef MS_HEAP_USE_MALLOC
#define MS_HEAP_USE_MALLOC 0
#undef MS_ALLOCATOR_H
#define msHeapAlloc msHeapThreadProbeAlloc
#define msHeapCalloc msHeapThreadProbeCalloc
#define msHeapRealloc msHeapThreadProbeRealloc
#define msHeapRealloc0 msHeapThreadProbeRealloc0
#define msHeapFree msHeapThreadProbeFree
#define msHeapReset msHeapThreadProbeReset
#define msHeapThreadRelease msHeapThreadProbeRelease
#define msHeapThreadFlush msHeapThreadProbeFlush
#define msHeapTryAllocPages msHeapThreadProbeTryAllocPages
#define msHeapDeallocPages msHeapThreadProbeDeallocPages
#define msHeapResetPages msHeapThreadProbeResetPages
#define msHeapOutOfMemory msHeapThreadProbeOutOfMemory
#define msThreadAttach msHeapThreadProbeAttach
#define msHeapReturnIdle msHeapThreadProbeReturnIdle
#define msHeapReturnUnused msHeapThreadProbeReturnUnused
#define msHeapIdleWaitMs msHeapThreadProbeIdleWaitMs
#define msHeapDiscardPages msHeapThreadProbeDiscardPages
#define msHeapReusePages msHeapThreadProbeReusePages
#define msHeapFreedTwice msHeapThreadProbeFreedTwice
#define msHeapKeepFirstPage msHeapThreadProbeKeepFirstPage
#define msHeapDropFirstPage msHeapThreadProbeDropFirstPage
#define MS_HEAP_KEPT_FIRST_PAGES 2
#include "../../../../runtime/allocator.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

#if !MS_HEAP_THREADS
#error "allocatorThreadChecks needs the threaded allocator"
#endif

static const char* phase;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "GUARD-FAIL allocator threads %s line %d: %s\n", phase, __LINE__, #x); abort(); } } while (0)

#if defined(_WIN32)
void* msHeapTryAllocPages(size_t bytes) { return VirtualAlloc(NULL, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE); }
void msHeapDeallocPages(void* p, size_t bytes) { (void)bytes; VirtualFree(p, 0, MEM_RELEASE); }
typedef HANDLE probeThread;
typedef struct { void (*fn)(void*); void* arg; } probeStart;
static DWORD WINAPI probeTrampoline(LPVOID raw) { probeStart s = *(probeStart*)raw; free(raw); s.fn(s.arg); return 0; }
static probeThread probeSpawn(void (*fn)(void*), void* arg) {
    probeStart* s = malloc(sizeof *s); s->fn = fn; s->arg = arg;
    probeThread t = CreateThread(NULL, 0, probeTrampoline, s, 0, NULL); CHECK(t != NULL); return t;
}
static void probeJoin(probeThread t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
void msHeapKeepFirstPage(void* p, size_t bytes) {
    CHECK(VirtualFree(p, bytes, MEM_DECOMMIT) && VirtualAlloc(p, MS_HEAP_PAGE_SIZE, MEM_COMMIT, PAGE_READONLY));
}
static void dropPage(void* p) { VirtualFree(p, 0, MEM_RELEASE); }
#else
#include <sys/mman.h>
void* msHeapTryAllocPages(size_t bytes) {
    void* p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}
void msHeapDeallocPages(void* p, size_t bytes) { munmap(p, bytes); }
typedef pthread_t probeThread;
typedef struct { void (*fn)(void*); void* arg; } probeStart;
static void* probeTrampoline(void* raw) { probeStart s = *(probeStart*)raw; free(raw); s.fn(s.arg); return NULL; }
static probeThread probeSpawn(void (*fn)(void*), void* arg) {
    probeStart* s = malloc(sizeof *s); s->fn = fn; s->arg = arg;
    probeThread t; CHECK(pthread_create(&t, NULL, probeTrampoline, s) == 0); return t;
}
static void probeJoin(probeThread t) { pthread_join(t, NULL); }
#include <unistd.h>
void msHeapKeepFirstPage(void* p, size_t bytes) {
    size_t first = (size_t)sysconf(_SC_PAGESIZE);
    munmap((unsigned char*)p + first, bytes - first);
    CHECK(mmap(p, first, PROT_READ, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == p);
}
static void dropPage(void* p) { munmap(p, (size_t)sysconf(_SC_PAGESIZE)); }
#endif
static int droppedPages;
void msHeapDropFirstPage(void* p, size_t bytes) { (void)bytes; ++droppedPages; dropPage(p); }
void msHeapResetPages(void) {}
_Noreturn void msHeapOutOfMemory(void) { fprintf(stderr, "GUARD-FAIL allocator threads: out of memory\n"); abort(); }
void msHeapDiscardPages(void* p, size_t bytes) { (void)p; (void)bytes; }
int msHeapReusePages(void* p, size_t bytes) { (void)p; (void)bytes; return 1; }
static int attachCalls;
void msThreadAttach(void) { __atomic_add_fetch(&attachCalls, 1, __ATOMIC_RELAXED); }

static unsigned refusals;
static _Thread_local int expectingRefusal;
static _Thread_local jmp_buf refusal;
static _Thread_local int refusedHere;
_Noreturn void msHeapFreedTwice(void* p) {
    __atomic_add_fetch(&refusals, 1, __ATOMIC_RELAXED);
    refusedHere = 1;
    if (expectingRefusal) longjmp(refusal, 1);
    fprintf(stderr, "GUARD-FAIL allocator threads %s: the free of %p was refused\n", phase, p);
    abort();
}

/* A return receives everything sent to the owner; `refused` says whether one of those blocks is
 * refused there, on the owner's thread. */
static void receivingRefusesOnce(int refused) {
    unsigned before = refusals;
    expectingRefusal = 1;
    if (!setjmp(refusal)) msHeapReturnIdle();
    expectingRefusal = 0;
    msHeapReturnIdle();
    CHECK(refusals == before + (unsigned)refused);
}

/* Every byte of a block another thread freed reads as before but the claim: a small cell's mark
 * word holds its chunk's sent mark, and a big chunk's payload is untouched. */
static void checkUntouchedButClaim(unsigned char* p, size_t n, unsigned char byte) {
    msHeapChunk* base = msHeapPage(p);
    int small = base->size <= MS_HEAP_SMALL_ROOM;
    for (size_t i = 0; i < n; ++i)
        if (!small || i < offsetof(msHeapCell, mark) || i >= sizeof(msHeapCell)) CHECK(p[i] == byte);
    if (small) CHECK(msHeapMarkOf((msHeapCell*)p) == msHeapSentMark((msHeapSmall*)base));
    else CHECK(msHeapBigState((msHeapBig*)base) == MS_HEAP_BIG_SENT);
}

enum { CELLS = 600, BIG = 64 * 1024 };
_Static_assert(CELLS >= 100 + MS_HEAP_REMOTE_BATCH_BYTES / 48 + 2, "remoteRuns needs a run, a cap's worth and one more cell");
static void* cells[CELLS];
static void* bigs[8];

static void freeCells(void* arg) {
    (void)arg;
    for (int i = 0; i < CELLS; ++i) msHeapFree(cells[i]);
}

static void freeBigs(void* arg) {
    (void)arg;
    for (int i = 0; i < 8; ++i) msHeapFree(bigs[i]);
}

static int inSet(void* p, void** set, int n) {
    for (int i = 0; i < n; ++i) if (set[i] == p) return 1;
    return 0;
}

static int inPages(void* p, void** set, int n) {
    for (int i = 0; i < n; ++i) if (msHeapPage(set[i]) == msHeapPage(p)) return 1;
    return 0;
}

/* M10: a cell another thread frees goes onto the owner's shared list, and the
 * owner reuses it once its active chunk has no free cell; calloc zeroes it. */
static void remoteSmallReuse(void) {
    phase = "remote small reuse";
    for (int i = 0; i < CELLS; ++i) { cells[i] = msHeapAlloc(48); memset(cells[i], 0x5a, 48); }
    size_t before = MS_HEAP_REGION(msHeapCurrent)->occupied;
    probeJoin(probeSpawn(freeCells, NULL));
    CHECK(MS_HEAP_REGION(msHeapCurrent)->occupied == before);
    void* again[CELLS];
    int reused = 0;
    for (int i = 0; i < CELLS; ++i) {
        again[i] = msHeapCalloc(1, 48);
        reused += inSet(again[i], cells, CELLS);
        for (int b = 0; b < 48; ++b) CHECK(((unsigned char*)again[i])[b] == 0);
    }
    CHECK(reused > CELLS / 2);
    for (int i = 0; i < CELLS; ++i) msHeapFree(again[i]);
}

/* M10: a thread with its own region gathers the addresses it frees for one owner into a batch, a
 * small cell of its own region, which reaches the owner's inbox in one CAS when the thread flushes,
 * parks or exits, when the batch is full, or when its batches hold 16 KiB of freed blocks; it writes
 * the batch and the claim, nothing else of the blocks, and gets the batch back once the owner has
 * freed them. */
enum { RUN_CELLS = 20, WIDE = 1504, CAP_CELLS = MS_HEAP_REMOTE_BATCH_BYTES / WIDE + 1, RUN_TOTAL = RUN_CELLS + MS_HEAP_BATCH_BLOCKS + CAP_CELLS + 1 };
_Static_assert(RUN_CELLS < MS_HEAP_BATCH_BLOCKS && CAP_CELLS < MS_HEAP_BATCH_BLOCKS &&
               (MS_HEAP_BATCH_BLOCKS + 1) * 48 < MS_HEAP_REMOTE_BATCH_BYTES, "remoteBatches needs each rule to post its own batch");
static size_t cellSize(int i) { return i >= RUN_CELLS + (int)MS_HEAP_BATCH_BLOCKS && i < RUN_TOTAL - 1 ? WIDE : 48; }
static msHeapHandle* batchOwner;
static msHeapHandle* batchSender;
static void freeIntoBatches(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    batchSender = msHeapCurrent;
    msHeapBatch** inbox = &batchOwner->inbox;
    for (int i = 0; i < RUN_CELLS; ++i) msHeapFree(cells[i]);
    CHECK(__atomic_load_n(inbox, __ATOMIC_ACQUIRE) == NULL);
    msHeapThreadFlush();
    msHeapBatch* head = __atomic_load_n(inbox, __ATOMIC_ACQUIRE);
    CHECK(head && head->count == RUN_CELLS && head->next == NULL && head->owner == batchOwner);
    for (int i = 0; i < RUN_CELLS; ++i) CHECK(head->blocks[i] == cells[i]);
    int at = RUN_CELLS;
    for (int i = 0; i < (int)MS_HEAP_BATCH_BLOCKS; ++i) msHeapFree(cells[at + i]);
    head = __atomic_load_n(inbox, __ATOMIC_ACQUIRE);
    CHECK(head->count == MS_HEAP_BATCH_BLOCKS && head->blocks[0] == cells[at]);
    at += MS_HEAP_BATCH_BLOCKS;
    for (int i = 0; i < CAP_CELLS; ++i) msHeapFree(cells[at + i]);
    head = __atomic_load_n(inbox, __ATOMIC_ACQUIRE);
    CHECK(head->count == CAP_CELLS && head->blocks[0] == cells[at]);
    msHeapFree(cells[RUN_TOTAL - 1]);
    CHECK(__atomic_load_n(inbox, __ATOMIC_ACQUIRE) == head);
    msHeapThreadRelease();
}

static int batchesIn(msHeapBatch* batch) {
    int n = 0;
    for (; batch; batch = batch->next) ++n;
    return n;
}

static void remoteBatches(void) {
    phase = "remote batches";
    batchOwner = msHeapCurrent;
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    msHeapReturnIdle();
    CHECK(__atomic_load_n(&batchOwner->inbox, __ATOMIC_ACQUIRE) == NULL);
    size_t before = a->occupied;
    for (int i = 0; i < RUN_TOTAL; ++i) { cells[i] = msHeapAlloc(cellSize(i)); memset(cells[i], 0x4e, cellSize(i)); }
    probeJoin(probeSpawn(freeIntoBatches, NULL));
    msHeapBatch* head = __atomic_load_n(&batchOwner->inbox, __ATOMIC_ACQUIRE);
    CHECK(head->count == 1 && head->blocks[0] == cells[RUN_TOTAL - 1] && batchesIn(head) == 4);
    for (int i = 0; i < RUN_TOTAL; ++i) checkUntouchedButClaim(cells[i], cellSize(i), 0x4e);
    int reused = 0;
    void* again[RUN_TOTAL];
    for (int i = 0; i < RUN_TOTAL; ++i) {
        again[i] = msHeapAlloc(cellSize(i));
        reused += inSet(again[i], cells, RUN_TOTAL);
    }
    CHECK(reused > RUN_TOTAL / 2);
    for (int i = 0; i < RUN_TOTAL; ++i) msHeapFree(again[i]);
    msHeapReturnIdle();
    CHECK(a->occupied == before && a->received == NULL);
    CHECK(batchesIn(__atomic_load_n(&batchSender->returned, __ATOMIC_ACQUIRE)) + batchesIn(batchSender->idle) == 4);
}

/* M10: a thread without a region holds back no more than 16 KiB either, so each 64 KiB chunk it
 * frees reaches the owner's inbox at once; the owner's next big allocation receives them and
 * reuses their pages, which calloc zeroes. */
static void remoteBigReuse(void) {
    phase = "remote big reuse";
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    msHeapReturnIdle();
    size_t before = a->occupied;
    for (int i = 0; i < 8; ++i) { bigs[i] = msHeapAlloc(BIG); memset(bigs[i], 0x5a, BIG); }
    probeJoin(probeSpawn(freeBigs, NULL));
    CHECK(batchesIn(__atomic_load_n(&msHeapCurrent->inbox, __ATOMIC_ACQUIRE)) == 8 && __atomic_load_n(&msHeapAloneHeld, __ATOMIC_ACQUIRE) == 0);
    void* again = msHeapCalloc(1, BIG);
    CHECK(inPages(again, (void**)bigs, 8));
    for (int b = 0; b < BIG; ++b) CHECK(((unsigned char*)again)[b] == 0);
    CHECK(msHeapCurrent->inbox == NULL && a->received == NULL && msHeapAloneHeld == 0);
    CHECK(a->occupied == before + msHeapPage(again)->size);
    msHeapFree(again);
    CHECK(a->occupied == before);
}

/* A thread that does not own a big chunk never grows it in place, because that
 * edits the owner's region; it moves the bytes instead. */
static unsigned char* reallocTarget;
static void reallocElsewhere(void* arg) {
    (void)arg;
    reallocTarget = msHeapRealloc(reallocTarget, BIG, 4 * BIG);
    for (int b = 0; b < BIG; ++b) CHECK(reallocTarget[b] == 0x6b);
    msHeapThreadRelease();
}

static void foreignRealloc(void) {
    phase = "realloc from a thread that does not own the chunk";
    unsigned char* original = msHeapAlloc(BIG);
    memset(original, 0x6b, BIG);
    reallocTarget = original;
    probeJoin(probeSpawn(reallocElsewhere, NULL));
    CHECK(reallocTarget != original);
    for (int b = 0; b < BIG; ++b) CHECK(reallocTarget[b] == 0x6b);
    msHeapFree(reallocTarget);
}

/* M10 stress: every thread allocates, stamps and hands cells to its neighbour,
 * which checks the stamp and frees them; sizes cover small classes and big chunks. */
enum { WORKERS = 8, ROUNDS = 2000, SLOTS = 64 };
typedef struct { void* p; size_t size; unsigned stamp; } handoff;
static handoff mailbox[WORKERS][SLOTS];
static int mailboxFull[WORKERS][SLOTS];

static void stressWorker(void* arg) {
    int self = (int)(intptr_t)arg;
    int next = (self + 1) % WORKERS;
    unsigned seed = (unsigned)self * 2654435761u + 1;
    for (int r = 0; r < ROUNDS; ++r) {
        for (int s = 0; s < SLOTS; ++s) {
            if (__atomic_load_n(&mailboxFull[self][s], __ATOMIC_ACQUIRE)) {
                handoff h = mailbox[self][s];
                unsigned char* bytes = h.p;
                for (size_t i = 0; i < h.size; i += 61) CHECK(bytes[i] == (unsigned char)h.stamp);
                msHeapFree(h.p);
                __atomic_store_n(&mailboxFull[self][s], 0, __ATOMIC_RELEASE);
            }
        }
        int slot = (int)((seed >> 8) % SLOTS);
        seed = seed * 1103515245u + 12345u;
        if (!__atomic_load_n(&mailboxFull[next][slot], __ATOMIC_ACQUIRE)) {
            size_t size = (seed >> 4) % 7 == 0 ? 5000 + (seed % 70000) : 1 + (seed >> 12) % 900;
            unsigned char* p = msHeapAlloc(size);
            memset(p, (unsigned char)seed, size);
            mailbox[next][slot] = (handoff){ p, size, (unsigned char)seed };
            __atomic_store_n(&mailboxFull[next][slot], 1, __ATOMIC_RELEASE);
        }
        void* local = msHeapAlloc(32 + (seed % 200));
        msHeapFree(local);
        if (r % 128 == 127) msHeapReturnIdle();
    }
    msHeapThreadRelease();
}

static void stress(void) {
    phase = "stress";
    probeThread threads[WORKERS];
    for (int i = 0; i < WORKERS; ++i) threads[i] = probeSpawn(stressWorker, (void*)(intptr_t)i);
    for (int i = 0; i < WORKERS; ++i) probeJoin(threads[i]);
    for (int w = 0; w < WORKERS; ++w)
        for (int s = 0; s < SLOTS; ++s)
            if (mailboxFull[w][s]) { msHeapFree(mailbox[w][s].p); mailboxFull[w][s] = 0; }
}

/* M11: a runtime thread releases its region at exit; its cells stay valid, their
 * frees reach the retired region, and the next thread adopts it with them. */
static msHeapHandle* retiredOwner;
static void allocateThenRetire(void* arg) {
    (void)arg;
    for (int i = 0; i < CELLS; ++i) { cells[i] = msHeapAlloc(80); memset(cells[i], 0x33, 80); }
    retiredOwner = msHeapCurrent;
    msHeapThreadRelease();
    CHECK(msHeapCurrent == NULL);
}

static msHeapHandle* adoptedOwner;
static int adoptedReuse;
static void adoptAndReuse(void* arg) {
    (void)arg;
    for (int i = 0; i < CELLS; ++i) {
        void* p = msHeapAlloc(80);
        adoptedReuse += inSet(p, cells, CELLS);
    }
    adoptedOwner = msHeapCurrent;
    msHeapThreadRelease();
}

static void retireAndAdopt(void) {
    phase = "retire and adopt";
    probeJoin(probeSpawn(allocateThenRetire, NULL));
    for (int i = 0; i < CELLS; ++i) {
        unsigned char* bytes = cells[i];
        CHECK(bytes[0] == 0x33 && bytes[79] == 0x33);
        msHeapFree(cells[i]);
    }
    probeJoin(probeSpawn(adoptAndReuse, NULL));
    CHECK(adoptedOwner == retiredOwner);
    CHECK(adoptedReuse > CELLS / 2);
}

/* M11: a thread's first allocation asks the runtime for its exit release; until that
 * release runs, the thread keeps its region, and its cells freed elsewhere stay safe. */
static void allocateAndLeave(void* arg) {
    (void)arg;
    for (int i = 0; i < CELLS; ++i) cells[i] = msHeapAlloc(24 + (i % 5) * 16);
    bigs[0] = msHeapAlloc(BIG);
}

static void foreignThreadExit(void) {
    phase = "foreign thread exit";
    int attachedBefore = __atomic_load_n(&attachCalls, __ATOMIC_RELAXED);
    probeJoin(probeSpawn(allocateAndLeave, NULL));
    CHECK(__atomic_load_n(&attachCalls, __ATOMIC_RELAXED) == attachedBefore + 1);
    for (int i = 0; i < CELLS; ++i) msHeapFree(cells[i]);
    msHeapFree(bigs[0]);
}

static msHeapChunk* chunkHolding(void* p) {
    uintptr_t at = (uintptr_t)msHeapPage(p);
    while (!msHeapContains(MS_HEAP_REGION(msHeapCurrent), at)) at -= MS_HEAP_PAGE_SIZE;
    return (msHeapChunk*)at;
}

/* M10: a small chunk whose cells were all freed by another thread goes back to the big-chunk
 * pool on the owner's next return, when every cell is on the chunk's own free list again. */
static void remotelyEmptiedChunksReturn(void) {
    phase = "small chunks emptied by another thread return to the big-chunk pool";
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    msHeapReturnIdle();
    size_t before = a->occupied;
    for (int i = 0; i < CELLS; ++i) { cells[i] = msHeapAlloc(112); memset(cells[i], 0x5a, 112); }
    probeJoin(probeSpawn(freeCells, NULL));
    for (int i = 0; i < CELLS; ++i) CHECK(msHeapPage(cells[i])->size == 112 && (msHeapPage(cells[i])->prevSize & 1));
    msHeapReturnIdle();
    CHECK(a->occupied == before);
    for (int i = 0; i < CELLS; ++i) CHECK(!(chunkHolding(cells[i])->prevSize & 1));
    for (int i = 0; i < CELLS; ++i) { cells[i] = msHeapAlloc(112); memset(cells[i], 0x5a, 112); }
    for (int i = 0; i < CELLS; ++i) msHeapFree(cells[i]);
}

/* M10: every second free the allocator can know is refused once, whichever threads made the two
 * frees and whether they raced. A thread freeing a block it does not own claims it first (the cell's
 * mark word, a big chunk's in-use word), so a free of a block already freed or already sent is
 * refused on the thread that makes it; a free of a block another thread sent passes on the owner
 * and is refused when the owner receives the address. The freeing thread writes nothing else. */
static void* twiceBlock;
static int twiceGo;
static unsigned refusedAtCall;

static void freeExpectingRefusal(void* p) {
    expectingRefusal = 1;
    refusedHere = 0;
    if (!setjmp(refusal)) msHeapFree(p);
    expectingRefusal = 0;
    __atomic_add_fetch(&refusedAtCall, (unsigned)refusedHere, __ATOMIC_RELAXED);
}

static void freeTwiceBlock(void* arg) {
    int times = (int)(intptr_t)arg;
    if (times > 0) msHeapFree(msHeapAlloc(16));
    else times = -times;
    while (!__atomic_load_n(&twiceGo, __ATOMIC_ACQUIRE)) {}
    for (int i = 0; i < times; ++i) freeExpectingRefusal(twiceBlock);
    msHeapThreadRelease();
}

/* `local` > 0: the owner frees after the other threads; < 0: before them. `retake`: after its own
 * free the owner takes the block again, before it receives, and the new holder's bytes stay. */
static void freedOnceMore(size_t size, int local, int remote, int racers, int retake, int atReceive) {
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    msHeapReturnIdle();
    void* neighbour = msHeapAlloc(size);
    twiceBlock = msHeapAlloc(size);
    memset(twiceBlock, 0x3c, size);
    size_t before = a->occupied, charged = msHeapPage(twiceBlock)->size;
    unsigned refusalsBefore = refusals;
    refusedAtCall = 0;
    if (local < 0) msHeapFree(twiceBlock);
    __atomic_store_n(&twiceGo, 0, __ATOMIC_RELEASE);
    probeThread t[2];
    for (int i = 0; i < racers; ++i) t[i] = probeSpawn(freeTwiceBlock, (void*)(intptr_t)(i ? -remote : remote));
    __atomic_store_n(&twiceGo, 1, __ATOMIC_RELEASE);
    for (int i = 0; i < racers; ++i) probeJoin(t[i]);
    unsigned char* holder = NULL;
    if (local > 0) {
        checkUntouchedButClaim(twiceBlock, size, 0x3c);
        freeExpectingRefusal(twiceBlock);
        if (retake) {
            holder = msHeapAlloc(size);
            CHECK(holder == twiceBlock);
            memset(holder, 0x6d, size);
        }
    }
    CHECK(refusedAtCall == !atReceive && refusals == refusalsBefore + !atReceive);
    receivingRefusesOnce(atReceive);
    CHECK(refusals == refusalsBefore + 1);
    if (holder) {
        for (size_t i = 0; i < size; ++i) CHECK(holder[i] == 0x6d);
        CHECK(a->occupied == before);
        msHeapFree(holder);
    }
    CHECK(a->occupied == before - charged);
    msHeapFree(neighbour);
}

static void secondFreesAreRefused(void) {
    const size_t sizes[] = { 64, 3 * 4096 };
    for (int s = 0; s < 2; ++s) {
        int small = sizes[s] <= MS_HEAP_SMALL_ROOM;
        phase = small ? "a free by another thread, then by the owner, refused when the owner receives"
                      : "a free by another thread, then by the owner, refused at the owner's call";
        freedOnceMore(sizes[s], 1, 1, 1, 0, small);
        if (small) {
            phase = "a free by another thread, then by the owner, who takes the block again before it receives";
            freedOnceMore(sizes[s], 1, 1, 1, 1, 1);
        }
        phase = "a free by the owner, then by another thread, refused on that thread";
        freedOnceMore(sizes[s], -1, 1, 1, 0, 0);
        phase = "two frees by one other thread, the second refused on that thread";
        freedOnceMore(sizes[s], 0, 2, 1, 0, 0);
        phase = "two frees by a thread without a region, the second refused on that thread";
        freedOnceMore(sizes[s], 0, -2, 1, 0, 0);
        phase = "a thread with a region and one without free at once, one refused at its call";
        freedOnceMore(sizes[s], 0, 1, 2, 0, 0);
    }
}

/* M10: a free by another thread of a cell its chunk has not handed out since it opened is refused
 * once, on that thread if the cell's bytes already read as a mark, else when the owner receives it;
 * the chunk's count and bump stay. */
static void* tailCell;
static void freeTailCell(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    freeExpectingRefusal(tailCell);
    msHeapThreadRelease();
}

static void unhandedCellsAreRefused(void) {
    phase = "a free by another thread of a cell its chunk has not handed out is refused";
    enum { TAIL = 1504 };
    msHeapReturnIdle();
    unsigned char* first = msHeapAlloc(TAIL);
    msHeapSmall* chunk = (msHeapSmall*)msHeapPage(first);
    CHECK(chunk->acc + TAIL <= MS_HEAP_SMALL_ROOM);
    size_t acc = chunk->acc, free = chunk->free;
    tailCell = chunk->data + acc;
    unsigned before = refusals;
    refusedAtCall = 0;
    probeJoin(probeSpawn(freeTailCell, NULL));
    receivingRefusesOnce(refusedAtCall == 0);
    CHECK(refusals == before + 1 && chunk->acc == acc && chunk->free == free);
    /* A refusal stops a real program; the fixture goes on, so it clears the claim the refused free
     * left in a cell the chunk may yet hand out as zeroed. */
    msHeapSetMark(tailCell, 0);
    msHeapFree(first);
}

/* M10: the owner's free of a big chunk can pass its check just before another thread claims the
 * chunk; the claim then lands on a chunk the owner releases and may hand out again. The receive
 * frees only a chunk that still carries a claim, so the new holder keeps its chunk. The phase
 * makes that order by releasing the chunk the way the owner's free does after its check, while
 * the claimed address still sits in the other thread's open batch. */
static void* claimedBig;
static int claimStep;
static void freeClaimedBig(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    msHeapFree(claimedBig);
    __atomic_store_n(&claimStep, 1, __ATOMIC_RELEASE);
    while (__atomic_load_n(&claimStep, __ATOMIC_ACQUIRE) != 2) {}
    msHeapThreadRelease();
}

enum { CLAIMED_BIG = 2 * 4096 };
_Static_assert(CLAIMED_BIG + sizeof(msHeapBig) + 4096 <= MS_HEAP_REMOTE_BATCH_BYTES, "the claimed chunk must stay in the open batch");
static void claimAfterTheOwnersCheck(void) {
    phase = "a big chunk claimed by another thread after the owner's free passed its check, then handed out again";
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    msHeapReturnIdle();
    void* neighbour = msHeapAlloc(CLAIMED_BIG);
    claimedBig = msHeapAlloc(CLAIMED_BIG);
    msHeapBig* chunk = (msHeapBig*)msHeapPage(claimedBig);
    __atomic_store_n(&claimStep, 0, __ATOMIC_RELEASE);
    probeThread t = probeSpawn(freeClaimedBig, NULL);
    while (__atomic_load_n(&claimStep, __ATOMIC_ACQUIRE) != 1) {}
    CHECK(msHeapBigState(chunk) == MS_HEAP_BIG_SENT && __atomic_load_n(&msHeapCurrent->inbox, __ATOMIC_ACQUIRE) == NULL);
    a->occupied -= chunk->base.size;
    msHeapReleaseBig(a, chunk);
    unsigned char* holder = msHeapAlloc(CLAIMED_BIG);
    CHECK((msHeapBig*)msHeapPage(holder) == chunk);
    memset(holder, 0x6d, CLAIMED_BIG);
    __atomic_store_n(&claimStep, 2, __ATOMIC_RELEASE);
    probeJoin(t);
    receivingRefusesOnce(1);
    for (size_t i = 0; i < CLAIMED_BIG; ++i) CHECK(holder[i] == 0x6d);
    CHECK((chunk->base.prevSize & 1) && msHeapBigState(chunk) == MS_HEAP_BIG_IN_USE);
    msHeapFree(holder);
    msHeapFree(neighbour);
}

/* M10: a free racing another free of the same block, one on the owner and one on another thread,
 * is refused exactly once in every one of many pairs, and the block is then handed to one holder. */
enum { RACE_PAIRS = 2000 };
static void* volatile raceTarget;
static int raceGo, raceDone;
static void raceFrees(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    for (int i = 1; i <= RACE_PAIRS; ++i) {
        while (__atomic_load_n(&raceGo, __ATOMIC_ACQUIRE) != i) {}
        freeExpectingRefusal(raceTarget);
        msHeapThreadFlush();
        __atomic_store_n(&raceDone, i, __ATOMIC_RELEASE);
    }
    msHeapThreadRelease();
}

static void racingFreesAreRefusedOnce(void) {
    const size_t sizes[] = { 64, 3 * 4096 };
    for (int s = 0; s < 2; ++s) {
        phase = sizes[s] <= MS_HEAP_SMALL_ROOM ? "a small block freed by the owner and another thread at once, many times"
                                               : "a big chunk freed by the owner and another thread at once, many times";
        msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
        msHeapReturnIdle();
        size_t before = a->occupied;
        __atomic_store_n(&raceGo, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&raceDone, 0, __ATOMIC_RELEASE);
        probeThread t = probeSpawn(raceFrees, NULL);
        for (int i = 1; i <= RACE_PAIRS; ++i) {
            unsigned refusalsBefore = refusals;
            void* p = msHeapAlloc(sizes[s]);
            raceTarget = p;
            __atomic_store_n(&raceGo, i, __ATOMIC_RELEASE);
            for (volatile int spin = 0; spin < (i & 63); ++spin) {}
            freeExpectingRefusal(p);
            while (__atomic_load_n(&raceDone, __ATOMIC_ACQUIRE) != i) {}
            unsigned before = refusals;
            expectingRefusal = 1;
            while (setjmp(refusal)) {}
            msHeapReturnIdle();
            expectingRefusal = 0;
            (void)before;
            CHECK(refusals == refusalsBefore + 1);
            void* r = msHeapAlloc(sizes[s]);
            void* q = msHeapAlloc(sizes[s]);
            CHECK(r != q);
            msHeapFree(r);
            msHeapFree(q);
        }
        probeJoin(t);
        msHeapReturnIdle();
        CHECK(a->occupied == before);
    }
}

/* M10: a sender keeps at most one batch per open slot for reuse once its owner gives them back;
 * a timed return frees the rest into the sender's region, and its release frees all. */
enum { SPARE_BATCHES = MS_HEAP_OPEN_BATCHES + 2 };
static int spareStep;
static msHeapBatch* spare[SPARE_BATCHES];
static int countBatches(msHeapBatch* batch) {
    int n = 0;
    for (; batch; batch = batch->next) ++n;
    return n;
}
static int batchInUse(msHeapBatch* batch) {
    msHeapSmall* chunk = (msHeapSmall*)msHeapPage(batch);
    if (chunk->base.size != MS_HEAP_BATCH_CELL || !(chunk->base.prevSize & 1)) return 0;
    for (msHeapCell* cell = chunk->freeList; cell; cell = cell->next)
        if ((void*)cell == (void*)batch) return 0;
    return 1;
}
static void sendSpareBatches(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    msHeapHandle* here = msHeapCurrent;
    for (int i = 0; i < SPARE_BATCHES; ++i) {
        msHeapFree(cells[i]);
        spare[i] = here->open[msHeapOpenSlot(batchOwner)];
        msHeapThreadFlush();
    }
    __atomic_store_n(&spareStep, 1, __ATOMIC_RELEASE);
    while (__atomic_load_n(&spareStep, __ATOMIC_ACQUIRE) != 2) {}
    msHeapReturn(MS_HEAP_REGION(here), MS_HEAP_NOW_MS());
    CHECK(countBatches(here->idle) + countBatches(__atomic_load_n(&here->returned, __ATOMIC_ACQUIRE)) == MS_HEAP_OPEN_BATCHES);
    int inUse = 0;
    for (int i = 0; i < SPARE_BATCHES; ++i) inUse += batchInUse(spare[i]);
    CHECK(inUse == MS_HEAP_OPEN_BATCHES);
    msHeapThreadRelease();
    for (int i = 0; i < SPARE_BATCHES; ++i) CHECK(!batchInUse(spare[i]));
}

static void spareBatchesGoBack(void) {
    phase = "batches back from their owner stay one per open slot, and the rest are freed into the sender's region";
    batchOwner = msHeapCurrent;
    msHeapReturnIdle();
    for (int i = 0; i < SPARE_BATCHES; ++i) cells[i] = msHeapAlloc(48);
    __atomic_store_n(&spareStep, 0, __ATOMIC_RELEASE);
    probeThread t = probeSpawn(sendSpareBatches, NULL);
    while (__atomic_load_n(&spareStep, __ATOMIC_ACQUIRE) != 1) {}
    for (int i = 0; i < SPARE_BATCHES; ++i) CHECK(spare[i] && batchInUse(spare[i]));
    msHeapReturnIdle();
    __atomic_store_n(&spareStep, 2, __ATOMIC_RELEASE);
    probeJoin(t);
}

static void freeIsRefusedHere(void* p) {
    unsigned before = __atomic_load_n(&refusals, __ATOMIC_RELAXED);
    expectingRefusal = 1;
    if (!setjmp(refusal)) msHeapFree(p);
    expectingRefusal = 0;
    CHECK(__atomic_load_n(&refusals, __ATOMIC_RELAXED) == before + 1);
}

static void freeHugeAgain(void* p) {
    freeIsRefusedHere(p);
    msHeapThreadRelease();
}

static unsigned char* hugeToFree;
static void freeHugeAgainWithARegion(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    freeHugeAgain(hugeToFree);
}

/* M10: a huge chunk's first page reads as zeros after its free, so a second free from any thread
 * finds no chunk header and is refused on that thread; only the last MS_HEAP_KEPT_FIRST_PAGES
 * freed huge chunks keep the page. */
static void hugeSecondFreesAreRefused(void) {
    phase = "a second free of a huge chunk is refused on the thread that makes it";
    size_t bytes = MS_HEAP_MAX_BIG + 1;
    unsigned char* huge[3];
    for (int i = 0; i < 3; ++i) {
        huge[i] = msHeapAlloc(bytes);
        huge[i][0] = 1;
        huge[i][bytes - 1] = 2;
    }
    msHeapFree(huge[0]);
    CHECK(msHeapPage(huge[0])->size == 0 && msHeapPage(huge[0])->owner == NULL && droppedPages == 0);
    freeIsRefusedHere(huge[0]);
    probeJoin(probeSpawn(freeHugeAgain, huge[0]));
    hugeToFree = huge[0];
    probeJoin(probeSpawn(freeHugeAgainWithARegion, NULL));
    msHeapFree(huge[1]);
    CHECK(droppedPages == 0);
    msHeapFree(huge[2]);
    CHECK(droppedPages == 1);
}

int32_t msAllocatorThreadChecks(void) {
    remoteSmallReuse();
    remoteBatches();
    secondFreesAreRefused();
    unhandedCellsAreRefused();
    claimAfterTheOwnersCheck();
    racingFreesAreRefusedOnce();
    spareBatchesGoBack();
    hugeSecondFreesAreRefused();
    remoteBigReuse();
    foreignRealloc();
    remotelyEmptiedChunksReturn();
    stress();
    retireAndAdopt();
    foreignThreadExit();
    msHeapThreadRelease();
    return 0;
}
