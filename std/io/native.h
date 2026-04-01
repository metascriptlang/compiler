/**
 * MetaScript I/O Runtime (C Backend)
 *
 * Standard streams only: stdin reading, stdout/stderr writing.
 * File I/O lives in std/fs/native.h.
 * JSON parsing lives in runtime/core/json.h.
 *
 * Follows the standard reference's synchronous I/O pattern: thin C wrappers, binary mode,
 * platform macros for stdin/stdout/stderr on macOS.
 */

#ifndef MS_STD_IO_H
#define MS_STD_IO_H

#include <stdio.h>
#include <string.h>
#include "std/core/system/native.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/select.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ===== Stdin Init ===== */

/**
 * Disable stdio buffering on stdin so select() accurately reflects
 * available data. Without this, fgets/fread may pull data into stdio's
 * internal buffer, making select() return false even though data exists.
 * Call once at server startup.
 */
static inline void msStdinDisableBuffering(void) {
	setvbuf(stdin, NULL, _IONBF, 0);
}

/* ===== Stdin ===== */

/**
 * Read a line from stdin (up to \n or EOF).
 * Strips trailing \r\n or \n. Returns empty string on EOF.
 * Buffer: 4 KiB (sufficient for LSP Content-Length headers).
 */
static inline msString msReadLine(void) {
	char buf[4096];
	if (fgets(buf, sizeof(buf), stdin) == NULL) {
		return MS_EMPTY_STRING;
	}
	size_t len = strlen(buf);
	if (len > 0 && buf[len - 1] == '\n') buf[--len] = '\0';
	if (len > 0 && buf[len - 1] == '\r') buf[--len] = '\0';
	return msStringFromCStr(buf);
}

/**
 * Read exactly n bytes from stdin, retrying on short reads (pipes).
 * Returns what was read (fewer only on EOF/error).
 * Cap: 1 MiB per call.
 */
static inline msString msReadBytes(double n) {
	int64_t count = (int64_t)n;
	if (count <= 0) return MS_EMPTY_STRING;
	if (count > 1048576) count = 1048576;
	char* buf = (char*)malloc(count + 1);
	if (!buf) return MS_EMPTY_STRING;
	size_t total = 0;
	while (total < (size_t)count) {
		size_t nread = fread(buf + total, 1, count - total, stdin);
		if (nread == 0) break;
		total += nread;
	}
	buf[total] = '\0';
	msString result = msStringNew(buf, (int64_t)total);
	free(buf);
	return result;
}

/**
 * Non-blocking check: is data available on stdin?
 * Uses select() with zero timeout — probes without changing fd state.
 * Returns 1.0 if data available, 0.0 otherwise.
 */
static inline double msStdinHasData(void) {
#ifdef _WIN32
	HANDLE hStdin = GetStdHandle(STD_INPUT_HANDLE);
	DWORD result = WaitForSingleObject(hStdin, 0);
	return result == WAIT_OBJECT_0 ? 1.0 : 0.0;
#else
	fd_set fds;
	struct timeval tv = {0, 0};
	FD_ZERO(&fds);
	FD_SET(STDIN_FILENO, &fds);
	int r = select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv);
	return (r > 0 && FD_ISSET(STDIN_FILENO, &fds)) ? 1.0 : 0.0;
#endif
}

/* ===== Stdout / Stderr ===== */

/**
 * Write string to stdout, flushing immediately.
 * Flush required for LSP (client reads Content-Length framed messages).
 */
static inline void msWriteStdout(msString s) {
	if (s.len > 0) {
		fwrite(msStringToCString(s), 1, s.len, stdout);
		fflush(stdout);
	}
}

/**
 * Write string to stderr, flushing immediately.
 */
static inline void msWriteStderr(msString s) {
	if (s.len > 0) {
		fwrite(msStringToCString(s), 1, s.len, stderr);
		fflush(stderr);
	}
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_IO_H */
