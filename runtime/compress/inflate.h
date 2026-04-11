/*
 * MetaScript Compress Runtime — streaming inflate wrapping miniz
 *
 * Wraps miniz's low-level `tinfl_decompress` state machine to provide:
 *   1. Streaming decompress (feed chunks, pull chunks) — for large files / HTTP bodies
 *   2. One-shot decompress — convenience for in-memory blobs
 *
 * Supports raw deflate, zlib (RFC 1950), and gzip (RFC 1952) input formats.
 *
 * All deflate compression / ZIP archive APIs are disabled via preprocessor
 * flags to keep the compiled footprint minimal (~20 KB). Enable them when
 * `msc publish` needs to create tarballs.
 */

#ifndef MS_COMPRESS_INFLATE_H
#define MS_COMPRESS_INFLATE_H

#include "runtime/core/string.h"
#include <stdint.h>

/* ===== Format selectors ===== */

/* Mirror the MS enum in std/compress/index.cms */
#define MS_COMPRESS_FORMAT_GZIP    0
#define MS_COMPRESS_FORMAT_ZLIB    1
#define MS_COMPRESS_FORMAT_DEFLATE 2

/* ===== Streaming API ===== */

/* Opaque handle; internally points to a heap-allocated context holding the
 * tinfl_decompressor + LZ dictionary + gzip header parser state. */
typedef struct msInflateCtx msInflateCtx;

/* Create a streaming inflate context. Returns 0 on allocation failure. */
int64_t msInflateNew(int32_t format);

/* Feed a chunk of compressed input; the context buffers decoded output
 * internally. Call msInflateDrain() to retrieve decoded bytes.
 *
 * Returns:
 *    0 = input chunk fully consumed, call drain then feed next chunk
 *    1 = stream successfully ended (saw final block + trailer)
 *  < 0 = error (corrupted input, adler/crc mismatch, etc.)
 *
 * `isLast` should be 1 on the final chunk of the stream, 0 otherwise.
 */
int32_t msInflateFeed(int64_t handle, msString inChunk, int32_t isLast);

/* Copy up to `maxBytes` of decoded output from the context's internal buffer
 * into a fresh msString. Consumes the returned bytes from the buffer. Returns
 * MS_EMPTY_STRING when no output is ready. */
msString msInflateDrain(int64_t handle, int32_t maxBytes);

/* Destroy a streaming inflate context. Safe to call with handle=0. */
void msInflateFree(int64_t handle);

/* ===== One-shot API (thin wrapper over streaming) ===== */

/* Decompress an in-memory blob. Returns MS_EMPTY_STRING on error. */
msString msInflateOneShot(msString data, int32_t format);

#endif
