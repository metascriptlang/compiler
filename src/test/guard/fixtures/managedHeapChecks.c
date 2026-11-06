#include "runtime/drc.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "GUARD-FAIL managed heap line %d: %s\n", __LINE__, #x); abort(); } } while (0)

typedef struct { size_t prevSize; size_t size; void* owner; } msManagedPageHeader;

static const msManagedPageHeader* msManagedPage(const void* p) {
    return (const msManagedPageHeader*)((uintptr_t)p & ~(uintptr_t)4095);
}

int32_t msManagedHeapChecks(void) {
    void* cells[64];
    for (int i = 0; i < 64; ++i) cells[i] = msMemAlloc(40);
    for (int i = 0; i < 64; ++i) {
        CHECK(msManagedPage(cells[i])->size == 48);
        CHECK(msManagedPage(cells[i])->owner != NULL);
        CHECK(msManagedPage(cells[i])->owner == msManagedPage(cells[0])->owner);
    }
    void* grown = msRealloc(cells[0], 40, 6000);
    CHECK(msManagedPage(grown)->size > 4096);
    msMemFree(grown);
    for (int i = 1; i < 64; ++i) msMemFree(cells[i]);
    return 0;
}
