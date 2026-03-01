/**
 * MetaScript I/O Runtime (C Backend)
 *
 * Provides stdin/stdout/stderr operations.
 */

#ifndef MS_STD_IO_H
#define MS_STD_IO_H

#include <stdio.h>
#include "system.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Read a line from stdin (up to newline or EOF).
 * Returns empty string on EOF.
 */
static inline msString msReadLine(void) {
	char buf[4096];
	if (fgets(buf, sizeof(buf), stdin) == NULL) {
		return MS_EMPTY_STRING;
	}
	/* Strip trailing newline if present */
	size_t len = strlen(buf);
	if (len > 0 && buf[len - 1] == '\n') {
		buf[len - 1] = '\0';
	}
	return msStringFromCStr(buf);
}

/**
 * Read n bytes from stdin. Returns what was read (may be less than n).
 */
static inline msString msReadBytes(double n) {
	int64_t count = (int64_t)n;
	if (count <= 0) return MS_EMPTY_STRING;
	if (count > 1048576) count = 1048576; /* 1 MiB cap */
	char* buf = (char*)malloc(count + 1);
	if (!buf) return MS_EMPTY_STRING;
	size_t nread = fread(buf, 1, count, stdin);
	buf[nread] = '\0';
	msString result = msStringNew(buf, (int64_t)nread);
	free(buf);
	return result;
}

/**
 * Write string to stdout, flushing immediately.
 */
static inline void msWriteStdout(msString s) {
	if (s.len > 0) {
		fwrite(msCStr(s), 1, s.len, stdout);
		fflush(stdout);
	}
}

/**
 * Write string to stderr, flushing immediately.
 */
static inline void msWriteStderr(msString s) {
	if (s.len > 0) {
		fwrite(msCStr(s), 1, s.len, stderr);
		fflush(stderr);
	}
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_IO_H */
