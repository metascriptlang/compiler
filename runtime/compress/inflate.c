/*
 * MetaScript streaming inflate wrapper.
 * Wraps miniz's low-level tinfl_decompress state machine.
 */

#include "runtime/compress/inflate.h"

#include <stdlib.h>
#include <string.h>

/* Scope miniz to decompress-only before including its header. */
#define MINIZ_NO_DEFLATE_APIS
#define MINIZ_NO_ARCHIVE_APIS
#define MINIZ_NO_ARCHIVE_WRITING_APIS
#define MINIZ_NO_ZLIB_APIS
#define MINIZ_NO_ZLIB_COMPATIBLE_NAMES
#define MINIZ_NO_STDIO
#define MINIZ_NO_TIME
#include "vendor/miniz/miniz.h"

/* ===== Internal Constants ===== */

#define MS_INFLATE_OUT_BUF_SIZE (32 * 1024)   /* = TINFL_LZ_DICT_SIZE, required by tinfl */

/* Max total bytes retained in the output queue across a stream's lifetime.
 * Sized for real-world package tarballs: a 5 MB compressed tar.gz commonly
 * expands to 20–40 MB. Callers who stream (drain between feeds) never hit
 * this; the cap only matters for one-shot decompression of huge blobs. */
#define MS_INFLATE_OUT_QUEUE_CAP (64 * 1024 * 1024)

/* Gzip header flag bits (RFC 1952) */
#define GZ_FTEXT    0x01
#define GZ_FHCRC    0x02
#define GZ_FEXTRA   0x04
#define GZ_FNAME    0x08
#define GZ_FCOMMENT 0x10

typedef enum { GZ_STAGE_FIXED = 0, GZ_STAGE_XLEN, GZ_STAGE_EXTRA, GZ_STAGE_NAME, GZ_STAGE_COMMENT, GZ_STAGE_HCRC, GZ_STAGE_END } gzStage;

/* ===== Context ===== */

typedef enum {
    GZ_STATE_HEADER = 0,   /* consuming gzip header bytes */
    GZ_STATE_BODY,         /* feeding raw deflate to tinfl */
    GZ_STATE_TRAILER,      /* consuming CRC32 + ISIZE */
    GZ_STATE_DONE,
    GZ_STATE_ERROR
} gzState;

struct msInflateCtx {
    int32_t format;             /* MS_COMPRESS_FORMAT_* */
    tinfl_decompressor tinfl;   /* ~11 KB */
    uint8_t outBuf[MS_INFLATE_OUT_BUF_SIZE];
    size_t outNext;             /* write cursor inside outBuf ring */

    /* Queued decoded output waiting to be drained. */
    uint8_t* queue;
    size_t queueLen;
    size_t queueCap;

    /* gzip parser state */
    gzState gzState;
    gzStage gzStage;
    uint32_t gzHdrBytesSeen;    /* bytes consumed of the fixed 10-byte gzip header */
    uint8_t  gzFlg;
    uint32_t gzXlenSeen;
    uint32_t gzExtraRemain;     /* bytes left in FEXTRA (if present) */
    uint32_t gzHcrcSeen;
    uint32_t gzHcrcGot;
    int      gzHcrcBad;
    uint32_t gzHdrCrc;
    uint32_t gzCrc;             /* CRC32 of the current member's output */
    uint64_t gzOutSize;
    uint8_t  gzTrailer[8];
    uint32_t gzTrailerBytesSeen;
    uint32_t gzMembers;         /* members fully decoded */
    int      gzPadded;          /* a zero byte followed the last member: the rest is padding */
};

/* ===== Queue helpers ===== */

static int queuePush(struct msInflateCtx* c, const uint8_t* data, size_t len) {
    if (len == 0) return 0;
    size_t needed = c->queueLen + len;
    if (needed > MS_INFLATE_OUT_QUEUE_CAP) return -1;
    if (needed > c->queueCap) {
        size_t newCap = c->queueCap == 0 ? 4096 : c->queueCap * 2;
        while (newCap < needed) newCap *= 2;
        c->queue = (uint8_t*)msRealloc(c->queue, c->queueCap, newCap);
        c->queueCap = newCap;
    }
    memcpy(c->queue + c->queueLen, data, len);
    c->queueLen += len;
    return 0;
}

/* ===== Handle <-> pointer conversion =====
 * Pointers are returned as int64_t so the MS extern signature stays int/string only. */
static inline int64_t ctxToHandle(struct msInflateCtx* c) { return (int64_t)(intptr_t)c; }
static inline struct msInflateCtx* handleToCtx(int64_t h) { return (struct msInflateCtx*)(intptr_t)h; }

/* ===== Public API ===== */

int64_t msInflateNew(int32_t format) {
    if (format != MS_COMPRESS_FORMAT_GZIP &&
        format != MS_COMPRESS_FORMAT_ZLIB &&
        format != MS_COMPRESS_FORMAT_DEFLATE) return 0;

    struct msInflateCtx* c = (struct msInflateCtx*)msMemAlloc0(sizeof(*c));
    tinfl_init(&c->tinfl);
    c->format = format;
    c->gzState = (format == MS_COMPRESS_FORMAT_GZIP) ? GZ_STATE_HEADER : GZ_STATE_BODY;
    return ctxToHandle(c);
}

void msInflateFree(int64_t handle) {
    struct msInflateCtx* c = handleToCtx(handle);
    if (!c) return;
    free(c->queue);
    free(c);
}

static int gzStageWanted(const struct msInflateCtx* c, gzStage s) {
    switch (s) {
        case GZ_STAGE_XLEN: return (c->gzFlg & GZ_FEXTRA) != 0;
        case GZ_STAGE_EXTRA: return (c->gzFlg & GZ_FEXTRA) != 0 && c->gzExtraRemain > 0;
        case GZ_STAGE_NAME: return (c->gzFlg & GZ_FNAME) != 0;
        case GZ_STAGE_COMMENT: return (c->gzFlg & GZ_FCOMMENT) != 0;
        case GZ_STAGE_HCRC: return (c->gzFlg & GZ_FHCRC) != 0;
        default: return 1;
    }
}

static void gzAdvanceStage(struct msInflateCtx* c) {
    do c->gzStage = (gzStage)(c->gzStage + 1); while (!gzStageWanted(c, c->gzStage));
    if (c->gzStage == GZ_STAGE_END) c->gzState = GZ_STATE_BODY;
}

static void gzBeginMember(struct msInflateCtx* c) {
    tinfl_init(&c->tinfl);
    c->outNext = 0;
    c->gzState = GZ_STATE_HEADER;
    c->gzStage = GZ_STAGE_FIXED;
    c->gzHdrBytesSeen = 0;
    c->gzFlg = 0;
    c->gzXlenSeen = 0;
    c->gzExtraRemain = 0;
    c->gzHcrcSeen = 0;
    c->gzHcrcGot = 0;
    c->gzHcrcBad = 0;
    c->gzHdrCrc = 0;
    c->gzCrc = 0;
    c->gzOutSize = 0;
    c->gzTrailerBytesSeen = 0;
}

static int32_t gzHeaderError(const struct msInflateCtx* c) {
    return c->gzMembers > 0 ? MS_INFLATE_ERR_TRAILING : MS_INFLATE_ERR_INVALID;
}

static size_t gzConsumeHeader(struct msInflateCtx* c, const uint8_t* in, size_t inLen) {
    size_t i = 0;
    while (i < inLen && c->gzState == GZ_STATE_HEADER) {
        uint8_t b = in[i++];
        if (c->gzStage != GZ_STAGE_HCRC) c->gzHdrCrc = (uint32_t)mz_crc32(c->gzHdrCrc, &b, 1);

        switch (c->gzStage) {
            case GZ_STAGE_FIXED:
                if (c->gzHdrBytesSeen == 0 && b != 0x1F) { c->gzState = GZ_STATE_ERROR; return i; }
                if (c->gzHdrBytesSeen == 1 && b != 0x8B) { c->gzState = GZ_STATE_ERROR; return i; }
                if (c->gzHdrBytesSeen == 2 && b != 0x08) { c->gzState = GZ_STATE_ERROR; return i; }
                if (c->gzHdrBytesSeen == 3) {
                    c->gzFlg = b;
                    if (b & 0xE0) { c->gzState = GZ_STATE_ERROR; return i; }
                }
                if (++c->gzHdrBytesSeen == 10) gzAdvanceStage(c);
                break;
            case GZ_STAGE_XLEN:
                c->gzExtraRemain |= (uint32_t)b << (8 * c->gzXlenSeen);
                if (++c->gzXlenSeen == 2) gzAdvanceStage(c);
                break;
            case GZ_STAGE_EXTRA:
                if (--c->gzExtraRemain == 0) gzAdvanceStage(c);
                break;
            case GZ_STAGE_NAME:
                if (b == 0) gzAdvanceStage(c);
                break;
            case GZ_STAGE_COMMENT:
                if (b == 0) gzAdvanceStage(c);
                break;
            case GZ_STAGE_HCRC:
                c->gzHcrcGot |= (uint32_t)b << (8 * c->gzHcrcSeen);
                if (++c->gzHcrcSeen == 2) {
                    if (c->gzHcrcGot != (c->gzHdrCrc & 0xFFFF)) { c->gzState = GZ_STATE_ERROR; c->gzHcrcBad = 1; return i; }
                    gzAdvanceStage(c);
                }
                break;
            case GZ_STAGE_END:
                break;
        }
    }
    return i;
}

static uint32_t le32(const uint8_t* p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int32_t gzConsumeTrailer(struct msInflateCtx* c, const uint8_t* in, size_t inLen, size_t* used) {
    size_t want = 8 - c->gzTrailerBytesSeen;
    size_t take = inLen < want ? inLen : want;
    if (take > 0) memcpy(c->gzTrailer + c->gzTrailerBytesSeen, in, take);
    c->gzTrailerBytesSeen += (uint32_t)take;
    *used = take;
    if (c->gzTrailerBytesSeen < 8) return 0;
    if (le32(c->gzTrailer) != c->gzCrc) { c->gzState = GZ_STATE_ERROR; return MS_INFLATE_ERR_CHECKSUM; }
    if (le32(c->gzTrailer + 4) != (uint32_t)c->gzOutSize) { c->gzState = GZ_STATE_ERROR; return MS_INFLATE_ERR_LENGTH; }
    c->gzMembers++;
    c->gzState = GZ_STATE_DONE;
    return 0;
}

static int32_t tinflError(tinfl_status st) {
    if (st == TINFL_STATUS_FAILED_CANNOT_MAKE_PROGRESS) return MS_INFLATE_ERR_TRUNCATED;
    if (st == TINFL_STATUS_ADLER32_MISMATCH) return MS_INFLATE_ERR_CHECKSUM;
    return MS_INFLATE_ERR_INVALID;
}

static int32_t inflateBody(struct msInflateCtx* c, const uint8_t* in, size_t inLen, size_t* inPos, int32_t isLast) {
    uint32_t decompFlags = c->format == MS_COMPRESS_FORMAT_ZLIB ? TINFL_FLAG_PARSE_ZLIB_HEADER | TINFL_FLAG_COMPUTE_ADLER32 : 0;
    while (c->gzState == GZ_STATE_BODY && (*inPos < inLen || isLast)) {
        size_t inBytes = inLen - *inPos;
        size_t outBytes = MS_INFLATE_OUT_BUF_SIZE - c->outNext;
        uint32_t flags = decompFlags;
        if (!isLast) flags |= TINFL_FLAG_HAS_MORE_INPUT;

        tinfl_status st = tinfl_decompress(
            &c->tinfl,
            in ? in + *inPos : NULL, &inBytes,
            c->outBuf, c->outBuf + c->outNext, &outBytes,
            flags);

        *inPos += inBytes;
        if (outBytes > 0) {
            if (c->format == MS_COMPRESS_FORMAT_GZIP) {
                c->gzCrc = (uint32_t)mz_crc32(c->gzCrc, c->outBuf + c->outNext, outBytes);
                c->gzOutSize += outBytes;
            }
            if (queuePush(c, c->outBuf + c->outNext, outBytes) < 0) {
                c->gzState = GZ_STATE_ERROR;
                return MS_INFLATE_ERR_INVALID;
            }
            c->outNext = (c->outNext + outBytes) & (MS_INFLATE_OUT_BUF_SIZE - 1);
        }

        if (st < 0) {
            c->gzState = GZ_STATE_ERROR;
            return tinflError(st);
        }
        if (st == TINFL_STATUS_DONE) {
            c->gzState = c->format == MS_COMPRESS_FORMAT_GZIP ? GZ_STATE_TRAILER : GZ_STATE_DONE;
        } else if (st == TINFL_STATUS_NEEDS_MORE_INPUT) {
            if (isLast && *inPos >= inLen) {
                c->gzState = GZ_STATE_ERROR;
                return MS_INFLATE_ERR_TRUNCATED;
            }
            break;
        }
    }
    return 0;
}

int32_t msInflateFeed(int64_t handle, const uint8_t* in, int64_t inLenBytes, int32_t isLast) {
    struct msInflateCtx* c = handleToCtx(handle);
    if (!c) return MS_INFLATE_ERR_INVALID;
    if (c->gzState == GZ_STATE_ERROR) return MS_INFLATE_ERR_INVALID;

    if (inLenBytes <= 0) in = NULL;
    size_t inLen = in ? (size_t)inLenBytes : 0;
    size_t inPos = 0;

    for (;;) {
        int32_t err = 0;
        if (c->gzState == GZ_STATE_DONE) {
            if (c->format != MS_COMPRESS_FORMAT_GZIP || c->gzPadded || inPos >= inLen) break;
            if (in[inPos] == 0) { c->gzPadded = 1; break; }
            gzBeginMember(c);
        } else if (c->gzState == GZ_STATE_HEADER) {
            inPos += gzConsumeHeader(c, in ? in + inPos : NULL, inLen - inPos);
            if (c->gzState == GZ_STATE_ERROR) return c->gzHcrcBad && c->gzMembers == 0 ? MS_INFLATE_ERR_CHECKSUM : gzHeaderError(c);
            if (c->gzState == GZ_STATE_HEADER) break;
        } else if (c->gzState == GZ_STATE_BODY) {
            err = inflateBody(c, in, inLen, &inPos, isLast);
            if (err < 0) return err;
            if (c->gzState == GZ_STATE_BODY) break;
        } else if (c->gzState == GZ_STATE_TRAILER) {
            size_t used = 0;
            err = gzConsumeTrailer(c, in ? in + inPos : NULL, inLen - inPos, &used);
            inPos += used;
            if (err < 0) return err;
            if (c->gzState == GZ_STATE_TRAILER) break;
        } else {
            break;
        }
    }

    if (c->gzState == GZ_STATE_DONE) return 1;
    if (isLast) {
        c->gzState = GZ_STATE_ERROR;
        return MS_INFLATE_ERR_TRUNCATED;
    }
    return 0;
}

msUint8Array msInflateDrain(int64_t handle, int32_t maxBytes) {
    struct msInflateCtx* c = handleToCtx(handle);
    if (!c || c->queueLen == 0) return MS_EMPTY_UINT8_ARRAY;

    size_t take = (size_t)maxBytes;
    if (take == 0 || take > c->queueLen) take = c->queueLen;

    msUint8Array out = msBufferFrom(c->queue, (int64_t)take);

    size_t remain = c->queueLen - take;
    if (remain > 0) memmove(c->queue, c->queue + take, remain);
    c->queueLen = remain;

    return out;
}
