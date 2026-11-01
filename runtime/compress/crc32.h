#ifndef MS_COMPRESS_CRC32_H
#define MS_COMPRESS_CRC32_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__)) && !defined(_WIN32) && !defined(__EMSCRIPTEN__)
#define MS_CRC_PCLMUL 1
#include <cpuid.h>
#include <immintrin.h>
#elif defined(__aarch64__) && defined(__ARM_FEATURE_CRC32)
#define MS_CRC_ARM 1
#include <arm_acle.h>
#elif defined(__aarch64__) && defined(__linux__) && (defined(__GNUC__) || defined(__clang__))
#define MS_CRC_ARM 1
#define MS_CRC_ARM_RUNTIME 1
#include <arm_acle.h>
#include <asm/hwcap.h>
#include <sys/auxv.h>
#endif

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

/* Raw register in and out (no pre/post inversion); the table must be initialised. */
static uint32_t msCrc32Soft(uint32_t crc, const uint8_t* p, size_t n) {
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
    return crc;
}

#if defined(MS_CRC_PCLMUL)

/* Carry-less-multiply folding of 64 bytes per step; needs n >= 64. */
__attribute__((target("pclmul,sse4.1")))
static uint32_t msCrc32Hw(uint32_t crc, const uint8_t* p, size_t n) {
    if (n < 64) return msCrc32Soft(crc, p, n);
    const __m128i k1k2 = _mm_set_epi64x(0x01c6e41596, 0x0154442bd4);
    const __m128i k3k4 = _mm_set_epi64x(0x00ccaa009e, 0x01751997d0);
    const __m128i k5k0 = _mm_set_epi64x(0, 0x0163cd6124);
    const __m128i poly = _mm_set_epi64x(0x01f7011641, 0x01db710641);
    const __m128i mask32 = _mm_setr_epi32(~0, 0, ~0, 0);
    __m128i x0, x1, x2, x3, x4, x5;
    x1 = _mm_xor_si128(_mm_loadu_si128((const __m128i*)(p + 0x00)), _mm_cvtsi32_si128((int)crc));
    x2 = _mm_loadu_si128((const __m128i*)(p + 0x10));
    x3 = _mm_loadu_si128((const __m128i*)(p + 0x20));
    x4 = _mm_loadu_si128((const __m128i*)(p + 0x30));
    p += 64;
    n -= 64;
    while (n >= 64) {
        __m128i y1 = _mm_loadu_si128((const __m128i*)(p + 0x00));
        __m128i y2 = _mm_loadu_si128((const __m128i*)(p + 0x10));
        __m128i y3 = _mm_loadu_si128((const __m128i*)(p + 0x20));
        __m128i y4 = _mm_loadu_si128((const __m128i*)(p + 0x30));
        __m128i z1 = _mm_clmulepi64_si128(x1, k1k2, 0x00);
        __m128i z2 = _mm_clmulepi64_si128(x2, k1k2, 0x00);
        __m128i z3 = _mm_clmulepi64_si128(x3, k1k2, 0x00);
        __m128i z4 = _mm_clmulepi64_si128(x4, k1k2, 0x00);
        x1 = _mm_clmulepi64_si128(x1, k1k2, 0x11);
        x2 = _mm_clmulepi64_si128(x2, k1k2, 0x11);
        x3 = _mm_clmulepi64_si128(x3, k1k2, 0x11);
        x4 = _mm_clmulepi64_si128(x4, k1k2, 0x11);
        x1 = _mm_xor_si128(_mm_xor_si128(x1, z1), y1);
        x2 = _mm_xor_si128(_mm_xor_si128(x2, z2), y2);
        x3 = _mm_xor_si128(_mm_xor_si128(x3, z3), y3);
        x4 = _mm_xor_si128(_mm_xor_si128(x4, z4), y4);
        p += 64;
        n -= 64;
    }
    x0 = k3k4;
    x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
    x1 = _mm_xor_si128(_mm_xor_si128(_mm_clmulepi64_si128(x1, x0, 0x11), x2), x5);
    x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
    x1 = _mm_xor_si128(_mm_xor_si128(_mm_clmulepi64_si128(x1, x0, 0x11), x3), x5);
    x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
    x1 = _mm_xor_si128(_mm_xor_si128(_mm_clmulepi64_si128(x1, x0, 0x11), x4), x5);
    while (n >= 16) {
        x2 = _mm_loadu_si128((const __m128i*)p);
        x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
        x1 = _mm_xor_si128(_mm_xor_si128(_mm_clmulepi64_si128(x1, x0, 0x11), x2), x5);
        p += 16;
        n -= 16;
    }
    x2 = _mm_clmulepi64_si128(x1, x0, 0x10);
    x1 = _mm_xor_si128(_mm_srli_si128(x1, 8), x2);
    x2 = _mm_srli_si128(x1, 4);
    x1 = _mm_clmulepi64_si128(_mm_and_si128(x1, mask32), k5k0, 0x00);
    x1 = _mm_xor_si128(x1, x2);
    x2 = _mm_clmulepi64_si128(_mm_and_si128(x1, mask32), poly, 0x10);
    x2 = _mm_clmulepi64_si128(_mm_and_si128(x2, mask32), poly, 0x00);
    x1 = _mm_xor_si128(x1, x2);
    crc = (uint32_t)_mm_extract_epi32(x1, 1);
    return msCrc32Soft(crc, p, n);
}

static int msCrcHardware(void) {
    unsigned a, b, c, d;
    return __get_cpuid(1, &a, &b, &c, &d) && (c & (1u << 1)) && (c & (1u << 19));
}

#elif defined(MS_CRC_ARM)

#ifndef __ARM_FEATURE_CRC32
__attribute__((target("+crc")))
#endif
static uint32_t msCrc32Hw(uint32_t crc, const uint8_t* p, size_t n) {
    while (n >= 8) {
        uint64_t v;
        memcpy(&v, p, 8);
        crc = __crc32d(crc, v);
        p += 8;
        n -= 8;
    }
    while (n--) crc = __crc32b(crc, *p++);
    return crc;
}

static int msCrcHardware(void) {
#if defined(MS_CRC_ARM_RUNTIME)
    return (getauxval(AT_HWCAP) & HWCAP_CRC32) != 0;
#else
    return 1;
#endif
}

#endif

#if defined(MS_CRC_PCLMUL) || defined(MS_CRC_ARM)
static atomic_int msCrcHw;

static uint32_t msCrc32Update(uint32_t crc, const uint8_t* p, size_t n) {
    if (atomic_load_explicit(&msCrcState, memory_order_acquire) != 2) msCrc32Init();
    int hw = atomic_load_explicit(&msCrcHw, memory_order_relaxed);
    if (hw == 0) {
        hw = msCrcHardware() ? 2 : 1;
        atomic_store_explicit(&msCrcHw, hw, memory_order_relaxed);
    }
    return ~(hw == 2 ? msCrc32Hw(~crc, p, n) : msCrc32Soft(~crc, p, n));
}
#else
static uint32_t msCrc32Update(uint32_t crc, const uint8_t* p, size_t n) {
    if (atomic_load_explicit(&msCrcState, memory_order_acquire) != 2) msCrc32Init();
    return ~msCrc32Soft(~crc, p, n);
}
#endif

#endif
