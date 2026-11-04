/*
 * SHA-256 block kernels on the Armv8 SHA2 and x86-64 SHA extensions, over a bare eight-word state so both the
 * vendor wrapper (sha256Hw.c) and the portable std/crypto modules run the same code. msSha256HwKernel compresses
 * the whole 64-byte blocks of msg into st and returns the bytes it consumed; the caller checks the CPU first
 * (cpuFeatures.h, MS_CPU_SHA256). MS_SHA256_HW_KERNEL is defined where a kernel exists. On x86-64 the kernel is
 * compiled by function target, so the baseline build carries it. The kernels have no secret-dependent branch or index.
 */

#ifndef MS_CRYPTO_SHA256_HW_KERNEL_H
#define MS_CRYPTO_SHA256_HW_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#define MS_SHA256_HW_KERNEL 1
#include <immintrin.h>

static const uint32_t msSha256HwK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define MS_X86_SHA_TARGET __attribute__((target("sha,sse4.1,ssse3")))

#define MS_X86_QUAD(m0, m1, m2, m3, k) \
    do { \
        __m128i w_ = _mm_add_epi32(m0, _mm_loadu_si128((const __m128i *) &msSha256HwK[k])); \
        state1 = _mm_sha256rnds2_epu32(state1, state0, w_); \
        state0 = _mm_sha256rnds2_epu32(state0, state1, _mm_shuffle_epi32(w_, 0x0E)); \
        if ((k) < 48) { \
            m0 = _mm_sha256msg2_epu32(_mm_add_epi32(_mm_sha256msg1_epu32(m0, m1), \
                                                    _mm_alignr_epi8(m3, m2, 4)), m3); \
        } \
    } while (0)

MS_X86_SHA_TARGET
static inline size_t msSha256X86Kernel(uint32_t *st, const uint8_t *msg, size_t len)
{
    const __m128i bswap = _mm_set_epi64x(0x0c0d0e0f08090a0bULL, 0x0405060700010203ULL);
    __m128i tmp = _mm_shuffle_epi32(_mm_loadu_si128((const __m128i *) &st[0]), 0xB1);
    __m128i state1 = _mm_shuffle_epi32(_mm_loadu_si128((const __m128i *) &st[4]), 0x1B);
    __m128i state0 = _mm_alignr_epi8(tmp, state1, 8);
    size_t processed = 0;
    state1 = _mm_blend_epi16(state1, tmp, 0xF0);

    for (; len >= 64;
         processed += 64, msg += 64, len -= 64) {
        const __m128i state0Orig = state0;
        const __m128i state1Orig = state1;
        __m128i m0 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) msg), bswap);
        __m128i m1 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) (msg + 16)), bswap);
        __m128i m2 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) (msg + 32)), bswap);
        __m128i m3 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *) (msg + 48)), bswap);

        for (int t = 0; t < 64; t += 16) {
            MS_X86_QUAD(m0, m1, m2, m3, t);
            MS_X86_QUAD(m1, m2, m3, m0, t + 4);
            MS_X86_QUAD(m2, m3, m0, m1, t + 8);
            MS_X86_QUAD(m3, m0, m1, m2, t + 12);
        }

        state0 = _mm_add_epi32(state0, state0Orig);
        state1 = _mm_add_epi32(state1, state1Orig);
    }

    tmp = _mm_shuffle_epi32(state0, 0x1B);
    state1 = _mm_shuffle_epi32(state1, 0xB1);
    _mm_storeu_si128((__m128i *) &st[0], _mm_blend_epi16(tmp, state1, 0xF0));
    _mm_storeu_si128((__m128i *) &st[4], _mm_alignr_epi8(state1, tmp, 8));
    return processed;
}

static inline size_t msSha256HwKernel(uint32_t *st, const uint8_t *msg, size_t len)
{
    return msSha256X86Kernel(st, msg, len);
}

#elif defined(__aarch64__) && (defined(__clang__) || defined(__GNUC__))
#define MS_SHA256_HW_KERNEL 1
#include <arm_neon.h>

static const uint32_t msSha256HwK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#if defined(__clang__)
#define MS_ARMV8_SHA2_TARGET __attribute__((target("sha2")))
#else
#define MS_ARMV8_SHA2_TARGET __attribute__((target("arch=armv8-a+crypto")))
#endif

#define MS_SHA256_ROUND(abcd, efgh, w) \
    __asm__("mov %2.16b, %0.16b\n\t" \
            "sha256h %q0, %q1, %3.4s\n\t" \
            "sha256h2 %q1, %q2, %3.4s" \
            : "+w"(abcd), "+w"(efgh), "=&w"(copy) : "w"(w))

#define MS_SHA256_STEP(abcd, efgh, sched, k) \
    do { \
        uint32x4_t w_ = vaddq_u32(sched, vld1q_u32(&msSha256HwK[k])); \
        MS_SHA256_ROUND(abcd, efgh, w_); \
    } while (0)

#define MS_SHA256_SCHEDULE(a, b, c, d) \
    vsha256su1q_u32(vsha256su0q_u32(a, b), c, d)

MS_ARMV8_SHA2_TARGET
static inline size_t msSha256Armv8Kernel(uint32_t *st, const uint8_t *msg, size_t len)
{
    uint32x4_t abcd = vld1q_u32(&st[0]);
    uint32x4_t efgh = vld1q_u32(&st[4]);
    uint32x4_t copy;
    size_t processed = 0;

    for (; len >= 64;
         processed += 64, msg += 64, len -= 64) {
        const uint32x4_t abcdOrig = abcd;
        const uint32x4_t efghOrig = efgh;
        uint32x4_t s0 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(msg)));
        uint32x4_t s1 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(msg + 16)));
        uint32x4_t s2 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(msg + 32)));
        uint32x4_t s3 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(msg + 48)));

        MS_SHA256_STEP(abcd, efgh, s0, 0);
        MS_SHA256_STEP(abcd, efgh, s1, 4);
        MS_SHA256_STEP(abcd, efgh, s2, 8);
        MS_SHA256_STEP(abcd, efgh, s3, 12);
        for (int t = 16; t < 64; t += 16) {
            s0 = MS_SHA256_SCHEDULE(s0, s1, s2, s3);
            MS_SHA256_STEP(abcd, efgh, s0, t);
            s1 = MS_SHA256_SCHEDULE(s1, s2, s3, s0);
            MS_SHA256_STEP(abcd, efgh, s1, t + 4);
            s2 = MS_SHA256_SCHEDULE(s2, s3, s0, s1);
            MS_SHA256_STEP(abcd, efgh, s2, t + 8);
            s3 = MS_SHA256_SCHEDULE(s3, s0, s1, s2);
            MS_SHA256_STEP(abcd, efgh, s3, t + 12);
        }

        abcd = vaddq_u32(abcd, abcdOrig);
        efgh = vaddq_u32(efgh, efghOrig);
    }

    vst1q_u32(&st[0], abcd);
    vst1q_u32(&st[4], efgh);
    return processed;
}

static inline size_t msSha256HwKernel(uint32_t *st, const uint8_t *msg, size_t len)
{
    return msSha256Armv8Kernel(st, msg, len);
}

#endif

#endif /* MS_CRYPTO_SHA256_HW_KERNEL_H */
