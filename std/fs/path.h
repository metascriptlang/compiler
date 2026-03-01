/**
 * MetaScript Path Utilities (C Backend)
 *
 * POSIX path manipulation via direct character scanning.
 */

#ifndef MS_STD_FS_PATH_H
#define MS_STD_FS_PATH_H

#include "system.h"
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * dirname — return directory portion of path.
 * "/a/b/c" → "/a/b", "/a" → "/", "file" → "."
 */
static inline msString msFsDirname(msString p) {
	if (p.len == 0) return msStringFromCStr(".");
	const char* s = msCStr(p);
	int64_t i = p.len - 1;
	while (i >= 0) {
		if (s[i] == '/') {
			if (i == 0) return msStringFromCStr("/");
			return msStringNew(s, i);
		}
		i--;
	}
	return msStringFromCStr(".");
}

/**
 * join — combine two path segments.
 * Absolute b wins. Trailing slash on a avoids double slash.
 */
static inline msString msFsJoin(msString a, msString b) {
	if (b.len > 0 && msCStr(b)[0] == '/') return b;
	if (a.len > 0 && msCStr(a)[a.len - 1] == '/') return msStringConcat(a, b);
	msString sep = msStringFromCStr("/");
	msString tmp = msStringConcat(a, sep);
	msString result = msStringConcat(tmp, b);
	msStringDestroy(sep);
	msStringDestroy(tmp);
	return result;
}

/**
 * resolve — resolve relative path against cwd.
 * Absolute paths pass through unchanged.
 */
static inline msString msFsResolve(msString p, msString cwdStr) {
	if (p.len > 0 && msCStr(p)[0] == '/') return p;
	return msFsJoin(cwdStr, p);
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_FS_PATH_H */
