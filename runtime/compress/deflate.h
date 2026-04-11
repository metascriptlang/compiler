/*
 * MetaScript streaming deflate wrapper — gzip / zlib / raw DEFLATE output.
 *
 * Wraps miniz's low-level tdefl_compress state machine. Supports:
 *   - MS_COMPRESS_FORMAT_GZIP    → RFC 1952 gzip (10-byte header + raw deflate + 8-byte CRC32+ISIZE trailer)
 *   - MS_COMPRESS_FORMAT_ZLIB    → RFC 1950 zlib wrapper (via TDEFL_WRITE_ZLIB_HEADER)
 *   - MS_COMPRESS_FORMAT_DEFLATE → RFC 1951 raw DEFLATE
 *
 * Compression level: 0-10 (0 = none, 1 = fastest, 6 = default, 9 = best, 10 = uber).
 */

#ifndef MS_COMPRESS_DEFLATE_H
#define MS_COMPRESS_DEFLATE_H

#include "runtime/core/string.h"
#include <stdint.h>

/* Format selectors — must match runtime/compress/inflate.h and the MS enum. */
#define MS_COMPRESS_FORMAT_GZIP    0
#define MS_COMPRESS_FORMAT_ZLIB    1
#define MS_COMPRESS_FORMAT_DEFLATE 2

/* ===== Streaming API ===== */

typedef struct msDeflateCtx msDeflateCtx;

/* Create a streaming deflate context.
 *   format: one of MS_COMPRESS_FORMAT_*
 *   level:  0-10 (6 is a reasonable default)
 * Returns an opaque handle (int64) or 0 on allocation failure. */
int64_t msDeflateNew(int32_t format, int32_t level);

/* Feed a chunk of uncompressed input.
 *   handle: from msDeflateNew()
 *   inChunk: raw bytes to compress
 *   isLast:  1 to signal end-of-stream (flushes the compressor and writes the trailer for gzip)
 * Returns 0 on OK, 1 when the stream has been finalised, or <0 on error. */
int32_t msDeflateFeed(int64_t handle, msString inChunk, int32_t isLast);

/* Copy up to `maxBytes` of compressed output from the context's internal queue.
 * Passing maxBytes=0 drains everything available. */
msString msDeflateDrain(int64_t handle, int32_t maxBytes);

/* Destroy a streaming deflate context. Safe on handle=0. */
void msDeflateFree(int64_t handle);

/* ===== One-shot ===== */

/* Compress an entire in-memory buffer in one call. Returns MS_EMPTY_STRING on error. */
msString msDeflateOneShot(msString data, int32_t format, int32_t level);

#endif
