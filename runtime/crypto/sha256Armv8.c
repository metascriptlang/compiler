/*
 * SHA-256 with the Armv8 crypto round written so the copy of the old state is off the dependency
 * chain: the vendor kernel lets the compiler place `mov` between consecutive sha256h. On aarch64
 * this file is the sha256.c translation unit, with the vendor update and one-shot replaced by ones that feed
 * whole blocks to msSha256Armv8Blocks; every other target gets the vendor file unchanged.
 */

#if defined(__aarch64__) && (defined(__clang__) || defined(__GNUC__))
#define mbedtls_sha256_update msSha256VendorUpdate
#define mbedtls_sha256 msSha256VendorOneShot
#define MS_SHA256_ARMV8_ROUND_ASM 1
#endif

#include "sha256.c"

#ifdef MS_SHA256_ARMV8_ROUND_ASM
#undef mbedtls_sha256_update
#undef mbedtls_sha256

#if defined(MBEDTLS_SHA256_USE_ARMV8_A_CRYPTO_IF_PRESENT)

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
        uint32x4_t w_ = vaddq_u32(sched, vld1q_u32(&K[k])); \
        MS_SHA256_ROUND(abcd, efgh, w_); \
    } while (0)

#define MS_SHA256_SCHEDULE(a, b, c, d) \
    vsha256su1q_u32(vsha256su0q_u32(a, b), c, d)

MS_ARMV8_SHA2_TARGET
static size_t msSha256Armv8Blocks(mbedtls_sha256_context *ctx, const uint8_t *msg, size_t len)
{
    uint32x4_t abcd = vld1q_u32(&ctx->state[0]);
    uint32x4_t efgh = vld1q_u32(&ctx->state[4]);
    uint32x4_t copy;
    size_t processed = 0;

    for (; len >= SHA256_BLOCK_SIZE;
         processed += SHA256_BLOCK_SIZE, msg += SHA256_BLOCK_SIZE, len -= SHA256_BLOCK_SIZE) {
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

    vst1q_u32(&ctx->state[0], abcd);
    vst1q_u32(&ctx->state[4], efgh);
    return processed;
}

static size_t msSha256Blocks(mbedtls_sha256_context *ctx, const uint8_t *msg, size_t len)
{
    if (mbedtls_a64_crypto_sha256_has_support()) {
        return msSha256Armv8Blocks(ctx, msg, len);
    }
    return mbedtls_internal_sha256_process_many(ctx, msg, len);
}

#else /* detection unavailable: the vendor file already dropped the Arm path */

#define msSha256Blocks mbedtls_internal_sha256_process_many

#endif

int mbedtls_sha256_update(mbedtls_sha256_context *ctx, const unsigned char *input, size_t ilen)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    size_t fill;
    uint32_t left;

    if (ilen == 0) {
        return 0;
    }

    left = ctx->total[0] & 0x3F;
    fill = SHA256_BLOCK_SIZE - left;

    ctx->total[0] += (uint32_t) ilen;
    ctx->total[0] &= 0xFFFFFFFF;

    if (ctx->total[0] < (uint32_t) ilen) {
        ctx->total[1]++;
    }

    if (left && ilen >= fill) {
        memcpy((void *) (ctx->buffer + left), input, fill);

        if ((ret = mbedtls_internal_sha256_process(ctx, ctx->buffer)) != 0) {
            return ret;
        }

        input += fill;
        ilen  -= fill;
        left = 0;
    }

    while (ilen >= SHA256_BLOCK_SIZE) {
        size_t processed = msSha256Blocks(ctx, input, ilen);
        if (processed < SHA256_BLOCK_SIZE) {
            return MBEDTLS_ERR_ERROR_GENERIC_ERROR;
        }

        input += processed;
        ilen  -= processed;
    }

    if (ilen > 0) {
        memcpy((void *) (ctx->buffer + left), input, ilen);
    }

    return 0;
}

int mbedtls_sha256(const unsigned char *input, size_t ilen, unsigned char *output, int is224)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    mbedtls_sha256_context ctx;

#if defined(MBEDTLS_SHA224_C)
    if (is224 != 0 && is224 != 1) {
        return MBEDTLS_ERR_SHA256_BAD_INPUT_DATA;
    }
#else
    if (is224 != 0) {
        return MBEDTLS_ERR_SHA256_BAD_INPUT_DATA;
    }
#endif

    mbedtls_sha256_init(&ctx);

    if ((ret = mbedtls_sha256_starts(&ctx, is224)) != 0) {
        goto exit;
    }

    if ((ret = mbedtls_sha256_update(&ctx, input, ilen)) != 0) {
        goto exit;
    }

    ret = mbedtls_sha256_finish(&ctx, output);

exit:
    mbedtls_sha256_free(&ctx);

    return ret;
}

#endif
