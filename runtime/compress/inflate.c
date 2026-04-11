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
    uint32_t gzHdrBytesSeen;    /* bytes consumed of the fixed 10-byte gzip header */
    uint8_t  gzFlg;
    uint32_t gzExtraRemain;     /* bytes left in FEXTRA (if present) */
    int      gzSkipNameTerm;    /* true while eating FNAME bytes until 0x00 */
    int      gzSkipCommentTerm;
    uint32_t gzHcrcRemain;      /* 2 bytes if FHCRC set */
    uint32_t gzTrailerBytesSeen;

    int streamEnded;
};

/* ===== Queue helpers ===== */

static int queuePush(struct msInflateCtx* c, const uint8_t* data, size_t len) {
    if (len == 0) return 0;
    size_t needed = c->queueLen + len;
    if (needed > MS_INFLATE_OUT_QUEUE_CAP) return -1;
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

/* ===== Handle <-> pointer conversion =====
 * Pointers are returned as int64_t so the MS extern signature stays int/string only. */
static inline int64_t ctxToHandle(struct msInflateCtx* c) { return (int64_t)(intptr_t)c; }
static inline struct msInflateCtx* handleToCtx(int64_t h) { return (struct msInflateCtx*)(intptr_t)h; }

/* ===== Public API ===== */

int64_t msInflateNew(int32_t format) {
    if (format != MS_COMPRESS_FORMAT_GZIP &&
        format != MS_COMPRESS_FORMAT_ZLIB &&
        format != MS_COMPRESS_FORMAT_DEFLATE) return 0;

    struct msInflateCtx* c = (struct msInflateCtx*)calloc(1, sizeof(*c));
    if (!c) return 0;
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

/* Parse incoming bytes against the gzip header state machine.
 * Returns the number of bytes consumed; sets c->gzState to GZ_STATE_BODY
 * once the full header is past, or GZ_STATE_ERROR on invalid header. */
static size_t gzConsumeHeader(struct msInflateCtx* c, const uint8_t* in, size_t inLen) {
    size_t i = 0;
    while (i < inLen && c->gzState == GZ_STATE_HEADER) {
        uint8_t b = in[i];

        if (c->gzHdrBytesSeen < 10) {
            /* Fixed 10-byte header:
             * [0] = 0x1F, [1] = 0x8B, [2] = CM=8, [3] = FLG, [4..7] = MTIME, [8] = XFL, [9] = OS */
            switch (c->gzHdrBytesSeen) {
                case 0: if (b != 0x1F) { c->gzState = GZ_STATE_ERROR; return i; } break;
                case 1: if (b != 0x8B) { c->gzState = GZ_STATE_ERROR; return i; } break;
                case 2: if (b != 0x08) { c->gzState = GZ_STATE_ERROR; return i; } break; /* CM must be DEFLATE */
                case 3: c->gzFlg = b; break;
                default: break; /* MTIME/XFL/OS — ignored */
            }
            c->gzHdrBytesSeen++;
            i++;

            /* After finishing the fixed header, set up the optional extras state. */
            if (c->gzHdrBytesSeen == 10) {
                if (c->gzFlg & GZ_FEXTRA) c->gzExtraRemain = (uint32_t)-1; /* -1 = need XLEN */
                if (c->gzFlg & GZ_FNAME) c->gzSkipNameTerm = 1;
                if (c->gzFlg & GZ_FCOMMENT) c->gzSkipCommentTerm = 1;
                if (c->gzFlg & GZ_FHCRC) c->gzHcrcRemain = 2;
            }
            continue;
        }

        /* FEXTRA: first 2 bytes are little-endian XLEN, then XLEN bytes of data. */
        if (c->gzFlg & GZ_FEXTRA) {
            if (c->gzExtraRemain == (uint32_t)-1) {
                c->gzExtraRemain = b;  /* low byte of XLEN */
                c->gzFlg &= ~GZ_FEXTRA;
                c->gzFlg |= 0x80;      /* reuse high bit as "XLEN low seen, need high" */
                i++;
                continue;
            }
            if (c->gzFlg & 0x80) {
                c->gzExtraRemain |= ((uint32_t)b) << 8;
                c->gzFlg &= ~0x80;
                i++;
                continue;
            }
            i++;
            c->gzExtraRemain--;
            if (c->gzExtraRemain == 0) c->gzFlg &= ~GZ_FEXTRA; /* done */
            continue;
        }

        if (c->gzSkipNameTerm) {
            i++;
            if (b == 0x00) c->gzSkipNameTerm = 0;
            continue;
        }
        if (c->gzSkipCommentTerm) {
            i++;
            if (b == 0x00) c->gzSkipCommentTerm = 0;
            continue;
        }
        if (c->gzHcrcRemain) {
            i++;
            c->gzHcrcRemain--;
            continue;
        }

        /* Header fully consumed — enter body. */
        c->gzState = GZ_STATE_BODY;
    }

    /* If we reach here with exactly 10 header bytes and no optional fields needed,
     * transition immediately to body. */
    if (c->gzState == GZ_STATE_HEADER && c->gzHdrBytesSeen >= 10
        && !(c->gzFlg & (GZ_FEXTRA | 0x80))
        && !c->gzSkipNameTerm && !c->gzSkipCommentTerm && !c->gzHcrcRemain) {
        c->gzState = GZ_STATE_BODY;
    }
    return i;
}

/* Consume the 8-byte gzip trailer (CRC32 + ISIZE). We don't verify — the
 * deflate stream's own integrity is checked by miniz, and the tarball sha256
 * provides end-to-end integrity. */
static size_t gzConsumeTrailer(struct msInflateCtx* c, size_t inLen) {
    size_t want = 8 - c->gzTrailerBytesSeen;
    size_t take = inLen < want ? inLen : want;
    c->gzTrailerBytesSeen += (uint32_t)take;
    if (c->gzTrailerBytesSeen >= 8) c->gzState = GZ_STATE_DONE;
    return take;
}

int32_t msInflateFeed(int64_t handle, msString inChunk, int32_t isLast) {
    struct msInflateCtx* c = handleToCtx(handle);
    if (!c) return -1;
    if (c->gzState == GZ_STATE_ERROR) return -1;

    const uint8_t* in = (inChunk.p && inChunk.len > 0) ? (const uint8_t*)inChunk.p->data : NULL;
    size_t inLen = (size_t)inChunk.len;
    size_t inPos = 0;

    /* 1. Eat gzip header bytes (only if format=gzip). */
    if (c->gzState == GZ_STATE_HEADER) {
        size_t consumed = gzConsumeHeader(c, in, inLen);
        inPos += consumed;
        if (c->gzState == GZ_STATE_ERROR) return -1;
        if (c->gzState == GZ_STATE_HEADER) {
            /* Still waiting for more header bytes. */
            return isLast ? -1 : 0;
        }
    }

    /* 2. Feed body bytes to tinfl until it's satisfied. */
    uint32_t decompFlags = 0;
    if (c->format == MS_COMPRESS_FORMAT_ZLIB) decompFlags |= TINFL_FLAG_PARSE_ZLIB_HEADER;
    /* For gzip and raw deflate, no zlib header. */

    while (c->gzState == GZ_STATE_BODY && (inPos < inLen || isLast)) {
        size_t inBytes = inLen - inPos;
        size_t outBytes = MS_INFLATE_OUT_BUF_SIZE - c->outNext;

        uint32_t flags = decompFlags;
        if (!isLast || inPos + inBytes < inLen) flags |= TINFL_FLAG_HAS_MORE_INPUT;

        tinfl_status st = tinfl_decompress(
            &c->tinfl,
            in ? in + inPos : NULL, &inBytes,
            c->outBuf, c->outBuf + c->outNext, &outBytes,
            flags);

        inPos += inBytes;
        if (outBytes > 0) {
            if (queuePush(c, c->outBuf + c->outNext, outBytes) < 0) {
                c->gzState = GZ_STATE_ERROR;
                return -1;
            }
            c->outNext = (c->outNext + outBytes) & (MS_INFLATE_OUT_BUF_SIZE - 1);
        }

        if (st < 0) {
            c->gzState = GZ_STATE_ERROR;
            return -1;
        }
        if (st == TINFL_STATUS_DONE) {
            c->gzState = (c->format == MS_COMPRESS_FORMAT_GZIP) ? GZ_STATE_TRAILER : GZ_STATE_DONE;
            break;
        }
        if (st == TINFL_STATUS_NEEDS_MORE_INPUT) {
            if (isLast && inPos >= inLen) {
                c->gzState = GZ_STATE_ERROR;
                return -1;
            }
            break;
        }
        /* TINFL_STATUS_HAS_MORE_OUTPUT: loop and give tinfl another pass. */
    }

    /* 3. Eat gzip trailer if applicable. */
    if (c->gzState == GZ_STATE_TRAILER) {
        size_t consumed = gzConsumeTrailer(c, inLen - inPos);
        inPos += consumed;
    }

    if (c->gzState == GZ_STATE_DONE) {
        c->streamEnded = 1;
        return 1;
    }
    return 0;
}

msString msInflateDrain(int64_t handle, int32_t maxBytes) {
    struct msInflateCtx* c = handleToCtx(handle);
    if (!c || c->queueLen == 0) return MS_EMPTY_STRING;

    size_t take = (size_t)maxBytes;
    if (take == 0 || take > c->queueLen) take = c->queueLen;

    msString out = msStringNew((const char*)c->queue, (int64_t)take);

    size_t remain = c->queueLen - take;
    if (remain > 0) memmove(c->queue, c->queue + take, remain);
    c->queueLen = remain;

    return out;
}

msString msInflateOneShot(msString data, int32_t format) {
    int64_t h = msInflateNew(format);
    if (!h) return MS_EMPTY_STRING;

    int32_t st = msInflateFeed(h, data, 1);
    if (st < 0) { msInflateFree(h); return MS_EMPTY_STRING; }

    struct msInflateCtx* c = handleToCtx(h);
    msString out = MS_EMPTY_STRING;
    if (c->queueLen > 0) {
        out = msStringNew((const char*)c->queue, (int64_t)c->queueLen);
    }
    msInflateFree(h);
    return out;
}
