/*
 * MetaScript streaming deflate runtime (tdefl wrapper).
 * Mirrors runtime/compress/inflate.c's context/queue/drain pattern.
 */

#include "runtime/compress/deflate.h"

#include <stdlib.h>
#include <string.h>

/* Scope miniz to what we actually need before including the header. */
#define MINIZ_NO_INFLATE_APIS
#define MINIZ_NO_ARCHIVE_APIS
#define MINIZ_NO_ARCHIVE_WRITING_APIS
#define MINIZ_NO_ZLIB_APIS
#define MINIZ_NO_ZLIB_COMPATIBLE_NAMES
#define MINIZ_NO_STDIO
#define MINIZ_NO_TIME
#include "vendor/miniz/miniz.h"

/* ===== Constants ===== */

#define DEFLATE_OUT_BUF_SIZE (32 * 1024)

/* Same cap as inflate so that round-trips are symmetric. Streaming callers
 * can compress arbitrarily large inputs by draining between feeds. */
#define DEFLATE_QUEUE_CAP    (64 * 1024 * 1024)

/* ===== Context ===== */

struct msDeflateCtx {
    int32_t format;
    tdefl_compressor tdefl;     /* ~200 KB state */

    uint8_t outBuf[DEFLATE_OUT_BUF_SIZE];   /* per-call staging buffer */

    /* Growable output queue (compressed bytes awaiting drain). */
    uint8_t* queue;
    size_t queueLen;
    size_t queueCap;

    /* gzip bookkeeping */
    mz_ulong crc32;
    uint64_t inputBytes;

    int finished;
    int errored;
};

/* ===== Queue helpers ===== */

static int queuePush(struct msDeflateCtx* c, const uint8_t* data, size_t len) {
    if (len == 0) return 0;
    size_t needed = c->queueLen + len;
    if (needed > DEFLATE_QUEUE_CAP) return -1;
    if (needed > c->queueCap) {
        size_t newCap = c->queueCap == 0 ? 4096 : c->queueCap * 2;
        while (newCap < needed) newCap *= 2;
        uint8_t* q = (uint8_t*)realloc(c->queue, newCap);
        if (!q) return -1;
        c->queue = q;
        c->queueCap = newCap;
    }
    memcpy(c->queue + c->queueLen, data, len);
    c->queueLen += len;
    return 0;
}

/* ===== Handle conversion ===== */

static inline int64_t ctxToHandle(struct msDeflateCtx* c) { return (int64_t)(intptr_t)c; }
static inline struct msDeflateCtx* handleToCtx(int64_t h) { return (struct msDeflateCtx*)(intptr_t)h; }

/* ===== Gzip header / trailer ===== */

/* Fixed 10-byte gzip header: magic, CM=8 (deflate), FLG=0, MTIME=0, XFL=0, OS=3 (Unix). */
static const uint8_t GZ_HEADER[10] = {
    0x1F, 0x8B, 0x08, 0x00,   /* magic + CM + FLG */
    0x00, 0x00, 0x00, 0x00,   /* MTIME */
    0x00, 0x03                /* XFL + OS */
};

static void writeLE32(uint8_t* out, uint32_t v) {
    out[0] = (uint8_t)(v & 0xFF);
    out[1] = (uint8_t)((v >> 8) & 0xFF);
    out[2] = (uint8_t)((v >> 16) & 0xFF);
    out[3] = (uint8_t)((v >> 24) & 0xFF);
}

/* ===== Public API ===== */

int64_t msDeflateNew(int32_t format, int32_t level) {
    if (format != MS_COMPRESS_FORMAT_GZIP &&
        format != MS_COMPRESS_FORMAT_ZLIB &&
        format != MS_COMPRESS_FORMAT_DEFLATE) return 0;

    if (level < 0) level = 6;
    if (level > 10) level = 10;

    struct msDeflateCtx* c = (struct msDeflateCtx*)calloc(1, sizeof(*c));
    if (!c) return 0;
    c->format = format;
    c->crc32 = MZ_CRC32_INIT;

    /* miniz compression flags:
     *   - raw deflate:        window_bits -15 (no wrapper)
     *   - zlib wrapper:       TDEFL_WRITE_ZLIB_HEADER | window_bits 15
     *   - gzip (our wrapper): raw deflate, we synthesize header+trailer ourselves
     */
    int window_bits = -15;  /* raw deflate, no wrapper */
    int strategy = MZ_DEFAULT_STRATEGY;
    mz_uint flags = (mz_uint)tdefl_create_comp_flags_from_zip_params(level, window_bits, strategy);
    if (format == MS_COMPRESS_FORMAT_ZLIB) {
        flags |= TDEFL_WRITE_ZLIB_HEADER;
    }

    if (tdefl_init(&c->tdefl, NULL, NULL, (int)flags) != TDEFL_STATUS_OKAY) {
        free(c);
        return 0;
    }

    /* For gzip, prewrite the 10-byte header to the output queue. */
    if (format == MS_COMPRESS_FORMAT_GZIP) {
        if (queuePush(c, GZ_HEADER, sizeof(GZ_HEADER)) < 0) {
            free(c);
            return 0;
        }
    }

    return ctxToHandle(c);
}

void msDeflateFree(int64_t handle) {
    struct msDeflateCtx* c = handleToCtx(handle);
    if (!c) return;
    free(c->queue);
    free(c);
}

int32_t msDeflateFeed(int64_t handle, msString inChunk, int32_t isLast) {
    struct msDeflateCtx* c = handleToCtx(handle);
    if (!c || c->errored) return -1;
    if (c->finished) return 1;

    const uint8_t* in = (inChunk.p && inChunk.len > 0) ? (const uint8_t*)inChunk.p->data : NULL;
    size_t inLen = (size_t)inChunk.len;
    size_t inPos = 0;

    /* For gzip, update CRC32 + total input length over all feed() calls. */
    if (c->format == MS_COMPRESS_FORMAT_GZIP && in && inLen > 0) {
        c->crc32 = mz_crc32(c->crc32, in, inLen);
        c->inputBytes += inLen;
    }

    /* Drive tdefl_compress until it consumes everything we gave it (and
     * emits all the output it wants to). On isLast, issue TDEFL_FINISH
     * repeatedly until TDEFL_STATUS_DONE. */
    while (1) {
        size_t inBytes = inLen - inPos;
        size_t outBytes = DEFLATE_OUT_BUF_SIZE;

        tdefl_flush flush = isLast ? TDEFL_FINISH : TDEFL_NO_FLUSH;

        tdefl_status st = tdefl_compress(
            &c->tdefl,
            in ? in + inPos : NULL, &inBytes,
            c->outBuf, &outBytes,
            flush);

        inPos += inBytes;

        if (outBytes > 0) {
            if (queuePush(c, c->outBuf, outBytes) < 0) {
                c->errored = 1;
                return -1;
            }
        }

        if (st == TDEFL_STATUS_DONE) {
            c->finished = 1;
            break;
        }
        if (st < 0) {
            c->errored = 1;
            return -1;
        }

        /* Not done, not errored — need more work. Loop unless we've fully
         * consumed the input AND we're not finishing. */
        if (!isLast && inPos >= inLen && outBytes == 0) break;
    }

    /* On finish with gzip, append the 8-byte trailer: CRC32 + ISIZE (both LE).
     *
     * ISIZE is defined by RFC 1952 as the input size mod 2^32, so inputs
     * larger than 4 GiB will round-trip correctly in every decoder but
     * report a reduced ISIZE. CRC32 is computed over the full input and is
     * always accurate. */
    if (c->finished && c->format == MS_COMPRESS_FORMAT_GZIP) {
        uint8_t trailer[8];
        writeLE32(trailer, (uint32_t)c->crc32);
        writeLE32(trailer + 4, (uint32_t)(c->inputBytes & 0xFFFFFFFFu));
        if (queuePush(c, trailer, sizeof(trailer)) < 0) {
            c->errored = 1;
            return -1;
        }
    }

    return c->finished ? 1 : 0;
}

msString msDeflateDrain(int64_t handle, int32_t maxBytes) {
    struct msDeflateCtx* c = handleToCtx(handle);
    if (!c || c->queueLen == 0) return MS_EMPTY_STRING;

    size_t take = (size_t)maxBytes;
    if (take == 0 || take > c->queueLen) take = c->queueLen;

    msString out = msStringNew((const char*)c->queue, (int64_t)take);

    size_t remain = c->queueLen - take;
    if (remain > 0) memmove(c->queue, c->queue + take, remain);
    c->queueLen = remain;

    return out;
}

msString msDeflateOneShot(msString data, int32_t format, int32_t level) {
    int64_t h = msDeflateNew(format, level);
    if (!h) return MS_EMPTY_STRING;

    int32_t st = msDeflateFeed(h, data, 1);
    if (st < 0) { msDeflateFree(h); return MS_EMPTY_STRING; }

    struct msDeflateCtx* c = handleToCtx(h);
    msString out = MS_EMPTY_STRING;
    if (c->queueLen > 0) {
        out = msStringNew((const char*)c->queue, (int64_t)c->queueLen);
    }
    msDeflateFree(h);
    return out;
}
