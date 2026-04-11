/*
 * MetaScript ZIP archive runtime — read + write via miniz's mz_zip_* API.
 *
 * Handles in-memory archive parsing (no filesystem I/O). The reader copies
 * the input buffer because miniz reads from the passed pointer lazily during
 * extract calls. The writer grows a heap-allocated archive buffer as entries
 * are added, then finalises it into a single msString on close.
 */

#ifndef MS_COMPRESS_ZIP_H
#define MS_COMPRESS_ZIP_H

#include "runtime/core/string.h"
#include <stdint.h>

/* ===== Reader ===== */

typedef struct msZipReaderCtx msZipReaderCtx;

/* Parse an archive from an in-memory buffer. Returns an opaque handle or 0. */
int64_t msZipReaderOpen(msString data);

/* Number of entries in the archive. -1 on bad handle. */
int32_t msZipReaderCount(int64_t handle);

/* Entry filename (empty string on bad index). */
msString msZipReaderEntryName(int64_t handle, int32_t index);

/* Entry uncompressed size in bytes (-1 on bad index). */
int64_t msZipReaderEntrySize(int64_t handle, int32_t index);

/* 1 if entry is a directory, 0 if regular file, -1 on bad index. */
int32_t msZipReaderEntryIsDir(int64_t handle, int32_t index);

/* Decompress entry into a fresh msString. MS_EMPTY_STRING on error. */
msString msZipReaderExtract(int64_t handle, int32_t index);

/* Release reader and its buffered input copy. */
void msZipReaderClose(int64_t handle);

/* ===== Writer ===== */

typedef struct msZipWriterCtx msZipWriterCtx;

/* Create an in-memory ZIP writer. Returns 0 on allocation failure. */
int64_t msZipWriterNew(void);

/* Add one entry with the given name, bytes, and compression level (0-9, 6 default).
 * Returns 0 on OK, <0 on error. */
int32_t msZipWriterAdd(int64_t handle, msString name, msString data, int32_t level);

/* Finalise the archive and return the resulting bytes.
 * After this call, only msZipWriterClose is valid. */
msString msZipWriterFinalize(int64_t handle);

/* Release writer. Safe on handle=0. */
void msZipWriterClose(int64_t handle);

#endif
