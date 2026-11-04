/*
 * SHA-512 block kernel on the Armv8.2 SHA512 extension, over a bare eight-word state, for the portable std/crypto
 * modules. Ported from mbedTLS sha512.c (mbedtls_internal_sha512_process_many_a64_crypto, Apache-2.0), which took it
 * from Simon Tatham's PuTTY (MIT). msSha512HwKernel compresses the whole 128-byte blocks of msg into st and returns
 * the bytes it consumed; the caller checks the CPU first (cpuFeatures.h, MS_CPU_SHA512). x86-64 has no SHA-512
 * extension, so MS_SHA512_HW_KERNEL is defined on aarch64 only. No secret-dependent branch or index.
 */

#ifndef MS_CRYPTO_SHA512_HW_KERNEL_H
#define MS_CRYPTO_SHA512_HW_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#if defined(__aarch64__) && (defined(__clang__) || defined(__GNUC__)) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define MS_SHA512_HW_KERNEL 1
#include <arm_neon.h>

#if defined(__clang__)
#pragma clang attribute push (__attribute__((target("sha3"))), apply_to=function)
#else
#pragma GCC push_options
#pragma GCC target ("arch=armv8.2-a+sha3")
#endif

static const uint64_t msSha512HwK[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL,
};

/* The instructions through inline assembly, so the kernel does not depend on which compiler release declares the
 * intrinsics. */
static inline uint64x2_t ms_vsha512su0q_u64(uint64x2_t x, uint64x2_t y)
{
    __asm__("sha512su0 %0.2D,%1.2D" : "+w"(x) : "w"(y));
    return x;
}
static inline uint64x2_t ms_vsha512su1q_u64(uint64x2_t x, uint64x2_t y, uint64x2_t z)
{
    __asm__("sha512su1 %0.2D,%1.2D,%2.2D" : "+w"(x) : "w"(y), "w"(z));
    return x;
}
static inline uint64x2_t ms_vsha512hq_u64(uint64x2_t x, uint64x2_t y, uint64x2_t z)
{
    __asm__("sha512h %q0,%q1,%2.2D" : "+w"(x) : "w"(y), "w"(z));
    return x;
}
static inline uint64x2_t ms_vsha512h2q_u64(uint64x2_t x, uint64x2_t y, uint64x2_t z)
{
    __asm__("sha512h2 %q0,%q1,%2.2D" : "+w"(x) : "w"(y), "w"(z));
    return x;
}

static inline size_t msSha512HwKernel(uint64_t *st, const uint8_t *msg, size_t len)
{
    uint64x2_t ab = vld1q_u64(&st[0]);
    uint64x2_t cd = vld1q_u64(&st[2]);
    uint64x2_t ef = vld1q_u64(&st[4]);
    uint64x2_t gh = vld1q_u64(&st[6]);

    size_t processed = 0;

    for (;
         len >= 128;
         processed += 128,
         msg += 128,
         len -= 128) {
        uint64x2_t initial_sum, sum, intermed;

        uint64x2_t ab_orig = ab;
        uint64x2_t cd_orig = cd;
        uint64x2_t ef_orig = ef;
        uint64x2_t gh_orig = gh;

        uint64x2_t s0 = (uint64x2_t) vld1q_u8(msg + 16 * 0);
        uint64x2_t s1 = (uint64x2_t) vld1q_u8(msg + 16 * 1);
        uint64x2_t s2 = (uint64x2_t) vld1q_u8(msg + 16 * 2);
        uint64x2_t s3 = (uint64x2_t) vld1q_u8(msg + 16 * 3);
        uint64x2_t s4 = (uint64x2_t) vld1q_u8(msg + 16 * 4);
        uint64x2_t s5 = (uint64x2_t) vld1q_u8(msg + 16 * 5);
        uint64x2_t s6 = (uint64x2_t) vld1q_u8(msg + 16 * 6);
        uint64x2_t s7 = (uint64x2_t) vld1q_u8(msg + 16 * 7);

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__  /* assume LE if these not defined; untested on BE */
        s0 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s0)));
        s1 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s1)));
        s2 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s2)));
        s3 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s3)));
        s4 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s4)));
        s5 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s5)));
        s6 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s6)));
        s7 = vreinterpretq_u64_u8(vrev64q_u8(vreinterpretq_u8_u64(s7)));
#endif

        /* Rounds 0 and 1 */
        initial_sum = vaddq_u64(s0, vld1q_u64(&msSha512HwK[0]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), gh);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(ef, gh, 1), vextq_u64(cd, ef, 1));
        gh = ms_vsha512h2q_u64(intermed, cd, ab);
        cd = vaddq_u64(cd, intermed);

        /* Rounds 2 and 3 */
        initial_sum = vaddq_u64(s1, vld1q_u64(&msSha512HwK[2]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ef);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(cd, ef, 1), vextq_u64(ab, cd, 1));
        ef = ms_vsha512h2q_u64(intermed, ab, gh);
        ab = vaddq_u64(ab, intermed);

        /* Rounds 4 and 5 */
        initial_sum = vaddq_u64(s2, vld1q_u64(&msSha512HwK[4]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), cd);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(ab, cd, 1), vextq_u64(gh, ab, 1));
        cd = ms_vsha512h2q_u64(intermed, gh, ef);
        gh = vaddq_u64(gh, intermed);

        /* Rounds 6 and 7 */
        initial_sum = vaddq_u64(s3, vld1q_u64(&msSha512HwK[6]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ab);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(gh, ab, 1), vextq_u64(ef, gh, 1));
        ab = ms_vsha512h2q_u64(intermed, ef, cd);
        ef = vaddq_u64(ef, intermed);

        /* Rounds 8 and 9 */
        initial_sum = vaddq_u64(s4, vld1q_u64(&msSha512HwK[8]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), gh);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(ef, gh, 1), vextq_u64(cd, ef, 1));
        gh = ms_vsha512h2q_u64(intermed, cd, ab);
        cd = vaddq_u64(cd, intermed);

        /* Rounds 10 and 11 */
        initial_sum = vaddq_u64(s5, vld1q_u64(&msSha512HwK[10]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ef);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(cd, ef, 1), vextq_u64(ab, cd, 1));
        ef = ms_vsha512h2q_u64(intermed, ab, gh);
        ab = vaddq_u64(ab, intermed);

        /* Rounds 12 and 13 */
        initial_sum = vaddq_u64(s6, vld1q_u64(&msSha512HwK[12]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), cd);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(ab, cd, 1), vextq_u64(gh, ab, 1));
        cd = ms_vsha512h2q_u64(intermed, gh, ef);
        gh = vaddq_u64(gh, intermed);

        /* Rounds 14 and 15 */
        initial_sum = vaddq_u64(s7, vld1q_u64(&msSha512HwK[14]));
        sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ab);
        intermed = ms_vsha512hq_u64(sum, vextq_u64(gh, ab, 1), vextq_u64(ef, gh, 1));
        ab = ms_vsha512h2q_u64(intermed, ef, cd);
        ef = vaddq_u64(ef, intermed);

        for (unsigned int t = 16; t < 80; t += 16) {
            /* Rounds t and t + 1 */
            s0 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s0, s1), s7, vextq_u64(s4, s5, 1));
            initial_sum = vaddq_u64(s0, vld1q_u64(&msSha512HwK[t]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), gh);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(ef, gh, 1), vextq_u64(cd, ef, 1));
            gh = ms_vsha512h2q_u64(intermed, cd, ab);
            cd = vaddq_u64(cd, intermed);

            /* Rounds t + 2 and t + 3 */
            s1 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s1, s2), s0, vextq_u64(s5, s6, 1));
            initial_sum = vaddq_u64(s1, vld1q_u64(&msSha512HwK[t + 2]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ef);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(cd, ef, 1), vextq_u64(ab, cd, 1));
            ef = ms_vsha512h2q_u64(intermed, ab, gh);
            ab = vaddq_u64(ab, intermed);

            /* Rounds t + 4 and t + 5 */
            s2 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s2, s3), s1, vextq_u64(s6, s7, 1));
            initial_sum = vaddq_u64(s2, vld1q_u64(&msSha512HwK[t + 4]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), cd);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(ab, cd, 1), vextq_u64(gh, ab, 1));
            cd = ms_vsha512h2q_u64(intermed, gh, ef);
            gh = vaddq_u64(gh, intermed);

            /* Rounds t + 6 and t + 7 */
            s3 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s3, s4), s2, vextq_u64(s7, s0, 1));
            initial_sum = vaddq_u64(s3, vld1q_u64(&msSha512HwK[t + 6]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ab);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(gh, ab, 1), vextq_u64(ef, gh, 1));
            ab = ms_vsha512h2q_u64(intermed, ef, cd);
            ef = vaddq_u64(ef, intermed);

            /* Rounds t + 8 and t + 9 */
            s4 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s4, s5), s3, vextq_u64(s0, s1, 1));
            initial_sum = vaddq_u64(s4, vld1q_u64(&msSha512HwK[t + 8]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), gh);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(ef, gh, 1), vextq_u64(cd, ef, 1));
            gh = ms_vsha512h2q_u64(intermed, cd, ab);
            cd = vaddq_u64(cd, intermed);

            /* Rounds t + 10 and t + 11 */
            s5 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s5, s6), s4, vextq_u64(s1, s2, 1));
            initial_sum = vaddq_u64(s5, vld1q_u64(&msSha512HwK[t + 10]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ef);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(cd, ef, 1), vextq_u64(ab, cd, 1));
            ef = ms_vsha512h2q_u64(intermed, ab, gh);
            ab = vaddq_u64(ab, intermed);

            /* Rounds t + 12 and t + 13 */
            s6 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s6, s7), s5, vextq_u64(s2, s3, 1));
            initial_sum = vaddq_u64(s6, vld1q_u64(&msSha512HwK[t + 12]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), cd);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(ab, cd, 1), vextq_u64(gh, ab, 1));
            cd = ms_vsha512h2q_u64(intermed, gh, ef);
            gh = vaddq_u64(gh, intermed);

            /* Rounds t + 14 and t + 15 */
            s7 = ms_vsha512su1q_u64(ms_vsha512su0q_u64(s7, s0), s6, vextq_u64(s3, s4, 1));
            initial_sum = vaddq_u64(s7, vld1q_u64(&msSha512HwK[t + 14]));
            sum = vaddq_u64(vextq_u64(initial_sum, initial_sum, 1), ab);
            intermed = ms_vsha512hq_u64(sum, vextq_u64(gh, ab, 1), vextq_u64(ef, gh, 1));
            ab = ms_vsha512h2q_u64(intermed, ef, cd);
            ef = vaddq_u64(ef, intermed);
        }

        ab = vaddq_u64(ab, ab_orig);
        cd = vaddq_u64(cd, cd_orig);
        ef = vaddq_u64(ef, ef_orig);
        gh = vaddq_u64(gh, gh_orig);
    }

    vst1q_u64(&st[0], ab);
    vst1q_u64(&st[2], cd);
    vst1q_u64(&st[4], ef);
    vst1q_u64(&st[6], gh);

    return processed;
}

#if defined(__clang__)
#pragma clang attribute pop
#else
#pragma GCC pop_options
#endif

#endif

#endif /* MS_CRYPTO_SHA512_HW_KERNEL_H */
