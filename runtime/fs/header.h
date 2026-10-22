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

/* List directory entries as "\n"-joined string.
 * Directories have trailing "/". "." and ".." excluded.
 * Returns MS_EMPTY_STRING on error (check msFsLastErrno). */
msString msFsReadDirEntries(msString path);

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_FS_H */
