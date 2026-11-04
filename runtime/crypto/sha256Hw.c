/*
 * SHA-256 block kernels the vendor file lacks or schedules badly (sha256HwKernel.h, shared with the portable
 * std/crypto modules). On aarch64 the Armv8 crypto round is written so the copy of the old state is off the
 * dependency chain: the vendor kernel lets the compiler place `mov` between consecutive sha256h. On x86-64 the
 * SHA extension kernel runs only where cpuid reports SHA, SSSE3 and SSE4.1; every other CPU keeps the vendor
 * scalar blocks. On both, this file is the sha256.c translation unit, with the vendor update,
 * finish and one-shot replaced by ones that feed every block, the buffered and padding blocks included, to
 * msSha256Blocks; every other target gets the vendor file unchanged. The kernels have no secret-dependent branch or index.
 */

#if (defined(__aarch64__) || defined(__x86_64__)) && (defined(__clang__) || defined(__GNUC__))
#define mbedtls_sha256_update msSha256VendorUpdate
#define mbedtls_sha256_finish msSha256VendorFinish
#define mbedtls_sha256 msSha256VendorOneShot
#define MS_SHA256_HW_WRAP 1
#endif

#include "sha256.c"

#ifdef MS_SHA256_HW_WRAP
#undef mbedtls_sha256_update
#undef mbedtls_sha256_finish
#undef mbedtls_sha256

#include "runtime/crypto/cpuFeatures.h"
#include "runtime/crypto/sha256HwKernel.h"

#if defined(__x86_64__)

static size_t msSha256Blocks(mbedtls_sha256_context *ctx, const uint8_t *msg, size_t len)
{
    if (msCpuFeatures() & MS_CPU_SHA256) {
        return msSha256HwKernel(ctx->state, msg, len);
    }
    return mbedtls_internal_sha256_process_many(ctx, msg, len);
}
#elif defined(MBEDTLS_SHA256_USE_ARMV8_A_CRYPTO_IF_PRESENT)

static size_t msSha256Blocks(mbedtls_sha256_context *ctx, const uint8_t *msg, size_t len)
{
    if (mbedtls_a64_crypto_sha256_has_support()) {
        return msSha256HwKernel(ctx->state, msg, len);
    }
    return mbedtls_internal_sha256_process_many(ctx, msg, len);
}

#else /* detection unavailable: the vendor file already dropped the Arm path */

#define msSha256Blocks mbedtls_internal_sha256_process_many

#endif

static int msSha256OneBlock(mbedtls_sha256_context *ctx, const unsigned char *block)
{
#if defined(__x86_64__)
    return msSha256Blocks(ctx, block, SHA256_BLOCK_SIZE) == SHA256_BLOCK_SIZE
               ? 0 : MBEDTLS_ERR_ERROR_GENERIC_ERROR;
#else
    return mbedtls_internal_sha256_process(ctx, block);
#endif
}

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

        if ((ret = msSha256OneBlock(ctx, ctx->buffer)) != 0) {
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

int mbedtls_sha256_finish(mbedtls_sha256_context *ctx, unsigned char *output)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    uint32_t used = ctx->total[0] & 0x3F;
    uint32_t high, low;

    ctx->buffer[used++] = 0x80;

    if (used <= 56) {
        memset(ctx->buffer + used, 0, 56 - used);
    } else {
        memset(ctx->buffer + used, 0, SHA256_BLOCK_SIZE - used);

        if ((ret = msSha256OneBlock(ctx, ctx->buffer)) != 0) {
            goto exit;
        }

        memset(ctx->buffer, 0, 56);
    }

    high = (ctx->total[0] >> 29) | (ctx->total[1] << 3);
    low  = (ctx->total[0] << 3);

    MBEDTLS_PUT_UINT32_BE(high, ctx->buffer, 56);
    MBEDTLS_PUT_UINT32_BE(low,  ctx->buffer, 60);

    if ((ret = msSha256OneBlock(ctx, ctx->buffer)) != 0) {
        goto exit;
    }

    for (int i = 0; i < 7; i++) {
        MBEDTLS_PUT_UINT32_BE(ctx->state[i], output, 4 * i);
    }
#if defined(MBEDTLS_SHA224_C)
    if (!ctx->is224)
#endif
    {
        MBEDTLS_PUT_UINT32_BE(ctx->state[7], output, 28);
    }

    ret = 0;

exit:
    mbedtls_sha256_free(ctx);
    return ret;
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
