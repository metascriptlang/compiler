#undef MSOS_BARE
#undef MS_HEAP_USE_MALLOC
#define MS_HEAP_USE_MALLOC 0
#undef MS_ALLOCATOR_H
#define msHeapAlloc msHeapThreadProbeAlloc
#define msHeapCalloc msHeapThreadProbeCalloc
#define msHeapRealloc msHeapThreadProbeRealloc
#define msHeapFree msHeapThreadProbeFree
#define msHeapReset msHeapThreadProbeReset
#define msHeapThreadRelease msHeapThreadProbeRelease
#define msHeapTryAllocPages msHeapThreadProbeTryAllocPages
#define msHeapDeallocPages msHeapThreadProbeDeallocPages
#define msHeapResetPages msHeapThreadProbeResetPages
#define msHeapOutOfMemory msHeapThreadProbeOutOfMemory
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

enum { CELLS = 600, BIG = 64 * 1024 };
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

/* M10: a cell another thread frees goes onto the owner's shared list, and the
 * owner reuses it once its active chunk has no free cell. */
static void remoteSmallReuse(void) {
    phase = "remote small reuse";
    for (int i = 0; i < CELLS; ++i) { cells[i] = msHeapAlloc(48); memset(cells[i], 0x5a, 48); }
    size_t before = MS_HEAP_REGION(msHeapCurrent)->occupied;
    probeJoin(probeSpawn(freeCells, NULL));
    CHECK(MS_HEAP_REGION(msHeapCurrent)->occupied == before);
    void* again[CELLS];
    int reused = 0;
    for (int i = 0; i < CELLS; ++i) { again[i] = msHeapAlloc(48); reused += inSet(again[i], cells, CELLS); }
    CHECK(reused > CELLS / 2);
    for (int i = 0; i < CELLS; ++i) msHeapFree(again[i]);
}

/* M10: a big chunk another thread frees is drained by the owner's next big
 * allocation, so its pages are reused. */
static void remoteBigReuse(void) {
    phase = "remote big reuse";
    msHeapRegion* a = MS_HEAP_REGION(msHeapCurrent);
    size_t before = a->occupied;
    for (int i = 0; i < 8; ++i) bigs[i] = msHeapAlloc(BIG);
    probeJoin(probeSpawn(freeBigs, NULL));
    CHECK(__atomic_load_n(&msHeapCurrent->sharedBig, __ATOMIC_ACQUIRE) != NULL);
    void* again = msHeapAlloc(BIG);
    CHECK(msHeapCurrent->sharedBig == NULL && a->pendingBig == NULL);
    CHECK(a->occupied == before + msHeapPage(again)->size);
    msHeapFree(again);
    CHECK(a->occupied == before);
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

/* M11: a foreign thread keeps its region; its cells freed elsewhere stay safe. */
static void allocateAndLeave(void* arg) {
    (void)arg;
    for (int i = 0; i < CELLS; ++i) cells[i] = msHeapAlloc(24 + (i % 5) * 16);
    bigs[0] = msHeapAlloc(BIG);
}

static void foreignThreadExit(void) {
    phase = "foreign thread exit";
    probeJoin(probeSpawn(allocateAndLeave, NULL));
    for (int i = 0; i < CELLS; ++i) msHeapFree(cells[i]);
    msHeapFree(bigs[0]);
}

int32_t msAllocatorThreadChecks(void) {
    remoteSmallReuse();
    remoteBigReuse();
    stress();
    retireAndAdopt();
    foreignThreadExit();
    msHeapThreadRelease();
    return 0;
}
