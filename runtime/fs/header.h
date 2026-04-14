/**
 * MetaScript File System Runtime — Platform-Agnostic Interface
 *
 * Only irreducible C: syscall wrappers that MetaScript cannot express.
 * Higher-level logic (isFile, isDir, exists, copyFile, etc.) lives in
 * pure MetaScript (.cms / .ms) using bitwise ops on stat mode bits.
 *
 * Design:
 *   - All paths are msString (UTF-8, not null-terminated internally)
 *   - msStringToCString() used at boundaries for syscalls
 *   - Errors return empty string / 0.0 / -1.0 (no exceptions at C level)
 *   - Binary mode ("rb"/"wb") always — no line-ending translation
 *
 * Implementations: runtime/fs/posix.c (POSIX), runtime/fs/windows.c (Win32).
 * Both are compiled; platform guards inside each .c emit only one.
 */

#ifndef MS_STD_FS_H
#define MS_STD_FS_H

#include <stdint.h>
#include "runtime/core/system.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Last errno captured after each fallible operation.
 * .cms wrappers call this to build IoError. */
int32_t msFsLastErrno(void);

/* Read entire file as string. Binary mode, 64 MiB cap.
 * Returns MS_EMPTY_STRING on failure. */
msString msFsReadFile(msString path);

/* Write string to file. mode = "wb" (truncate) or "ab" (append).
 * Returns 1.0 on success, 0.0 on failure. */
double msFsWriteFileMode(msString path, msString content, msString mode);

/* chmod(path, mode). No-op on Windows. Returns 1.0/0.0. */
double msFsChmod(msString path, int32_t mode);

/* Stat predicates. Return 1.0 (true) or 0.0 (false). */
double msFsExists(msString path);
double msFsIsFile(msString path);
double msFsIsDir(msString path);

/* File size in bytes. Returns -1.0 on error. */
double msFsFileSize(msString path);

/* Create directory (0755 on POSIX). Returns 1.0 on success or EEXIST, 0.0 on failure. */
double msFsMkdir(msString path);

/* Remove empty directory. Returns 1.0/0.0. */
double msFsRmdir(msString path);

/* List directory entries as "\n"-joined string.
 * Directories have trailing "/". "." and ".." excluded.
 * Returns MS_EMPTY_STRING on error (check msFsLastErrno). */
msString msFsReadDirEntries(msString path);

/* Remove a file. Returns 1.0/0.0. */
double msFsRemove(msString path);

/* Rename/move a file or directory. Returns 1.0/0.0. */
double msFsRename(msString oldPath, msString newPath);

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_FS_H */
