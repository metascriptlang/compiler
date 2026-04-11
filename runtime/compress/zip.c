/*
 * MetaScript ZIP runtime — wraps miniz's mz_zip_archive reader + writer.
 */

#include "runtime/compress/zip.h"

#include <stdlib.h>
#include <string.h>

/* miniz's ZIP API needs both tdefl and tinfl internally (entries can be
 * deflate-compressed), but we don't disable either — all archive APIs pull
 * them in by inclusion.                                                     */
#define MINIZ_NO_ZLIB_APIS
#define MINIZ_NO_ZLIB_COMPATIBLE_NAMES
#define MINIZ_NO_STDIO
#define MINIZ_NO_TIME
#include "vendor/miniz/miniz.h"

/* ===== Contexts ===== */

struct msZipReaderCtx {
    mz_zip_archive zip;
    char* dataCopy;   /* miniz reads from this buffer lazily — must outlive the archive */
    size_t dataLen;
};

struct msZipWriterCtx {
    mz_zip_archive zip;
    int finalized;
};

/* ===== Handle conversion ===== */

static inline int64_t rCtxToHandle(struct msZipReaderCtx* c) { return (int64_t)(intptr_t)c; }
static inline struct msZipReaderCtx* rHandleToCtx(int64_t h) { return (struct msZipReaderCtx*)(intptr_t)h; }
static inline int64_t wCtxToHandle(struct msZipWriterCtx* c) { return (int64_t)(intptr_t)c; }
static inline struct msZipWriterCtx* wHandleToCtx(int64_t h) { return (struct msZipWriterCtx*)(intptr_t)h; }

/* ===== Reader ===== */

int64_t msZipReaderOpen(msString data) {
    if (data.len <= 0 || !data.p) return 0;

    struct msZipReaderCtx* c = (struct msZipReaderCtx*)calloc(1, sizeof(*c));
    if (!c) return 0;

    /* Copy the input buffer — miniz's reader holds the pointer for the
     * archive's entire lifetime and dereferences it lazily during extract
     * calls. The caller's msString could be released by DRC before the
     * reader context is closed, so we own our own copy.
     *
     * Peak memory cost: ~2× the input size during extraction. For the
     * typical ~1 MB package tarball this is fine; callers handling very
     * large archives can stream entry-by-entry to keep peaks down. */
    c->dataCopy = (char*)malloc((size_t)data.len);
    if (!c->dataCopy) { free(c); return 0; }
    memcpy(c->dataCopy, data.p->data, (size_t)data.len);
    c->dataLen = (size_t)data.len;

    if (!mz_zip_reader_init_mem(&c->zip, c->dataCopy, c->dataLen, 0)) {
        free(c->dataCopy);
        free(c);
        return 0;
    }

    return rCtxToHandle(c);
}

int32_t msZipReaderCount(int64_t handle) {
    struct msZipReaderCtx* c = rHandleToCtx(handle);
    if (!c) return -1;
    return (int32_t)mz_zip_reader_get_num_files(&c->zip);
}

msString msZipReaderEntryName(int64_t handle, int32_t index) {
    struct msZipReaderCtx* c = rHandleToCtx(handle);
    if (!c) return MS_EMPTY_STRING;

    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&c->zip, (mz_uint)index, &stat)) return MS_EMPTY_STRING;

    /* m_filename is a char[MZ_ZIP_MAX_ARCHIVE_FILENAME_SIZE] that miniz
     * guarantees to be zero-terminated, but we bound the scan defensively
     * in case of a malformed or corrupted archive. */
    size_t n = 0;
    while (n < MZ_ZIP_MAX_ARCHIVE_FILENAME_SIZE && stat.m_filename[n] != '\0') n++;
    return msStringNew(stat.m_filename, (int64_t)n);
}

int64_t msZipReaderEntrySize(int64_t handle, int32_t index) {
    struct msZipReaderCtx* c = rHandleToCtx(handle);
    if (!c) return -1;

    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&c->zip, (mz_uint)index, &stat)) return -1;

    return (int64_t)stat.m_uncomp_size;
}

int32_t msZipReaderEntryIsDir(int64_t handle, int32_t index) {
    struct msZipReaderCtx* c = rHandleToCtx(handle);
    if (!c) return -1;

    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&c->zip, (mz_uint)index, &stat)) return -1;

    return stat.m_is_directory ? 1 : 0;
}

msString msZipReaderExtract(int64_t handle, int32_t index) {
    struct msZipReaderCtx* c = rHandleToCtx(handle);
    if (!c) return MS_EMPTY_STRING;

    size_t sz = 0;
    void* buf = mz_zip_reader_extract_to_heap(&c->zip, (mz_uint)index, &sz, 0);
    if (!buf) return MS_EMPTY_STRING;

    msString out = msStringNew((const char*)buf, (int64_t)sz);
    mz_free(buf);   /* miniz allocator owns `buf` — release via mz_free */
    return out;
}

void msZipReaderClose(int64_t handle) {
    struct msZipReaderCtx* c = rHandleToCtx(handle);
    if (!c) return;
    mz_zip_reader_end(&c->zip);
    free(c->dataCopy);
    free(c);
}

/* ===== Writer ===== */

int64_t msZipWriterNew(void) {
    struct msZipWriterCtx* c = (struct msZipWriterCtx*)calloc(1, sizeof(*c));
    if (!c) return 0;
    if (!mz_zip_writer_init_heap(&c->zip, 0, 0)) {
        free(c);
        return 0;
    }
    return wCtxToHandle(c);
}

int32_t msZipWriterAdd(int64_t handle, msString name, msString data, int32_t level) {
    struct msZipWriterCtx* c = wHandleToCtx(handle);
    if (!c || c->finalized) return -1;

    /* Copy name to a null-terminated buffer on the stack (miniz wants char*).
     * The archive filename limit is MZ_ZIP_MAX_ARCHIVE_FILENAME_SIZE (512). */
    if (name.len <= 0 || !name.p) return -1;
    if (name.len >= MZ_ZIP_MAX_ARCHIVE_FILENAME_SIZE) return -1;
    char nameBuf[MZ_ZIP_MAX_ARCHIVE_FILENAME_SIZE];
    memcpy(nameBuf, name.p->data, (size_t)name.len);
    nameBuf[name.len] = '\0';

    if (level < 0) level = 6;
    if (level > 9) level = 9;

    const void* dataPtr = (data.len > 0 && data.p) ? data.p->data : NULL;
    size_t dataLen = (data.len > 0) ? (size_t)data.len : 0;

    if (!mz_zip_writer_add_mem(&c->zip, nameBuf, dataPtr, dataLen, (mz_uint)level)) {
        return -1;
    }
    return 0;
}

msString msZipWriterFinalize(int64_t handle) {
    struct msZipWriterCtx* c = wHandleToCtx(handle);
    if (!c || c->finalized) return MS_EMPTY_STRING;

    void* buf = NULL;
    size_t sz = 0;
    if (!mz_zip_writer_finalize_heap_archive(&c->zip, &buf, &sz)) {
        return MS_EMPTY_STRING;
    }
    c->finalized = 1;

    msString out = (buf && sz > 0) ? msStringNew((const char*)buf, (int64_t)sz) : MS_EMPTY_STRING;
    /* miniz allocator owns `buf` — release after copying. */
    if (buf) mz_free(buf);
    return out;
}

void msZipWriterClose(int64_t handle) {
    struct msZipWriterCtx* c = wHandleToCtx(handle);
    if (!c) return;
    mz_zip_writer_end(&c->zip);
    free(c);
}
