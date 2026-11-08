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
#include "../../../../runtime/allocator.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
#endif
void msHeapResetPages(void) {}
_Noreturn void msHeapOutOfMemory(void) { fprintf(stderr, "GUARD-FAIL allocator threads: out of memory\n"); abort(); }
static int attachCalls;
void msThreadAttach(void) { __atomic_add_fetch(&attachCalls, 1, __ATOMIC_RELAXED); }

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

/* M10: a thread with its own region gathers the cells it frees for one owner and
 * size class into a run, which reaches the owner's shared list in one CAS when the
 * thread flushes, parks or exits, or when its runs reach 16 KiB; the run's header
 * carries its length, so the owner counts the cells without visiting them. */
enum { RUN_CELLS = 100, CAP_CELLS = MS_HEAP_REMOTE_BATCH_BYTES / 48 + 1, RUN_TOTAL = RUN_CELLS + CAP_CELLS + 1 };
static msHeapHandle* runOwner;
static void freeIntoRuns(void* arg) {
    (void)arg;
    msHeapFree(msHeapAlloc(16));
    msHeapCell** shared = &runOwner->sharedCells[48 / MS_HEAP_ALIGN];
    for (int i = 0; i < RUN_CELLS; ++i) msHeapFree(cells[i]);
    CHECK(__atomic_load_n(shared, __ATOMIC_ACQUIRE) == NULL);
    msHeapThreadFlush();
    msHeapCell* head = __atomic_load_n(shared, __ATOMIC_ACQUIRE);
    CHECK(head == cells[RUN_CELLS - 1]);
    CHECK(msHeapRunLength(head) == RUN_CELLS);
    CHECK(msHeapRunTail(head) == cells[0] && msHeapRunTail(head)->next == NULL);
    for (int i = RUN_CELLS; i < RUN_CELLS + CAP_CELLS; ++i) msHeapFree(cells[i]);
    head = __atomic_load_n(shared, __ATOMIC_ACQUIRE);
    CHECK(head == cells[RUN_CELLS + CAP_CELLS - 1] && msHeapRunLength(head) == CAP_CELLS);
    msHeapFree(cells[RUN_TOTAL - 1]);
    CHECK(__atomic_load_n(shared, __ATOMIC_ACQUIRE) == head);
    msHeapThreadRelease();
}

static void remoteRuns(void) {
    phase = "remote runs";
    runOwner = msHeapCurrent;
    msHeapCell** shared = &runOwner->sharedCells[48 / MS_HEAP_ALIGN];
    CHECK(__atomic_load_n(shared, __ATOMIC_ACQUIRE) == NULL);
    for (int i = 0; i < RUN_TOTAL; ++i) cells[i] = msHeapAlloc(48);
    size_t before = MS_HEAP_REGION(msHeapCurrent)->occupied;
    probeJoin(probeSpawn(freeIntoRuns, NULL));
    msHeapCell* head = __atomic_load_n(shared, __ATOMIC_ACQUIRE);
    CHECK(head == cells[RUN_TOTAL - 1] && msHeapRunLength(head) == 1);
    int reused = 0;
    void* again[RUN_TOTAL];
    for (int i = 0; i < RUN_TOTAL; ++i) {
        again[i] = msHeapAlloc(48);
        reused += inSet(again[i], cells, RUN_TOTAL);
    }
    CHECK(reused > RUN_TOTAL / 2);
    CHECK(MS_HEAP_REGION(msHeapCurrent)->occupied == before);
    for (int i = 0; i < RUN_TOTAL; ++i) msHeapFree(again[i]);
}

/* M10: a big chunk another thread frees is drained by the owner's next big
 * allocation, so its pages are reused; calloc zeroes them. */
static void remoteBigReuse(void) {
    phase = "remote big reuse";
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    size_t before = a->occupied;
    for (int i = 0; i < 8; ++i) { bigs[i] = msHeapAlloc(BIG); memset(bigs[i], 0x5a, BIG); }
    probeJoin(probeSpawn(freeBigs, NULL));
    CHECK(__atomic_load_n(&msHeapCurrent->sharedBig, __ATOMIC_ACQUIRE) != NULL);
    void* again = msHeapCalloc(1, BIG);
    CHECK(inPages(again, (void**)bigs, 8));
    for (int b = 0; b < BIG; ++b) CHECK(((unsigned char*)again)[b] == 0);
    CHECK(msHeapCurrent->sharedBig == NULL && a->pendingBig == NULL);
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

int32_t msAllocatorThreadChecks(void) {
    remoteSmallReuse();
    remoteRuns();
    remoteBigReuse();
    foreignRealloc();
    stress();
    retireAndAdopt();
    foreignThreadExit();
    msHeapThreadRelease();
    return 0;
}
