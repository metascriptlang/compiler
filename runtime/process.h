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
#include "runtime/core/system.h"

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#include <shellapi.h>
#else
#include <sys/types.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <string.h>
#include <spawn.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#define MS_SPAWN_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define MS_SPAWN_ENVIRON environ
#endif
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

/* Windows console init — runs before main() via GCC/LLVM constructor
 * attribute. Matches what modern CLI tools (cargo, gh, ripgrep) do:
 *
 *   1. UTF-8 output code page — so `→`, box-drawing, etc. render instead
 *      of showing CP437 mojibake like `ΓåÆ`.
 *   2. Virtual-terminal processing on stdout/stderr — so ANSI escape
 *      sequences from child processes (zig cc's progress reporter, color
 *      codes) are interpreted instead of dumped as literal `^[[?2026h` junk.
 *      Enables the escape-sequence overwrite that POSIX terminals do by
 *      default, keeping build output clean.
 */
__attribute__((constructor))
static void _msInitConsoleUtf8(void) {
	SetConsoleOutputCP(CP_UTF8);
	SetConsoleCP(CP_UTF8);
	HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
	HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
	DWORD mode;
	if (hOut != INVALID_HANDLE_VALUE && GetConsoleMode(hOut, &mode)) {
		SetConsoleMode(hOut, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
	}
	if (hErr != INVALID_HANDLE_VALUE && GetConsoleMode(hErr, &mode)) {
		SetConsoleMode(hErr, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
	}
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
	msTestErrorFlag();
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

/* Note: legacy `msProcessExec` (exit-code-only `system()` wrapper) removed.
 * std/process.exec() now uses msProcessSpawnSync — rich result with captured
 * stdout, stderr, exit code, and signal. Wrap via Result<string, ProcessError>. */

/**
 * Execute a binary directly (no shell). Returns its exit code, or -1 on spawn failure.
 *
 * - POSIX: posix_spawnp; inherits stdio by default.
 * - Windows: CreateProcessA with inherited stdio; forward-slash paths accepted
 *   (CreateProcess normalizes internally). Bypasses cmd.exe entirely — no
 *   "argument-switch misparse" for paths like `out/debug/hello.exe`.
 *
 * Args are passed as argv (POSIX) or assembled into lpCommandLine per
 * Microsoft CRT quoting rules (Windows). Matches Node.js `child_process.execFile`
 * semantics: path is taken literally, no PATH lookup — resolve via findOnPath first if needed.
 */
#ifdef _WIN32
/* Windows argv quoting per MS CRT rules:
 *   https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments
 * - If arg has no spaces/tabs/quotes, append verbatim.
 * - Otherwise wrap in "...". Each `"` becomes `\"`; runs of `\` before a `"`
 *   (or the closing `"`) are doubled.
 */
static inline void _msAppendWinArg(char** buf, size_t* len, size_t* cap, const char* arg) {
	/* Ensure room for worst case: 2 quotes + doubled escapes + terminator. */
	size_t needExtra = strlen(arg) * 2 + 4;
	if (*len + needExtra > *cap) {
		*cap = (*len + needExtra) * 2;
		*buf = (char*)realloc(*buf, *cap);
	}
	char* out = *buf + *len;
	int hasSpecial = 0;
	for (const char* s = arg; *s; s++) {
		if (*s == ' ' || *s == '\t' || *s == '"') { hasSpecial = 1; break; }
	}
	if (arg[0] == '\0') { hasSpecial = 1; }  /* empty arg needs "" */
	if (!hasSpecial) {
		size_t l = strlen(arg);
		memcpy(out, arg, l);
		*len += l;
		return;
	}
	*out++ = '"';
	for (const char* s = arg; *s; s++) {
		if (*s == '\\') {
			/* Count consecutive backslashes. */
			int bsCount = 0;
			while (*s == '\\') { bsCount++; s++; }
			if (*s == '\0') {
				/* Trailing backslashes before closing quote: double them. */
				for (int i = 0; i < bsCount * 2; i++) *out++ = '\\';
				break;
			} else if (*s == '"') {
				/* Backslashes before an embedded quote: double + escape quote. */
				for (int i = 0; i < bsCount * 2 + 1; i++) *out++ = '\\';
				*out++ = '"';
			} else {
				/* Backslashes not followed by quote: pass through. */
				for (int i = 0; i < bsCount; i++) *out++ = '\\';
				*out++ = *s;
			}
		} else if (*s == '"') {
			*out++ = '\\';
			*out++ = '"';
		} else {
			*out++ = *s;
		}
	}
	*out++ = '"';
	*len = out - *buf;
}

/* Serializes pipe creation + CreateProcess + closing the parent's write ends.
 *
 * CreateProcess with bInheritHandles=TRUE hands the child EVERY handle that is
 * inheritable in this process at that moment — not just the three named in
 * STARTUPINFO. The pipe write ends must be inheritable for the child to write
 * through them, so while one thread sits between its CreatePipe and its
 * CloseHandle(write end), any other thread that spawns leaks that first
 * thread's write end into an unrelated child. That child holds the pipe open,
 * so the first thread's ReadFile never sees EOF and blocks until the unrelated
 * child happens to exit — across a wide pool, effectively forever.
 *
 * @compile dispatch spawns across the whole runtime thread pool, so a
 * many-core box hits this readily: it is why a `--os=solana` build stalled with
 * a clang child sitting at 0.00 s CPU.
 *
 * The lock-free alternative is STARTUPINFOEX + PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
 * which confines inheritance to an explicit list. That is the structurally
 * correct fix and worth taking if spawn ever becomes hot, but it costs several
 * more failure paths (every std handle must itself be valid and inheritable).
 * Spawn is ~1-3 ms against ~500 ms compiles, so serializing it does not show up
 * in a build; only the spawn is serialized, the compiles still run in parallel. */
static SRWLOCK _msSpawnCreateLock = SRWLOCK_INIT;

static inline double msProcessExecFile(msString path, msStringArray* args) {
	const char* pathStr = msStringToCString(path);

	/* Assemble command line: "path" arg1 arg2 ... */
	size_t cap = 256;
	size_t len = 0;
	char* cmdLine = (char*)malloc(cap);
	if (!cmdLine) return -1.0;
	_msAppendWinArg(&cmdLine, &len, &cap, pathStr);
	if (args != NULL && args->p != NULL) {
		for (int64_t i = 0; i < args->len; i++) {
			if (len + 2 > cap) { cap *= 2; cmdLine = (char*)realloc(cmdLine, cap); }
			cmdLine[len++] = ' ';
			const char* a = msStringToCString(args->p->data[i]);
			_msAppendWinArg(&cmdLine, &len, &cap, a);
		}
	}
	cmdLine[len] = '\0';

	STARTUPINFOA si;
	PROCESS_INFORMATION pi;
	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
	si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
	si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
	ZeroMemory(&pi, sizeof(pi));

	/* This spawn creates no pipes of its own, but bInheritHandles=TRUE still
	 * captures every inheritable handle in the process — including the pipe
	 * write ends a concurrent msProcessSpawnSync is holding open. Taking the
	 * same lock keeps that window closed; see _msSpawnCreateLock. */
	AcquireSRWLockExclusive(&_msSpawnCreateLock);
	BOOL ok = CreateProcessA(
		pathStr,     /* lpApplicationName - accepts forward slashes */
		cmdLine,     /* lpCommandLine (mutable) */
		NULL, NULL,  /* process/thread security attrs */
		TRUE,        /* bInheritHandles - for stdio inheritance */
		0,           /* creation flags */
		NULL,        /* inherit parent environment */
		NULL,        /* inherit parent cwd */
		&si, &pi);
	ReleaseSRWLockExclusive(&_msSpawnCreateLock);
	free(cmdLine);
	if (!ok) return -1.0;

	WaitForSingleObject(pi.hProcess, INFINITE);
	DWORD exitCode = 0;
	GetExitCodeProcess(pi.hProcess, &exitCode);
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);
	return (double)exitCode;
}
#else
static inline double msProcessExecFile(msString path, msStringArray* args) {
	const char* pathStr = msStringToCString(path);
	int64_t argc = (args != NULL) ? args->len : 0;
	char** argv = (char**)malloc(sizeof(char*) * (argc + 2));
	if (!argv) return -1.0;
	argv[0] = (char*)pathStr;
	/* msStringToCString may reuse a shared buffer — materialize each arg now. */
	for (int64_t i = 0; i < argc; i++) {
		const char* src = msStringToCString(args->p->data[i]);
		size_t slen = strlen(src);
		char* copy = (char*)malloc(slen + 1);
		if (!copy) {
			for (int64_t j = 1; j <= i; j++) free(argv[j]);
			free(argv);
			return -1.0;
		}
		memcpy(copy, src, slen + 1);
		argv[i + 1] = copy;
	}
	argv[argc + 1] = NULL;

	/* posix_spawnp, not fork(): fork from a large parent copies its page tables
	 * (sys-time heavy) and concurrent forks serialize on the parent's vm map
	 * lock, capping the parallel compile pool near 2 effective cores. */
	pid_t pid = 0;
	int spawnErr = posix_spawnp(&pid, pathStr, NULL, NULL, argv, MS_SPAWN_ENVIRON);
	for (int64_t j = 1; j <= argc; j++) free(argv[j]);
	free(argv);
	if (spawnErr != 0) return -1.0;
	int status = 0;
	if (waitpid(pid, &status, 0) < 0) return -1.0;
	if (WIFEXITED(status)) return (double)WEXITSTATUS(status);
	return -1.0;
}
#endif

// =============================================================================
// Synchronous subprocess (capture stdout + stderr + exit status)
// =============================================================================
//
// Implementation pattern: errno-style globals populated after each call, mirrors
// msFsLastErrno in runtime/fs/posix.c. MS wrapper reads stdout return value
// then queries getters for additional metadata before building Result/Error.
//
// POSIX: pipe() × 2 + posix_spawn("/bin/sh", "-c", cmd) with dup2 file
//        actions + read loops + waitpid(). Stderr captured separately.
// Windows: CreatePipe() × 2 + CreateProcess() + ReadFile loops +
//          WaitForSingleObject + GetExitCodeProcess.
//
// Output cap: 16 MB per stream. Longer outputs are truncated (matches stdout
// capture semantics in popen-based shells like Bun.$).
//
// Known limitation (v1): sequential read of stdout-first-then-stderr can
// deadlock if child writes >64KB to stderr while we're blocked on stdout
// read. For build-introspection tools (pkg-config, llvm-config, brew --prefix)
// outputs are tiny so this is not hit in practice. Upgrade to select()/poll()
// when a deadlock case appears.

/* Thread-local: exec() runs concurrently on pool workers (parallel @compile /
 * module compile); shared globals would cross-attribute exit codes between jobs. */
static _Thread_local int32_t _msProcSpawnExitCode = 0;
static _Thread_local int32_t _msProcSpawnSignal = 0;
static _Thread_local msString _msProcSpawnStderr = MS_EMPTY_STRING;
static _Thread_local int32_t _msProcSpawnOk = 0;  /* 1 if spawn succeeded, 0 otherwise */
static _Thread_local int32_t _msProcSpawnPipeOk = 1;  /* 0 if a pipe read/setup failed mid-flight */

static inline int32_t msProcSpawnGetExitCode(void) { return _msProcSpawnExitCode; }
static inline int32_t msProcSpawnGetSignal(void) { return _msProcSpawnSignal; }
static inline msString msProcSpawnGetStderr(void) { return _msProcSpawnStderr; }
static inline int32_t msProcSpawnGetOk(void) { return _msProcSpawnOk; }
static inline int32_t msProcSpawnGetPipeOk(void) { return _msProcSpawnPipeOk; }

#define MS_SPAWN_MAX_OUTPUT (16 * 1024 * 1024)

#ifndef _WIN32
/* Drain a fd into a heap buffer; returns malloc'd buffer + length via out params.
 * 1 on success, 0 on read error. Caller frees *outBuf. */
static inline int _msSpawnDrainFd(int fd, char** outBuf, size_t* outLen) {
	size_t cap = 4096;
	size_t len = 0;
	char* buf = (char*)malloc(cap);
	if (!buf) { *outBuf = NULL; *outLen = 0; return 0; }
	char chunk[4096];
	ssize_t n;
	while ((n = read(fd, chunk, sizeof(chunk))) > 0) {
		size_t got = (size_t)n;
		if (len + got > MS_SPAWN_MAX_OUTPUT) {
			got = MS_SPAWN_MAX_OUTPUT - len;
			if (got == 0) break;
		}
		while (len + got + 1 > cap) {
			cap *= 2;
			char* nb = (char*)realloc(buf, cap);
			if (!nb) { free(buf); *outBuf = NULL; *outLen = 0; return 0; }
			buf = nb;
		}
		memcpy(buf + len, chunk, got);
		len += got;
		if (len >= MS_SPAWN_MAX_OUTPUT) break;
	}
	if (n < 0 && errno != 0) { free(buf); *outBuf = NULL; *outLen = 0; return 0; }
	buf[len] = '\0';
	*outBuf = buf;
	*outLen = len;
	return 1;
}
#endif

#ifdef _WIN32
/* Move whatever is currently buffered in `h` into a growable buffer without
 * blocking. Returns FALSE once the pipe is at EOF (every write end closed) or
 * on allocation failure; *didRead reports whether bytes moved so the caller can
 * skip its backoff while either pipe is still producing.
 *
 * Past MS_SPAWN_MAX_OUTPUT the data is read and discarded rather than left in
 * the pipe: stopping the reads would refill the buffer and block the child in
 * WriteFile, which is the very deadlock this pump exists to avoid. */
static inline BOOL msSpawnPumpPipe(HANDLE h, char** buf, size_t* cap, size_t* len, BOOL* didRead) {
	DWORD avail = 0;
	if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) return FALSE;  /* broken pipe == EOF */
	if (avail == 0) return TRUE;
	if (*buf == NULL) return FALSE;

	char chunk[4096];
	DWORD want = avail > (DWORD)sizeof(chunk) ? (DWORD)sizeof(chunk) : avail;
	DWORD nRead = 0;
	if (!ReadFile(h, chunk, want, &nRead, NULL) || nRead == 0) return FALSE;
	*didRead = TRUE;

	size_t got = (size_t)nRead;
	if (*len >= MS_SPAWN_MAX_OUTPUT) return TRUE;               /* capped: drained and dropped */
	if (*len + got > MS_SPAWN_MAX_OUTPUT) got = MS_SPAWN_MAX_OUTPUT - *len;
	while (*len + got + 1 > *cap) {
		size_t newCap = *cap * 2;
		char* grown = (char*)realloc(*buf, newCap);
		if (!grown) { free(*buf); *buf = NULL; return FALSE; }  /* realloc keeps the old block on failure */
		*buf = grown;
		*cap = newCap;
	}
	memcpy(*buf + *len, chunk, got);
	*len += got;
	return TRUE;
}
#endif  /* _WIN32 */

static inline msString msProcessSpawnSync(msString command) {
	/* Reset side-channel state for this invocation. */
	_msProcSpawnExitCode = 0;
	_msProcSpawnSignal = 0;
	_msProcSpawnStderr = MS_EMPTY_STRING;
	_msProcSpawnOk = 0;
	_msProcSpawnPipeOk = 1;

	const char* cmd = msStringToCString(command);

#ifdef _WIN32
	/* Critical section runs to the CloseHandle of both write ends — see
	 * _msSpawnCreateLock for why an unlocked window here hangs concurrent
	 * spawns. Every exit path below must release it. */
	AcquireSRWLockExclusive(&_msSpawnCreateLock);

	SECURITY_ATTRIBUTES sa;
	sa.nLength = sizeof(SECURITY_ATTRIBUTES);
	sa.bInheritHandle = TRUE;
	sa.lpSecurityDescriptor = NULL;

	/* 64 KB pipe buffers rather than the ~4 KB default: the pump below is
	 * already deadlock-free at any size, this just cuts the number of
	 * Peek/Read round trips for the multi-kilobyte diagnostic dumps a failing
	 * compile produces. */
	HANDLE outRd = NULL, outWr = NULL;
	HANDLE errRd = NULL, errWr = NULL;
	if (!CreatePipe(&outRd, &outWr, &sa, 64 * 1024)) {
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}
	if (!SetHandleInformation(outRd, HANDLE_FLAG_INHERIT, 0)) {
		CloseHandle(outRd); CloseHandle(outWr);
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}
	if (!CreatePipe(&errRd, &errWr, &sa, 64 * 1024)) {
		CloseHandle(outRd); CloseHandle(outWr);
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}
	if (!SetHandleInformation(errRd, HANDLE_FLAG_INHERIT, 0)) {
		CloseHandle(outRd); CloseHandle(outWr);
		CloseHandle(errRd); CloseHandle(errWr);
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}

	/* Run via cmd.exe to support shell features (pipes, redirects). Flags are
	 * `/d /s /c "<command>"`, the same form Node's child_process.exec uses.
	 *
	 * /s + wrapping the whole command in quotes, NOT a bare `/c %s`: without /s,
	 * cmd applies its legacy quote-stripping rule — when the line starts with a
	 * quote it drops that quote and the LAST one on the line, which unbalances
	 * every quote in between. A command whose first token is a quoted path
	 * (`"C:/…/zig.exe" cc …`) and that also carries a quoted arg containing
	 * redirect characters (`-DMBEDTLS_CONFIG_FILE="<mbedtls/mbedtlsConfig.h>"`)
	 * then exposes the `<`/`>` as redirects and cmd rejects the whole line with
	 * "The syntax of the command is incorrect." before spawning anything.
	 * With /s the outer pair is stripped and the remainder is passed verbatim;
	 * redirects and pipes written outside that pair still work.
	 *
	 * /d skips the AutoRun command in HK{CU,LM}\Software\Microsoft\Command
	 * Processor. Without it, an arbitrary user-configured command runs inside
	 * every process we spawn — non-deterministic builds and an injection point.
	 *
	 * Sizing: "cmd.exe /d /s /c \"" (18) + closing quote (1) + NUL (1) = 20. */
	char* cmdLine = (char*)malloc(strlen(cmd) + 24);
	if (!cmdLine) {
		CloseHandle(outRd); CloseHandle(outWr);
		CloseHandle(errRd); CloseHandle(errWr);
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}
	sprintf(cmdLine, "cmd.exe /d /s /c \"%s\"", cmd);

	STARTUPINFOA si;
	PROCESS_INFORMATION pi;
	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
	si.hStdOutput = outWr;
	si.hStdError = errWr;
	ZeroMemory(&pi, sizeof(pi));

	BOOL ok = CreateProcessA(NULL, cmdLine, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
	free(cmdLine);
	CloseHandle(outWr);  /* child writes; parent reads */
	CloseHandle(errWr);
	/* Both write ends are gone from this process, so no later spawn can leak
	 * them into an unrelated child — end of the critical section. The drain
	 * below is the slow part and runs unlocked, so spawns stay parallel. */
	ReleaseSRWLockExclusive(&_msSpawnCreateLock);
	if (!ok) {
		CloseHandle(outRd); CloseHandle(errRd);
		return MS_EMPTY_STRING;
	}

	/* Drain BOTH pipes concurrently.
	 *
	 * Reading stdout to EOF and only then starting on stderr deadlocks: a child
	 * that fills the stderr pipe buffer blocks in WriteFile, so it never exits
	 * and never closes stdout, and the parent waits forever for a stdout EOF
	 * that cannot arrive. Compiler and linker diagnostics pass the buffer size
	 * routinely — the hang lands on exactly the builds whose output you need.
	 *
	 * PeekNamedPipe services both pipes from this one thread, so neither
	 * overlapped I/O nor a reader thread per pipe is needed. The 1 ms backoff
	 * only runs when both pipes are momentarily empty and still open. */
	size_t outCap = 4096, outLen = 0;
	size_t errCap = 4096, errLen = 0;
	char* outBuf = (char*)malloc(outCap);
	char* errBuf = (char*)malloc(errCap);
	BOOL outOpen = TRUE, errOpen = TRUE;
	while (outOpen || errOpen) {
		BOOL didRead = FALSE;
		if (outOpen && !msSpawnPumpPipe(outRd, &outBuf, &outCap, &outLen, &didRead)) outOpen = FALSE;
		if (errOpen && !msSpawnPumpPipe(errRd, &errBuf, &errCap, &errLen, &didRead)) errOpen = FALSE;
		if (!didRead && (outOpen || errOpen)) Sleep(1);
	}
	CloseHandle(outRd);
	CloseHandle(errRd);
	/* A failed allocation means the captured text is incomplete. Report it as a
	 * pipe error instead of handing back a short read that reads like success. */
	if (!outBuf || !errBuf) _msProcSpawnPipeOk = 0;

	WaitForSingleObject(pi.hProcess, INFINITE);
	DWORD exitCode = 0;
	GetExitCodeProcess(pi.hProcess, &exitCode);
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	_msProcSpawnOk = 1;
	_msProcSpawnExitCode = (int32_t)exitCode;
	_msProcSpawnSignal = 0;  /* Windows has no signal concept here */

	msString stdoutResult = MS_EMPTY_STRING;
	msString stderrResult = MS_EMPTY_STRING;
	if (outBuf) { outBuf[outLen] = '\0'; stdoutResult = msStringNew(outBuf, (int64_t)outLen); free(outBuf); }
	if (errBuf) { errBuf[errLen] = '\0'; stderrResult = msStringNew(errBuf, (int64_t)errLen); free(errBuf); }
	_msProcSpawnStderr = stderrResult;
	return stdoutResult;

#else  /* POSIX */
	int outPipe[2], errPipe[2];
	if (pipe(outPipe) < 0) return MS_EMPTY_STRING;
	if (pipe(errPipe) < 0) {
		close(outPipe[0]); close(outPipe[1]);
		return MS_EMPTY_STRING;
	}

	/* posix_spawn, not fork() — see msProcessExecFile. Shell exec keeps
	 * pipes/redirects/glob in the command string working. */
	posix_spawn_file_actions_t fa;
	if (posix_spawn_file_actions_init(&fa) != 0) {
		close(outPipe[0]); close(outPipe[1]);
		close(errPipe[0]); close(errPipe[1]);
		return MS_EMPTY_STRING;
	}
	posix_spawn_file_actions_addclose(&fa, outPipe[0]);
	posix_spawn_file_actions_addclose(&fa, errPipe[0]);
	posix_spawn_file_actions_adddup2(&fa, outPipe[1], STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&fa, errPipe[1], STDERR_FILENO);
	posix_spawn_file_actions_addclose(&fa, outPipe[1]);
	posix_spawn_file_actions_addclose(&fa, errPipe[1]);
	char* shArgv[4];
	shArgv[0] = (char*)"sh";
	shArgv[1] = (char*)"-c";
	shArgv[2] = (char*)cmd;
	shArgv[3] = NULL;
	pid_t pid = 0;
	int spawnErr = posix_spawn(&pid, "/bin/sh", &fa, NULL, shArgv, MS_SPAWN_ENVIRON);
	posix_spawn_file_actions_destroy(&fa);
	if (spawnErr != 0) {
		close(outPipe[0]); close(outPipe[1]);
		close(errPipe[0]); close(errPipe[1]);
		return MS_EMPTY_STRING;
	}

	/* Parent */
	close(outPipe[1]);
	close(errPipe[1]);

	char* outBuf = NULL; size_t outLen = 0;
	char* errBuf = NULL; size_t errLen = 0;
	if (!_msSpawnDrainFd(outPipe[0], &outBuf, &outLen)) _msProcSpawnPipeOk = 0;
	if (!_msSpawnDrainFd(errPipe[0], &errBuf, &errLen)) _msProcSpawnPipeOk = 0;
	close(outPipe[0]);
	close(errPipe[0]);

	int status = 0;
	if (waitpid(pid, &status, 0) < 0) {
		if (outBuf) free(outBuf);
		if (errBuf) free(errBuf);
		return MS_EMPTY_STRING;
	}

	_msProcSpawnOk = 1;
	if (WIFEXITED(status)) {
		_msProcSpawnExitCode = (int32_t)WEXITSTATUS(status);
		_msProcSpawnSignal = 0;
	} else if (WIFSIGNALED(status)) {
		_msProcSpawnExitCode = 0;
		_msProcSpawnSignal = (int32_t)WTERMSIG(status);
	} else {
		_msProcSpawnExitCode = -1;
		_msProcSpawnSignal = 0;
	}

	msString stdoutResult = MS_EMPTY_STRING;
	msString stderrResult = MS_EMPTY_STRING;
	if (outBuf) { stdoutResult = msStringNew(outBuf, (int64_t)outLen); free(outBuf); }
	if (errBuf) { stderrResult = msStringNew(errBuf, (int64_t)errLen); free(errBuf); }
	_msProcSpawnStderr = stderrResult;
	return stdoutResult;
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

/**
 * Set environment variable. Overwrites existing. 1.0 on success, 0.0 on failure.
 */
static inline double msProcessSetEnv(msString name, msString value) {
	const char* cname = msStringToCString(name);
	const char* cval = msStringToCString(value);
#if defined(_WIN32)
	return (_putenv_s(cname, cval) == 0) ? 1.0 : 0.0;
#else
	return (setenv(cname, cval, 1) == 0) ? 1.0 : 0.0;
#endif
}

/**
 * Remove environment variable. 1.0 on success, 0.0 on failure (incl. not-set).
 */
static inline double msProcessUnsetEnv(msString name) {
	const char* cname = msStringToCString(name);
#if defined(_WIN32)
	return (_putenv_s(cname, "") == 0) ? 1.0 : 0.0;
#else
	return (unsetenv(cname) == 0) ? 1.0 : 0.0;
#endif
}

// Time primitives (wall-clock, monotonic) live in runtime/core/datetime.h,
// surfaced via std/core/date (Date.now()) and std/core/time (time.monotonicMs()) preludes.

// =============================================================================
// Platform detection
// =============================================================================

/**
 * Return platform identifier string: "windows", "darwin", "linux", or "other".
 * Resolved at compile time via platform macros — no syscall cost.
 */
static inline msString msProcessPlatform(void) {
#if defined(_WIN32)
	return msStringFromCStr("windows");
#elif defined(__APPLE__)
	return msStringFromCStr("darwin");
#elif defined(__linux__)
	return msStringFromCStr("linux");
#else
	return msStringFromCStr("other");
#endif
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_PROCESS_H */
