/**
 * MetaScript Process Runtime (C Backend)
 *
 * Provides access to command-line arguments, process control,
 * file I/O, environment variables, and monotonic clock.
 * Uses platform-specific APIs to access argv even from main(void).
 */

#ifndef MS_STD_PROCESS_H
#define MS_STD_PROCESS_H

#include <stdlib.h>
#include <time.h>
#include "runtime/core/system.h"

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#include <shellapi.h>
#else
#include <unistd.h>
#include <sys/wait.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// Platform-specific argv access
// =============================================================================

#if defined(__APPLE__)
#include <crt_externs.h>
#endif

/**
 * Get number of command-line arguments.
 */
#ifdef _WIN32
static wchar_t** _msWargv = NULL;
static int _msWargc = 0;
static inline void _msInitWargv(void) {
	if (!_msWargv) _msWargv = CommandLineToArgvW(GetCommandLineW(), &_msWargc);
}
#endif

static inline double msProcessArgc(void) {
#if defined(_WIN32)
	_msInitWargv();
	return (double)_msWargc;
#elif defined(__APPLE__)
	return (double)(*_NSGetArgc());
#elif defined(__linux__)
	static int cached_argc = -1;
	if (cached_argc >= 0) return (double)cached_argc;
	FILE* f = fopen("/proc/self/cmdline", "r");
	if (!f) return 0.0;
	cached_argc = 0;
	int ch;
	while ((ch = fgetc(f)) != EOF) {
		if (ch == 0) cached_argc++;
	}
	fclose(f);
	return (double)cached_argc;
#else
	return 0.0;
#endif
}

/**
 * Get command-line argument at index as msString.
 */
static inline msString msProcessArgvAt(double index) {
	int idx = (int)index;
#if defined(_WIN32)
	_msInitWargv();
	if (idx < 0 || idx >= _msWargc) return MS_EMPTY_STRING;
	/* Convert wide string to UTF-8 */
	int needed = WideCharToMultiByte(CP_UTF8, 0, _msWargv[idx], -1, NULL, 0, NULL, NULL);
	if (needed <= 0) return MS_EMPTY_STRING;
	char* buf = (char*)malloc(needed);
	WideCharToMultiByte(CP_UTF8, 0, _msWargv[idx], -1, buf, needed, NULL, NULL);
	msString result = msStringFromCStr(buf);
	free(buf);
	return result;
#elif defined(__APPLE__)
	char*** argv_ptr = _NSGetArgv();
	int argc = *_NSGetArgc();
	if (idx < 0 || idx >= argc) return MS_EMPTY_STRING;
	return msStringFromCStr((*argv_ptr)[idx]);
#elif defined(__linux__)
	FILE* f = fopen("/proc/self/cmdline", "r");
	if (!f) return MS_EMPTY_STRING;
	int current = 0;
	char buf[4096];
	int pos = 0;
	int ch;
	while ((ch = fgetc(f)) != EOF) {
		if (ch == 0) {
			if (current == idx) {
				buf[pos] = '\0';
				fclose(f);
				return msStringFromCStr(buf);
			}
			current++;
			pos = 0;
		} else {
			if (pos < 4095) buf[pos++] = (char)ch;
		}
	}
	fclose(f);
	return MS_EMPTY_STRING;
#else
	return MS_EMPTY_STRING;
#endif
}

/**
 * Exit the process with a status code.
 */
static inline void msProcessExit(double code) {
	exit((int)code);
}

/**
 * Get current working directory.
 */
static inline msString msProcessCwd(void) {
	char buf[4096];
#ifdef _WIN32
	if (_getcwd(buf, sizeof(buf)) != NULL) {
#else
	if (getcwd(buf, sizeof(buf)) != NULL) {
#endif
		return msStringFromCStr(buf);
	}
	return MS_EMPTY_STRING;
}

// =============================================================================
// File I/O
// =============================================================================

/**
 * Read entire file as string. Returns empty string on failure.
 */
static inline msString msProcessReadFile(msString path) {
	const char* cpath = msStringToCString(path);
	FILE* f = fopen(cpath, "rb");
	if (!f) return MS_EMPTY_STRING;
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (size <= 0) { fclose(f); return MS_EMPTY_STRING; }
	char* buf = (char*)malloc(size + 1);
	if (!buf) { fclose(f); return MS_EMPTY_STRING; }
	size_t nread = fread(buf, 1, size, f);
	fclose(f);
	buf[nread] = '\0';
	msString result = msStringFromCStr(buf);
	free(buf);
	return result;
}

/**
 * Check if file exists (can be opened for reading).
 */
static inline double msProcessFileExists(msString path) {
	const char* cpath = msStringToCString(path);
	FILE* f = fopen(cpath, "r");
	if (!f) return 0.0;
	fclose(f);
	return 1.0;
}

/**
 * Execute a shell command. Returns the exit code.
 */
static inline double msProcessExec(msString command) {
	const char* cmd = msStringToCString(command);
	int status = system(cmd);
#if defined(__APPLE__) || defined(__linux__)
	if (WIFEXITED(status)) return (double)WEXITSTATUS(status);
	return -1.0;
#else
	return (double)status;
#endif
}

/**
 * Write string to file. Returns 1.0 on success, 0.0 on failure.
 */
static inline double msProcessWriteFile(msString path, msString content) {
	const char* cpath = msStringToCString(path);
	FILE* f = fopen(cpath, "wb");
	if (!f) return 0.0;
	const char* data = msStringToCString(content);
	size_t len = content.len;
	size_t written = fwrite(data, 1, len, f);
	fclose(f);
	return (written == len) ? 1.0 : 0.0;
}

// =============================================================================
// Environment variables
// =============================================================================

/**
 * Get environment variable value. Returns empty string if not set.
 */
static inline msString msProcessGetEnv(msString name) {
	const char* cname = msStringToCString(name);
	const char* val = getenv(cname);
	if (!val) return MS_EMPTY_STRING;
	return msStringFromCStr(val);
}

// =============================================================================
// Monotonic clock
// =============================================================================

/**
 * Get monotonic clock time in milliseconds (fractional).
 */
static inline double msProcessClockMs(void) {
#if defined(_WIN32)
	LARGE_INTEGER freq, cnt;
	QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&cnt);
	return (double)(cnt.QuadPart * 1000) / (double)freq.QuadPart;
#elif defined(__APPLE__) || defined(__linux__)
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
#else
	return 0.0;
#endif
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_PROCESS_H */
