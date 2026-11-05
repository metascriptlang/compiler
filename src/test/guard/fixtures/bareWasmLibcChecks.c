#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

__attribute__((export_name("libcContracts")))
int32_t msBareWasmLibcChecks(void) {
    msArenaReset();
    for (size_t round = 0; round < 256; ++round) {
        unsigned char* p = calloc(7, 19);
        for (size_t i = 0; i < 133; ++i) if (p[i] != 0) return 1;
        memset(p, 0x5a, 133);
        p = realloc(p, 8193);
        for (size_t i = 0; i < 133; ++i) if (p[i] != 0x5a) return 2;
        p = realloc(p, 7);
        for (size_t i = 0; i < 7; ++i) if (p[i] != 0x5a) return 3;
        free(p);
    }
    unsigned char* held = malloc(17);
    memset(held, 0x69, 17);
    volatile size_t impossible = SIZE_MAX;
    if (realloc(held, impossible) != NULL) return 4;
    if (msRealloc(held, 17, impossible) != NULL) return 5;
    if (calloc(impossible, 2) != NULL) return 6;
    for (size_t i = 0; i < 17; ++i) if (held[i] != 0x69) return 7;
    free(held);
    free(NULL);
    free(malloc(0));
    if (realloc(malloc(17), 0) != NULL) return 8;
    if (msRealloc(malloc(17), 17, 0) != NULL) return 9;
    msArenaReset();
    for (size_t round = 0; round < 16; ++round) {
        unsigned char* p = msArenaAlloc(120 * 1024);
        for (size_t i = 0; i < 120 * 1024; ++i) if (p[i] != 0) return 10;
        memset(p, 0xa7, 120 * 1024);
        msArenaReset();
    }
    return 0;
}
