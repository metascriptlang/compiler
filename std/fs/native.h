/**
 * MetaScript File System Runtime (C Backend) — Minimal POSIX Layer
 *
 * Only irreducible C: syscall wrappers that MetaScript cannot express.
 * Higher-level logic (isFile, isDir, exists, copyFile, etc.) lives in
 * pure MetaScript (.cms / .ms) using bitwise ops on stat mode bits.
 *
 * Design:
 *   - All paths are msString (UTF-8, not null-terminated internally)
 *   - msStringToCString() used at boundaries for POSIX calls
 *   - Errors return empty string / 0.0 / -1.0 (no exceptions at C level)
 *   - Binary mode ("rb"/"wb") always — no line-ending translation
 */

#ifndef MS_STD_FS_H
#define MS_STD_FS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include "std/core/system/native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ===== Read ===== */

/**
 * Read entire file as string. Returns empty string on failure.
 * Binary mode — no line-ending translation.
 * Cap: 64 MiB (guard against accidental huge reads).
 */
static inline msString msFsReadFile(msString path) {
	FILE* f = fopen(msStringToCString(path), "rb");
	if (!f) return MS_EMPTY_STRING;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz <= 0 || sz > 67108864) { fclose(f); return MS_EMPTY_STRING; }
	char* buf = (char*)malloc(sz + 1);
	if (!buf) { fclose(f); return MS_EMPTY_STRING; }
	size_t nread = fread(buf, 1, sz, f);
	fclose(f);
	buf[nread] = '\0';
	msString result = msStringNew(buf, (int64_t)nread);
	free(buf);
	return result;
}

/* ===== Write ===== */

/**
 * Write string to file with given mode ("wb" = truncate, "ab" = append).
 * Returns 1.0 on success, 0.0 on failure.
 */
static inline double msFsWriteFileMode(msString path, msString content, msString mode) {
	FILE* f = fopen(msStringToCString(path), msStringToCString(mode));
	if (!f) return 0.0;
	size_t written = fwrite(msStringToCString(content), 1, content.len, f);
	fclose(f);
	return (written == (size_t)content.len) ? 1.0 : 0.0;
}

/* ===== Stat ===== */

static inline double msFsExists(msString path) {
	struct stat st;
	return (stat(msStringToCString(path), &st) == 0) ? 1.0 : 0.0;
}

static inline double msFsIsFile(msString path) {
	struct stat st;
	if (stat(msStringToCString(path), &st) != 0) return 0.0;
	return S_ISREG(st.st_mode) ? 1.0 : 0.0;
}

static inline double msFsIsDir(msString path) {
	struct stat st;
	if (stat(msStringToCString(path), &st) != 0) return 0.0;
	return S_ISDIR(st.st_mode) ? 1.0 : 0.0;
}

/**
 * File size in bytes. Returns -1.0 on error.
 */
static inline double msFsFileSize(msString path) {
	struct stat st;
	if (stat(msStringToCString(path), &st) != 0) return -1.0;
	return (double)st.st_size;
}

/* ===== Directory ===== */

/**
 * Create directory (0755). Returns 1.0 on success or EEXIST, 0.0 on failure.
 */
static inline double msFsMkdir(msString path) {
	int r = mkdir(msStringToCString(path), 0755);
	if (r == 0 || errno == EEXIST) return 1.0;
	return 0.0;
}

/**
 * Remove empty directory. Returns 1.0 on success, 0.0 on failure.
 */
static inline double msFsRmdir(msString path) {
	return (rmdir(msStringToCString(path)) == 0) ? 1.0 : 0.0;
}

/* ===== Remove / Rename ===== */

/**
 * Remove a file. Returns 1.0 on success, 0.0 on failure.
 */
static inline double msFsRemove(msString path) {
	return (unlink(msStringToCString(path)) == 0) ? 1.0 : 0.0;
}

/**
 * Rename/move a file or directory. Returns 1.0 on success, 0.0 on failure.
 */
static inline double msFsRename(msString oldPath, msString newPath) {
	return (rename(msStringToCString(oldPath), msStringToCString(newPath)) == 0) ? 1.0 : 0.0;
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_FS_H */
