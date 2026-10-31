#ifndef MS_COMPRESS_CRC32_H
#define MS_COMPRESS_CRC32_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

static uint32_t msCrcTable[8][256];
static atomic_int msCrcState;

static void msCrc32Init(void) {
    int expected = 0;
    if (atomic_compare_exchange_strong(&msCrcState, &expected, 1)) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            msCrcTable[0][i] = c;
        }
        for (uint32_t i = 0; i < 256; i++) {
            for (int t = 1; t < 8; t++) {
                uint32_t p = msCrcTable[t - 1][i];
                msCrcTable[t][i] = (p >> 8) ^ msCrcTable[0][p & 0xFF];
            }
        }
        atomic_store(&msCrcState, 2);
    } else {
        while (atomic_load(&msCrcState) != 2) {}
    }
}

static uint32_t msCrc32Update(uint32_t crc, const uint8_t* p, size_t n) {
    if (atomic_load_explicit(&msCrcState, memory_order_acquire) != 2) msCrc32Init();
    crc = ~crc;
    while (n >= 8) {
        uint32_t a = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
        uint32_t b = (uint32_t)p[4] | (uint32_t)p[5] << 8 | (uint32_t)p[6] << 16 | (uint32_t)p[7] << 24;
        a ^= crc;
        crc = msCrcTable[7][a & 0xFF] ^ msCrcTable[6][(a >> 8) & 0xFF] ^ msCrcTable[5][(a >> 16) & 0xFF] ^ msCrcTable[4][a >> 24]
            ^ msCrcTable[3][b & 0xFF] ^ msCrcTable[2][(b >> 8) & 0xFF] ^ msCrcTable[1][(b >> 16) & 0xFF] ^ msCrcTable[0][b >> 24];
        p += 8;
        n -= 8;
    }
    while (n--) crc = msCrcTable[0][(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

#endif
