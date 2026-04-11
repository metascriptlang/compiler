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
#include "runtime/core/system.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ===== Last errno capture ===== */
/* Captured after each fallible operation so .cms wrappers can build IoError. */

static int _msFsLastErrno = 0;

static inline int32_t msFsLastErrno(void) {
	return (int32_t)_msFsLastErrno;
}

/* ===== Read ===== */

/**
 * Read entire file as string. Returns empty string on failure.
 * Binary mode — no line-ending translation.
 * Cap: 64 MiB (guard against accidental huge reads).
 */
static inline msString msFsReadFile(msString path) {
	_msFsLastErrno = 0;
	FILE* f = fopen(msStringToCString(path), "rb");
	if (!f) { _msFsLastErrno = errno; return MS_EMPTY_STRING; }
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
	_msFsLastErrno = 0;
	FILE* f = fopen(msStringToCString(path), msStringToCString(mode));
	if (!f) { _msFsLastErrno = errno; return 0.0; }
	size_t written = fwrite(msStringToCString(content), 1, content.len, f);
	fclose(f);
	return (written == (size_t)content.len) ? 1.0 : 0.0;
}

/* ===== Permissions ===== */

/**
 * chmod(path, mode) — POSIX file permission bits.
 * Returns 1.0 on success, 0.0 on failure.
 * Windows is a no-op (ACL model is different; not our first-class target).
 * Used by `saveToken()` in login.ms to tighten ~/.metascript/credentials to 0600.
 */
static inline double msFsChmod(msString path, int32_t mode) {
	_msFsLastErrno = 0;
#ifdef _WIN32
	(void)path; (void)mode;
	return 1.0;
#else
	if (chmod(msStringToCString(path), (mode_t)mode) != 0) {
		_msFsLastErrno = errno;
		return 0.0;
	}
	return 1.0;
#endif
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
	_msFsLastErrno = 0;
	int r = mkdir(msStringToCString(path), 0755);
	if (r == 0 || errno == EEXIST) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

/**
 * Remove empty directory. Returns 1.0 on success, 0.0 on failure.
 */
static inline double msFsRmdir(msString path) {
	_msFsLastErrno = 0;
	if (rmdir(msStringToCString(path)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

/**
 * List directory entries. Returns a "\n"-joined string where directories
 * have a trailing "/" marker. "." and ".." are always excluded. Returns an
 * empty string on error (check msFsLastErrno to distinguish error from
 * empty directory — a truly empty dir still returns ""; callers use
 * msFsLastErrno == 0 to confirm success).
 *
 * Format: "name1\nname2/\nname3\n" (trailing newline after each entry).
 *
 * Falls back to stat() when d_type is DT_UNKNOWN (some filesystems don't
 * populate d_type — e.g. older ReiserFS, some FUSE mounts).
 */
static inline msString msFsReadDirEntries(msString path) {
	_msFsLastErrno = 0;
	const char* cpath = msStringToCString(path);
	DIR* d = opendir(cpath);
	if (!d) {
		_msFsLastErrno = errno;
		return MS_EMPTY_STRING;
	}
	size_t cap = 4096;
	size_t len = 0;
	char* buf = (char*)malloc(cap);
	if (!buf) {
		closedir(d);
		_msFsLastErrno = ENOMEM;
		return MS_EMPTY_STRING;
	}
	size_t pathLen = strlen(cpath);
	struct dirent* e;
	while ((e = readdir(d)) != NULL) {
		/* Skip "." and ".." */
		if (e->d_name[0] == '.' &&
		    (e->d_name[1] == '\0' ||
		     (e->d_name[1] == '.' && e->d_name[2] == '\0'))) {
			continue;
		}
		size_t nlen = strlen(e->d_name);
		int isDir = 0;
#ifdef DT_DIR
		if (e->d_type == DT_DIR) {
			isDir = 1;
		} else if (e->d_type == DT_UNKNOWN || e->d_type == DT_LNK) {
#endif
			/* Fall back to stat: build "path/name" and check S_ISDIR */
			char* tmp = (char*)malloc(pathLen + 1 + nlen + 1);
			if (tmp) {
				memcpy(tmp, cpath, pathLen);
				tmp[pathLen] = '/';
				memcpy(tmp + pathLen + 1, e->d_name, nlen);
				tmp[pathLen + 1 + nlen] = '\0';
				struct stat st;
				if (stat(tmp, &st) == 0 && S_ISDIR(st.st_mode)) {
					isDir = 1;
				}
				free(tmp);
			}
#ifdef DT_DIR
		}
#endif
		/* Resize buffer if needed: name + optional "/" + "\n" */
		while (len + nlen + 2 >= cap) {
			size_t newCap = cap * 2;
			char* nb = (char*)realloc(buf, newCap);
			if (!nb) {
				free(buf);
				closedir(d);
				_msFsLastErrno = ENOMEM;
				return MS_EMPTY_STRING;
			}
			buf = nb;
			cap = newCap;
		}
		memcpy(buf + len, e->d_name, nlen);
		len += nlen;
		if (isDir) buf[len++] = '/';
		buf[len++] = '\n';
	}
	closedir(d);
	msString result = msStringNew(buf, (int64_t)len);
	free(buf);
	return result;
}

/* ===== Remove / Rename ===== */

/**
 * Remove a file. Returns 1.0 on success, 0.0 on failure.
 */
static inline double msFsRemove(msString path) {
	_msFsLastErrno = 0;
	if (unlink(msStringToCString(path)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

/**
 * Rename/move a file or directory. Returns 1.0 on success, 0.0 on failure.
 */
static inline double msFsRename(msString oldPath, msString newPath) {
	_msFsLastErrno = 0;
	if (rename(msStringToCString(oldPath), msStringToCString(newPath)) == 0) return 1.0;
	_msFsLastErrno = errno;
	return 0.0;
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_FS_H */
