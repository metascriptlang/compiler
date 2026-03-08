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
	/* Strip trailing \r\n or \n (LSP uses \r\n framing) */
	size_t len = strlen(buf);
	if (len > 0 && buf[len - 1] == '\n') {
		buf[--len] = '\0';
	}
	if (len > 0 && buf[len - 1] == '\r') {
		buf[--len] = '\0';
	}
	return msStringFromCStr(buf);
}

/**
 * Read exactly n bytes from stdin, retrying on short reads (pipes).
 * Returns what was read (fewer only on EOF/error).
 */
static inline msString msReadBytes(double n) {
	int64_t count = (int64_t)n;
	if (count <= 0) return MS_EMPTY_STRING;
	if (count > 1048576) count = 1048576; /* 1 MiB cap */
	char* buf = (char*)malloc(count + 1);
	if (!buf) return MS_EMPTY_STRING;
	size_t total = 0;
	while (total < (size_t)count) {
		size_t nread = fread(buf + total, 1, count - total, stdin);
		if (nread == 0) break; /* EOF or error */
		total += nread;
	}
	buf[total] = '\0';
	msString result = msStringNew(buf, (int64_t)total);
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
