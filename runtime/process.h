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

#if defined(__EMSCRIPTEN__) || defined(__wasi__)
#define MS_NO_SPAWN 1
#else
#define MS_NO_SPAWN 0
#endif

#ifdef _WIN32
#include <windows.h>
#include <errno.h>
#include <direct.h>
#include <shellapi.h>
#elif MS_NO_SPAWN
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#else
#include <sys/types.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <string.h>
#include <spawn.h>
#include <poll.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#define MS_SPAWN_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define MS_SPAWN_ENVIRON environ
#endif
#endif

#if defined(__ANDROID__) && __ANDROID_API__ < 34
/* bionic has posix_spawn from API 28 and posix_spawn_file_actions_addchdir_np from API 34.
 * Below 34 the same calls run on fork + exec: the child touches only async-signal-safe
 * calls, and an exec that fails exits 127 instead of failing the spawn. */
typedef struct {
	int count;
	struct { int kind; int fd; int target; const char *path; } steps[16];
} msSpawnActions;

typedef struct { short flags; sigset_t mask; sigset_t defaults; } msSpawnAttr;

static inline int msSpawnAttrInit(msSpawnAttr *attr) {
	attr->flags = 0;
	sigemptyset(&attr->mask);
	sigemptyset(&attr->defaults);
	return 0;
}

static inline int msSpawnActionsInit(msSpawnActions *actions) { actions->count = 0; return 0; }
static inline int msSpawnActionsDestroy(msSpawnActions *actions) { (void)actions; return 0; }
static inline int msSpawnActionsAdd(msSpawnActions *actions, int kind, int fd, int target, const char *path) {
	if (actions->count == 16) return ENOMEM;
	actions->steps[actions->count].kind = kind;
	actions->steps[actions->count].fd = fd;
	actions->steps[actions->count].target = target;
	actions->steps[actions->count].path = path;
	actions->count += 1;
	return 0;
}

static inline int msSpawnFork(pid_t *pid, const char *file, int searchPath, const msSpawnActions *actions, const msSpawnAttr *attr, char *const argv[], char *const envp[]) {
	pid_t child = fork();
	if (child < 0) return errno;
	if (child == 0) {
		if (attr != NULL && (attr->flags & POSIX_SPAWN_SETSIGDEF)) {
			struct sigaction dfl;
			memset(&dfl, 0, sizeof dfl);
			dfl.sa_handler = SIG_DFL;
			for (int sig = 1; sig < NSIG; sig++) {
				if (sigismember(&attr->defaults, sig) == 1 && sigaction(sig, &dfl, NULL) != 0) _exit(127);
			}
		}
		if (attr != NULL && (attr->flags & POSIX_SPAWN_SETSIGMASK) && sigprocmask(SIG_SETMASK, &attr->mask, NULL) != 0) _exit(127);
		for (int i = 0; actions != NULL && i < actions->count; i++) {
			int failed = 0;
			if (actions->steps[i].kind == 0) failed = close(actions->steps[i].fd);
			else if (actions->steps[i].kind == 1) failed = dup2(actions->steps[i].fd, actions->steps[i].target) < 0;
			else failed = chdir(actions->steps[i].path);
			if (failed) _exit(127);
		}
		if (searchPath) execvpe(file, argv, envp);
		else execve(file, argv, envp);
		_exit(127);
	}
	*pid = child;
	return 0;
}

#define posix_spawn_file_actions_t msSpawnActions
#define posix_spawn_file_actions_init(actions) msSpawnActionsInit(actions)
#define posix_spawn_file_actions_destroy(actions) msSpawnActionsDestroy(actions)
#define posix_spawn_file_actions_addclose(actions, fd) msSpawnActionsAdd(actions, 0, fd, 0, NULL)
#define posix_spawn_file_actions_adddup2(actions, fd, target) msSpawnActionsAdd(actions, 1, fd, target, NULL)
#define posix_spawn_file_actions_addchdir_np(actions, path) msSpawnActionsAdd(actions, 2, 0, 0, path)
#define posix_spawnattr_t msSpawnAttr
#define posix_spawnattr_init(attr) msSpawnAttrInit(attr)
#define posix_spawnattr_destroy(attr) ((void)(attr), 0)
#define posix_spawnattr_setsigmask(attr, set) ((attr)->mask = *(set), 0)
#define posix_spawnattr_setsigdefault(attr, set) ((attr)->defaults = *(set), 0)
#define posix_spawnattr_setflags(attr, f) ((attr)->flags = (short)(f), 0)
#define posix_spawn(pid, file, actions, attr, argv, envp) msSpawnFork(pid, file, 0, actions, attr, argv, envp)
#define posix_spawnp(pid, file, actions, attr, argv, envp) msSpawnFork(pid, file, 1, actions, attr, argv, envp)
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

#if !defined(_WIN32) && !defined(__APPLE__) && !defined(__linux__)
extern int cmdCount;
extern char** cmdLine;
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
	return cmdLine ? (double)cmdCount : 0.0;
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
	if (!cmdLine || idx < 0 || idx >= cmdCount) return MS_EMPTY_STRING;
	return msStringFromCStr(cmdLine[idx]);
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
#elif MS_NO_SPAWN
static inline double msProcessExecFile(msString path, msStringArray* args) {
	(void)path; (void)args;
	errno = ENOSYS;
	return -1.0;
}
#else
/* posix_spawn hands the child every descriptor without FD_CLOEXEC, and macOS has no
 * pipe2: a spawn that lands between pipe() and the FD_CLOEXEC below leaks the pipe
 * the way the Windows _msSpawnCreateLock describes, so creation and spawn share it. */
static pthread_mutex_t _msSpawnCreateLock = PTHREAD_MUTEX_INITIALIZER;

static inline int _msSpawnPipe(int fds[2]) {
	pthread_mutex_lock(&_msSpawnCreateLock);
	int made = pipe(fds);
	if (made == 0) {
		fcntl(fds[0], F_SETFD, FD_CLOEXEC);
		fcntl(fds[1], F_SETFD, FD_CLOEXEC);
	}
	pthread_mutex_unlock(&_msSpawnCreateLock);
	return made;
}

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
	pthread_mutex_lock(&_msSpawnCreateLock);
	int spawnErr = posix_spawnp(&pid, pathStr, NULL, NULL, argv, MS_SPAWN_ENVIRON);
	pthread_mutex_unlock(&_msSpawnCreateLock);
	for (int64_t j = 1; j <= argc; j++) free(argv[j]);
	free(argv);
	if (spawnErr != 0) return -1.0;
	int status = 0;
	if (waitpid(pid, &status, 0) < 0) return -1.0;
	if (WIFEXITED(status)) return (double)WEXITSTATUS(status);
	if (WIFSIGNALED(status)) return (double)(128 + WTERMSIG(status));
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
//        actions + a poll() pump over both pipes + waitpid(). Stderr captured
//        separately.
// Windows: CreatePipe() × 2 + CreateProcess() + ReadFile loops +
//          WaitForSingleObject + GetExitCodeProcess.
//
// Each stream grows without a cap; an allocation failure reports a pipe error
// instead of a shortened capture.
//
// Both platforms service the two pipes from one thread and never let either
// fill: a child that writes past the pipe buffer on one stream while the
// parent is committed to the other deadlocks both, and a C compiler dumping
// warnings clears 64 KB routinely.

/* Thread-local: exec() runs concurrently on pool workers (parallel @compile /
 * module compile); shared globals would cross-attribute exit codes between jobs. */
static _Thread_local int32_t _msProcSpawnExitCode = 0;
static _Thread_local int32_t _msProcSpawnSignal = 0;
static _Thread_local msString _msProcSpawnStderr = MS_EMPTY_STRING;
static _Thread_local int32_t _msProcSpawnOk = 0;  /* 1 if spawn succeeded, 0 otherwise */
static _Thread_local int32_t _msProcSpawnPipeOk = 1;  /* 0 if a pipe read/setup failed mid-flight */
static _Thread_local int32_t _msProcSpawnErrno = 0;

static inline int32_t msProcSpawnGetExitCode(void) { return _msProcSpawnExitCode; }
static inline int32_t msProcSpawnGetSignal(void) { return _msProcSpawnSignal; }
static inline msString msProcSpawnGetStderr(void) { return _msProcSpawnStderr; }
static inline int32_t msProcSpawnGetOk(void) { return _msProcSpawnOk; }
static inline int32_t msProcSpawnGetPipeOk(void) { return _msProcSpawnPipeOk; }
static inline int32_t msProcSpawnGetErrno(void) { return _msProcSpawnErrno; }
static inline int32_t msProcSpawnGetUnsupported(void) { return _msProcSpawnErrno == ENOSYS; }

#if !defined(_WIN32) && !MS_NO_SPAWN
/* Move whatever is currently readable on `fd` into a growable buffer. Only ever
 * called on a descriptor poll() just reported ready, so the read cannot block.
 * Returns 0 once the pipe is at EOF (every write end closed), on a read error,
 * or on allocation failure. */
static inline int msSpawnPumpFd(int fd, char** buf, size_t* cap, size_t* len) {
	if (*buf == NULL) return 0;

	char chunk[4096];
	ssize_t n = read(fd, chunk, sizeof(chunk));
	if (n == 0) return 0;
	if (n < 0) {
		if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return 1;
		_msProcSpawnPipeOk = 0;
		return 0;
	}

	size_t got = (size_t)n;
	while (*len + got + 1 > *cap) {
		size_t newCap = *cap * 2;
		char* grown = (char*)realloc(*buf, newCap);
		if (!grown) { free(*buf); *buf = NULL; return 0; }  /* realloc keeps the old block on failure */
		*buf = grown;
		*cap = newCap;
	}
	memcpy(*buf + *len, chunk, got);
	*len += got;
	return 1;
}

/* Shared tail of the POSIX capture spawns: drain both pipes, reap the child,
 * populate the thread-local result state. Takes ownership of the fds + pid;
 * returns captured stdout. */
static inline msString _msPosixFinishCapture(int outFd, int errFd, pid_t pid) {
	size_t outCap = 4096, outLen = 0;
	size_t errCap = 4096, errLen = 0;
	char* outBuf = (char*)malloc(outCap);
	char* errBuf = (char*)malloc(errCap);
	int outOpen = 1, errOpen = 1;
	while (outOpen || errOpen) {
		struct pollfd fds[2];
		int outSlot = -1, errSlot = -1;
		nfds_t nfds = 0;
		if (outOpen) { outSlot = (int)nfds; fds[nfds].fd = outFd; fds[nfds].events = POLLIN; fds[nfds].revents = 0; nfds++; }
		if (errOpen) { errSlot = (int)nfds; fds[nfds].fd = errFd; fds[nfds].events = POLLIN; fds[nfds].revents = 0; nfds++; }
		if (poll(fds, nfds, -1) < 0) {
			if (errno == EINTR) continue;
			_msProcSpawnPipeOk = 0;
			break;
		}
		if (outSlot >= 0 && fds[outSlot].revents && !msSpawnPumpFd(outFd, &outBuf, &outCap, &outLen)) outOpen = 0;
		if (errSlot >= 0 && fds[errSlot].revents && !msSpawnPumpFd(errFd, &errBuf, &errCap, &errLen)) errOpen = 0;
	}
	close(outFd);
	close(errFd);
	/* A failed allocation means the captured text is incomplete. Report it as a
	 * pipe error instead of handing back a short read that reads like success. */
	if (!outBuf || !errBuf) _msProcSpawnPipeOk = 0;

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
	if (outBuf) { outBuf[outLen] = '\0'; stdoutResult = msStringNew(outBuf, (int64_t)outLen); free(outBuf); }
	if (errBuf) { errBuf[errLen] = '\0'; stderrResult = msStringNew(errBuf, (int64_t)errLen); free(errBuf); }
	_msProcSpawnStderr = stderrResult;
	return stdoutResult;
}
#endif

#ifdef _WIN32
/* Move whatever is currently buffered in `h` into a growable buffer without
 * blocking. Returns FALSE once the pipe is at EOF (every write end closed) or
 * on allocation failure; *didRead reports whether bytes moved so the caller can
 * skip its backoff while either pipe is still producing. */
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

/* Create the two capture pipes with non-inheritable read ends. Callers hold
 * _msSpawnCreateLock across this and the spawn (see that lock for why).
 * 64 KB buffers rather than the ~4 KB default: the pump below is already
 * deadlock-free at any size, this just cuts the number of Peek/Read round
 * trips for the multi-kilobyte diagnostic dumps a failing compile produces.
 * On failure every handle is closed and FALSE returned. */
static inline BOOL _msWinCreateCapturePipes(HANDLE* outRd, HANDLE* outWr, HANDLE* errRd, HANDLE* errWr) {
	SECURITY_ATTRIBUTES sa;
	sa.nLength = sizeof(SECURITY_ATTRIBUTES);
	sa.bInheritHandle = TRUE;
	sa.lpSecurityDescriptor = NULL;
	if (!CreatePipe(outRd, outWr, &sa, 64 * 1024)) return FALSE;
	if (!SetHandleInformation(*outRd, HANDLE_FLAG_INHERIT, 0)) {
		CloseHandle(*outRd); CloseHandle(*outWr);
		return FALSE;
	}
	if (!CreatePipe(errRd, errWr, &sa, 64 * 1024)) {
		CloseHandle(*outRd); CloseHandle(*outWr);
		return FALSE;
	}
	if (!SetHandleInformation(*errRd, HANDLE_FLAG_INHERIT, 0)) {
		CloseHandle(*outRd); CloseHandle(*outWr);
		CloseHandle(*errRd); CloseHandle(*errWr);
		return FALSE;
	}
	return TRUE;
}

/* Shared tail of the Windows capture spawns.
 *
 * Drain BOTH pipes concurrently: reading stdout to EOF and only then starting
 * on stderr deadlocks — a child that fills the stderr pipe buffer blocks in
 * WriteFile, so it never exits and never closes stdout, and the parent waits
 * forever for a stdout EOF that cannot arrive. Compiler and linker
 * diagnostics pass the buffer size routinely — the hang lands on exactly the
 * builds whose output you need. PeekNamedPipe services both pipes from this
 * one thread, so neither overlapped I/O nor a reader thread per pipe is
 * needed. The 1 ms backoff only runs when both pipes are momentarily empty
 * and still open.
 *
 * Takes ownership of the read ends and the process/thread handles; returns
 * captured stdout. */
static inline msString _msWinFinishCapture(HANDLE outRd, HANDLE errRd, PROCESS_INFORMATION pi) {
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
}
#endif  /* _WIN32 */

static inline msString msProcessSpawnSync(msString command) {
	/* Reset side-channel state for this invocation. */
	_msProcSpawnExitCode = 0;
	_msProcSpawnSignal = 0;
	_msProcSpawnStderr = MS_EMPTY_STRING;
	_msProcSpawnOk = 0;
	_msProcSpawnPipeOk = 1;
	_msProcSpawnErrno = 0;

	const char* cmd = msStringToCString(command);

#ifdef _WIN32
	/* Critical section runs to the CloseHandle of both write ends — see
	 * _msSpawnCreateLock for why an unlocked window here hangs concurrent
	 * spawns. Every exit path below must release it. */
	AcquireSRWLockExclusive(&_msSpawnCreateLock);

	HANDLE outRd = NULL, outWr = NULL;
	HANDLE errRd = NULL, errWr = NULL;
	if (!_msWinCreateCapturePipes(&outRd, &outWr, &errRd, &errWr)) {
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

	return _msWinFinishCapture(outRd, errRd, pi);

#elif MS_NO_SPAWN
	(void)command;
	_msProcSpawnErrno = ENOSYS;
	return MS_EMPTY_STRING;
#else  /* POSIX */
	int outPipe[2], errPipe[2];
	if (_msSpawnPipe(outPipe) < 0) return MS_EMPTY_STRING;
	if (_msSpawnPipe(errPipe) < 0) {
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
	pthread_mutex_lock(&_msSpawnCreateLock);
	int spawnErr = posix_spawn(&pid, "/bin/sh", &fa, NULL, shArgv, MS_SPAWN_ENVIRON);
	pthread_mutex_unlock(&_msSpawnCreateLock);
	posix_spawn_file_actions_destroy(&fa);
	if (spawnErr != 0) {
		close(outPipe[0]); close(outPipe[1]);
		close(errPipe[0]); close(errPipe[1]);
		return MS_EMPTY_STRING;
	}

	/* Parent */
	close(outPipe[1]);
	close(errPipe[1]);
	return _msPosixFinishCapture(outPipe[0], errPipe[0], pid);
#endif
}

/**
 * Synchronous argv subprocess WITH capture — the no-shell counterpart of
 * msProcessSpawnSync. Spawns `exe` with `args` directly (no /bin/sh, no
 * cmd.exe) and reports through the same thread-local getters (exit code,
 * signal, stderr, ok, pipeOk); returns captured stdout.
 *
 * This is the spawn path for invoking build tools (the C compiler above all):
 * a shell in that loop only adds failure modes — cmd.exe quote-stripping, the
 * 8191-char command-line cap, AutoRun hooks, POSIX-isms (`rm -f`, `2>/dev/null`)
 * — and none of its features (pipes, redirects, globbing) are wanted when the
 * command is already a token list. The reference compiler invokes cc exactly
 * this way: per-argument CRT quoting straight into CreateProcessW.
 *
 * - Windows: MS-CRT quoting per argument (_msAppendWinArg), UTF-8 → UTF-16,
 *   CreateProcessW with lpApplicationName=NULL so the first quoted token
 *   resolves through the standard search order (exe dir, cwd, system dirs,
 *   PATH). The W API also makes paths outside the ANSI codepage work.
 * - POSIX: posix_spawnp (PATH search) with dup2 file actions onto two pipes.
 *
 * A non-empty `cwd` is the child's working directory; empty inherits ours.
 */
static inline msString msProcessSpawnSyncArgv(msString exe, msStringArray* args, msString cwd) {
	/* Reset side-channel state for this invocation. */
	_msProcSpawnExitCode = 0;
	_msProcSpawnSignal = 0;
	_msProcSpawnStderr = MS_EMPTY_STRING;
	_msProcSpawnOk = 0;
	_msProcSpawnPipeOk = 1;
	_msProcSpawnErrno = 0;

#ifdef _WIN32
	AcquireSRWLockExclusive(&_msSpawnCreateLock);

	HANDLE outRd = NULL, outWr = NULL;
	HANDLE errRd = NULL, errWr = NULL;
	if (!_msWinCreateCapturePipes(&outRd, &outWr, &errRd, &errWr)) {
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}

	/* Command line: "exe" arg1 arg2 … with MS-CRT quoting per token. */
	const char* exeStr = msStringToCString(exe);
	/* CreateProcessW with lpApplicationName=NULL resolves the first command-
	 * line token itself and does NOT normalize forward slashes there (unlike
	 * lpApplicationName, which accepts them). Managed-zig paths are
	 * forward-slash ("C:/Users/…/zig.exe"), so normalize the exe token to
	 * backslashes. Args keep their spelling — the child handles either. */
	size_t exeLen = strlen(exeStr);
	char* exeNorm = (char*)malloc(exeLen + 1);
	if (!exeNorm) {
		CloseHandle(outRd); CloseHandle(outWr);
		CloseHandle(errRd); CloseHandle(errWr);
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}
	memcpy(exeNorm, exeStr, exeLen + 1);
	for (char* p = exeNorm; *p; p++) {
		if (*p == '/') *p = '\\';
	}
	size_t cap = 256;
	size_t len = 0;
	char* cmdLine = (char*)malloc(cap);
	if (!cmdLine) {
		free(exeNorm);
		CloseHandle(outRd); CloseHandle(outWr);
		CloseHandle(errRd); CloseHandle(errWr);
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}
	_msAppendWinArg(&cmdLine, &len, &cap, exeNorm);
	free(exeNorm);
	if (args != NULL && args->p != NULL) {
		for (int64_t i = 0; i < args->len; i++) {
			if (len + 2 > cap) { cap *= 2; cmdLine = (char*)realloc(cmdLine, cap); }
			cmdLine[len++] = ' ';
			const char* a = msStringToCString(args->p->data[i]);
			_msAppendWinArg(&cmdLine, &len, &cap, a);
		}
	}
	cmdLine[len] = '\0';

	/* UTF-8 → UTF-16. MetaScript strings are UTF-8; building the command line
	 * in UTF-8 and converting once keeps the quoting logic byte-based. */
	int wlen = MultiByteToWideChar(CP_UTF8, 0, cmdLine, (int)len + 1, NULL, 0);
	wchar_t* wcmd = NULL;
	if (wlen > 0) wcmd = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)wlen);
	if (wcmd == NULL || MultiByteToWideChar(CP_UTF8, 0, cmdLine, (int)len + 1, wcmd, wlen) == 0) {
		free(cmdLine);
		if (wcmd) free(wcmd);
		CloseHandle(outRd); CloseHandle(outWr);
		CloseHandle(errRd); CloseHandle(errWr);
		ReleaseSRWLockExclusive(&_msSpawnCreateLock);
		return MS_EMPTY_STRING;
	}

	wchar_t* wcwd = NULL;
	if (cwd.len > 0) {
		const char* cwdStr = msStringToCString(cwd);
		int cwdLen = MultiByteToWideChar(CP_UTF8, 0, cwdStr, -1, NULL, 0);
		if (cwdLen > 0) wcwd = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)cwdLen);
		if (wcwd == NULL || MultiByteToWideChar(CP_UTF8, 0, cwdStr, -1, wcwd, cwdLen) == 0) {
			free(cmdLine);
			free(wcmd);
			if (wcwd) free(wcwd);
			CloseHandle(outRd); CloseHandle(outWr);
			CloseHandle(errRd); CloseHandle(errWr);
			ReleaseSRWLockExclusive(&_msSpawnCreateLock);
			return MS_EMPTY_STRING;
		}
		for (wchar_t* p = wcwd; *p; p++) {
			if (*p == L'/') *p = L'\\';
		}
	}

	STARTUPINFOW si;
	PROCESS_INFORMATION pi;
	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
	si.hStdOutput = outWr;
	si.hStdError = errWr;
	ZeroMemory(&pi, sizeof(pi));

	BOOL ok = CreateProcessW(NULL, wcmd, NULL, NULL, TRUE, 0, NULL, wcwd, &si, &pi);
	free(cmdLine);
	free(wcmd);
	if (wcwd) free(wcwd);
	CloseHandle(outWr);  /* child writes; parent reads */
	CloseHandle(errWr);
	/* Both write ends are gone from this process — end of the critical
	 * section (see _msSpawnCreateLock). The drain runs unlocked. */
	ReleaseSRWLockExclusive(&_msSpawnCreateLock);
	if (!ok) {
		DWORD lastError = GetLastError();
		_msProcSpawnErrno = lastError == ERROR_FILE_NOT_FOUND || lastError == ERROR_PATH_NOT_FOUND ? ENOENT
			: lastError == ERROR_ACCESS_DENIED ? EACCES
			: lastError == ERROR_BAD_EXE_FORMAT ? ENOEXEC
			: 0;
		CloseHandle(outRd); CloseHandle(errRd);
		return MS_EMPTY_STRING;
	}

	return _msWinFinishCapture(outRd, errRd, pi);

#elif MS_NO_SPAWN
	(void)exe; (void)args; (void)cwd;
	_msProcSpawnErrno = ENOSYS;
	return MS_EMPTY_STRING;
#else  /* POSIX */
	int outPipe[2], errPipe[2];
	if (_msSpawnPipe(outPipe) < 0) return MS_EMPTY_STRING;
	if (_msSpawnPipe(errPipe) < 0) {
		close(outPipe[0]); close(outPipe[1]);
		return MS_EMPTY_STRING;
	}

	const char* exeStr = msStringToCString(exe);
	int64_t argc = (args != NULL) ? args->len : 0;
	char** argv = (char**)malloc(sizeof(char*) * (size_t)(argc + 2));
	if (!argv) {
		close(outPipe[0]); close(outPipe[1]);
		close(errPipe[0]); close(errPipe[1]);
		return MS_EMPTY_STRING;
	}
	argv[0] = (char*)exeStr;
	/* msStringToCString may reuse a shared buffer — materialize each arg now. */
	for (int64_t i = 0; i < argc; i++) {
		const char* src = msStringToCString(args->p->data[i]);
		size_t slen = strlen(src);
		char* copy = (char*)malloc(slen + 1);
		if (!copy) {
			for (int64_t j = 1; j <= i; j++) free(argv[j]);
			free(argv);
			close(outPipe[0]); close(outPipe[1]);
			close(errPipe[0]); close(errPipe[1]);
			return MS_EMPTY_STRING;
		}
		memcpy(copy, src, slen + 1);
		argv[i + 1] = copy;
	}
	argv[argc + 1] = NULL;

	posix_spawn_file_actions_t fa;
	if (posix_spawn_file_actions_init(&fa) != 0) {
		for (int64_t j = 1; j <= argc; j++) free(argv[j]);
		free(argv);
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
	if (cwd.len > 0) posix_spawn_file_actions_addchdir_np(&fa, msStringToCString(cwd));
	pid_t pid = 0;
	pthread_mutex_lock(&_msSpawnCreateLock);
	int spawnErr = posix_spawnp(&pid, exeStr, &fa, NULL, argv, MS_SPAWN_ENVIRON);
	pthread_mutex_unlock(&_msSpawnCreateLock);
	posix_spawn_file_actions_destroy(&fa);
	for (int64_t j = 1; j <= argc; j++) free(argv[j]);
	free(argv);
	if (spawnErr != 0) {
		_msProcSpawnErrno = spawnErr;
		close(outPipe[0]); close(outPipe[1]);
		close(errPipe[0]); close(errPipe[1]);
		return MS_EMPTY_STRING;
	}

	close(outPipe[1]);
	close(errPipe[1]);
	return _msPosixFinishCapture(outPipe[0], errPipe[0], pid);
#endif
}

// =============================================================================
// Long-lived child process: three pipes, deadline-bounded pump
// =============================================================================
//
// msProcChildSpawn returns a handle (> 0) or -errno. Every blocking call takes
// a deadline in milliseconds (0 polls once) and returns an MS_PROC_CHILD_*
// code; read, write and wait all run one pump over the three pipes, so a child
// that fills one stream while the parent waits on another keeps flowing.
// A stream buffer stops reading at MS_PROC_CHILD_BUFFER_CAP instead of
// dropping bytes, and the next read of that stream reports the overflow.

#define MS_PROC_CHILD_OK 0
#define MS_PROC_CHILD_ENDED 1
#define MS_PROC_CHILD_TIMEOUT 2
#define MS_PROC_CHILD_PIPE_CLOSED 3
#define MS_PROC_CHILD_OVERFLOW 4
#define MS_PROC_CHILD_ERROR 5

#define MS_PROC_CHILD_BUFFER_CAP ((size_t)16 * 1024 * 1024)

static inline int32_t msProcChildIsUnsupported(int64_t spawnResult) { return spawnResult == -(int64_t)ENOSYS; }

#if !defined(_WIN32) && !MS_NO_SPAWN
typedef struct {
	int fd;
	char* data;
	size_t len;
	size_t cap;
	int overflow;
} msProcChildStream;

typedef struct {
	pid_t pid;
	int inFd;
	msProcChildStream out;
	msProcChildStream err;
	int reaped;
	int rawStatus;
	int closed;
	int lastErrno;
	int64_t written;
} msProcChild;

static inline double _msProcChildNowMs(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static inline int _msProcChildRemainingMs(double deadline) {
	double left = deadline - _msProcChildNowMs();
	if (left <= 0) return 0;
	if (left >= 2147483647.0) return 2147483647;
	return (int)(left + 0.999);
}

static inline void _msProcChildCloseFd(int* fd) {
	if (*fd >= 0) {
		close(*fd);
		*fd = -1;
	}
}

static inline void _msProcChildRecordStatus(msProcChild* c, int status) {
	c->reaped = 1;
	c->rawStatus = status;
}

/* One read into the stream's buffer; the fd was reported ready, so it cannot block. */
static inline void _msProcChildFill(msProcChild* c, msProcChildStream* s) {
	size_t room = MS_PROC_CHILD_BUFFER_CAP - s->len;
	if (room == 0) {
		s->overflow = 1;
		return;
	}
	size_t want = room < 65536 ? room : 65536;
	if (s->len + want > s->cap) {
		size_t newCap = s->cap == 0 ? 65536 : s->cap;
		while (newCap < s->len + want) newCap *= 2;
		char* grown = (char*)realloc(s->data, newCap);
		if (!grown) {
			c->lastErrno = ENOMEM;
			return;
		}
		s->data = grown;
		s->cap = newCap;
	}
	ssize_t n = read(s->fd, s->data + s->len, want);
	if (n > 0) {
		s->len += (size_t)n;
		return;
	}
	if (n == 0) {
		_msProcChildCloseFd(&s->fd);
		return;
	}
	if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return;
	c->lastErrno = errno;
	_msProcChildCloseFd(&s->fd);
}

/* A write to a child that closed its stdin returns EPIPE instead of raising SIGPIPE:
 * macOS marks the fd F_SETNOSIGPIPE at spawn; elsewhere the signal is blocked around
 * the write and a SIGPIPE it raised is consumed before the mask is restored. */
static inline ssize_t _msProcChildWriteNoSigpipe(int fd, const char* data, size_t len) {
#if defined(F_SETNOSIGPIPE)
	return write(fd, data, len);
#else
	sigset_t pipeSet, pending, old;
	sigemptyset(&pipeSet);
	sigaddset(&pipeSet, SIGPIPE);
	sigpending(&pending);
	int alreadyPending = sigismember(&pending, SIGPIPE);
	pthread_sigmask(SIG_BLOCK, &pipeSet, &old);
	ssize_t n = write(fd, data, len);
	int saved = errno;
	if (n < 0 && saved == EPIPE && !alreadyPending) {
		struct timespec zero = { 0, 0 };
		while (sigtimedwait(&pipeSet, NULL, &zero) < 0 && errno == EINTR) {}
	}
	pthread_sigmask(SIG_SETMASK, &old, NULL);
	errno = saved;
	return n;
#endif
}

/* One poll round over every open pipe, bounded by timeoutMs. Moves readable bytes into
 * the stream buffers and, when `data` is given, advances the pending write at *done. */
static inline void _msProcChildPump(msProcChild* c, const char* data, size_t len, size_t* done, int timeoutMs) {
	struct pollfd fds[3];
	int inSlot = -1, outSlot = -1, errSlot = -1;
	nfds_t nfds = 0;
	if (data != NULL && c->inFd >= 0 && *done < len) {
		inSlot = (int)nfds;
		fds[nfds].fd = c->inFd; fds[nfds].events = POLLOUT; fds[nfds].revents = 0; nfds++;
	}
	if (c->out.fd >= 0 && c->out.len < MS_PROC_CHILD_BUFFER_CAP) {
		outSlot = (int)nfds;
		fds[nfds].fd = c->out.fd; fds[nfds].events = POLLIN; fds[nfds].revents = 0; nfds++;
	} else if (c->out.fd >= 0) {
		c->out.overflow = 1;
	}
	if (c->err.fd >= 0 && c->err.len < MS_PROC_CHILD_BUFFER_CAP) {
		errSlot = (int)nfds;
		fds[nfds].fd = c->err.fd; fds[nfds].events = POLLIN; fds[nfds].revents = 0; nfds++;
	} else if (c->err.fd >= 0) {
		c->err.overflow = 1;
	}
	if (poll(fds, nfds, timeoutMs) <= 0) return;
	if (outSlot >= 0 && fds[outSlot].revents) _msProcChildFill(c, &c->out);
	if (errSlot >= 0 && fds[errSlot].revents) _msProcChildFill(c, &c->err);
	if (inSlot >= 0 && fds[inSlot].revents) {
		ssize_t n = _msProcChildWriteNoSigpipe(c->inFd, data + *done, len - *done);
		if (n > 0) *done += (size_t)n;
		else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) c->lastErrno = errno;
	}
}

static inline msProcChild* _msProcChildOf(int64_t h) { return (msProcChild*)(intptr_t)h; }

static inline int64_t msProcChildSpawn(msString path, msStringArray* args, msString cwd, int32_t mergeStderr) {
	int inPipe[2], outPipe[2], errPipe[2] = { -1, -1 };
	if (_msSpawnPipe(inPipe) < 0) return -(int64_t)errno;
	if (_msSpawnPipe(outPipe) < 0) {
		int e = errno;
		close(inPipe[0]); close(inPipe[1]);
		return -(int64_t)e;
	}
	if (!mergeStderr && _msSpawnPipe(errPipe) < 0) {
		int e = errno;
		close(inPipe[0]); close(inPipe[1]);
		close(outPipe[0]); close(outPipe[1]);
		return -(int64_t)e;
	}

	int64_t argc = (args != NULL) ? args->len : 0;
	char** argv = (char**)calloc((size_t)(argc + 2), sizeof(char*));
	msProcChild* c = (msProcChild*)calloc(1, sizeof(msProcChild));
	int failed = (argv == NULL || c == NULL) ? ENOMEM : 0;
	/* msStringToCString may reuse a shared buffer — materialize every string now. */
	for (int64_t i = -1; !failed && i < argc; i++) {
		const char* src = msStringToCString(i < 0 ? path : args->p->data[i]);
		size_t slen = strlen(src);
		char* copy = (char*)malloc(slen + 1);
		if (!copy) { failed = ENOMEM; break; }
		memcpy(copy, src, slen + 1);
		argv[i + 1] = copy;
	}

	posix_spawn_file_actions_t fa;
	posix_spawnattr_t attr;
	int haveFa = 0, haveAttr = 0;
	if (!failed && (failed = posix_spawn_file_actions_init(&fa)) == 0) haveFa = 1;
	if (!failed && (failed = posix_spawnattr_init(&attr)) == 0) haveAttr = 1;
	if (!failed) {
		sigset_t emptyMask, defaults;
		sigemptyset(&emptyMask);
		sigemptyset(&defaults);
		sigaddset(&defaults, SIGPIPE);
		posix_spawnattr_setsigmask(&attr, &emptyMask);
		posix_spawnattr_setsigdefault(&attr, &defaults);
		posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
		int childErr = mergeStderr ? outPipe[1] : errPipe[1];
		posix_spawn_file_actions_addclose(&fa, inPipe[1]);
		posix_spawn_file_actions_addclose(&fa, outPipe[0]);
		if (!mergeStderr) posix_spawn_file_actions_addclose(&fa, errPipe[0]);
		posix_spawn_file_actions_adddup2(&fa, inPipe[0], STDIN_FILENO);
		posix_spawn_file_actions_adddup2(&fa, outPipe[1], STDOUT_FILENO);
		posix_spawn_file_actions_adddup2(&fa, childErr, STDERR_FILENO);
		posix_spawn_file_actions_addclose(&fa, inPipe[0]);
		posix_spawn_file_actions_addclose(&fa, outPipe[1]);
		if (!mergeStderr) posix_spawn_file_actions_addclose(&fa, errPipe[1]);
		char* cwdCopy = NULL;
		if (cwd.len > 0) {
			cwdCopy = strdup(msStringToCString(cwd));
			if (!cwdCopy) failed = ENOMEM;
			else posix_spawn_file_actions_addchdir_np(&fa, cwdCopy);
		}
		if (!failed) {
			pid_t pid = 0;
			pthread_mutex_lock(&_msSpawnCreateLock);
			failed = posix_spawnp(&pid, argv[0], &fa, &attr, argv, MS_SPAWN_ENVIRON);
			pthread_mutex_unlock(&_msSpawnCreateLock);
			c->pid = pid;
		}
		free(cwdCopy);
	}
	if (haveFa) posix_spawn_file_actions_destroy(&fa);
	if (haveAttr) posix_spawnattr_destroy(&attr);
	if (argv) {
		for (int64_t j = 0; j <= argc; j++) free(argv[j]);
		free(argv);
	}

	close(inPipe[0]);
	close(outPipe[1]);
	if (!mergeStderr) close(errPipe[1]);
	if (failed) {
		close(inPipe[1]);
		close(outPipe[0]);
		if (!mergeStderr) close(errPipe[0]);
		free(c);
		return -(int64_t)failed;
	}

	c->inFd = inPipe[1];
	c->out.fd = outPipe[0];
	c->err.fd = mergeStderr ? -1 : errPipe[0];
	fcntl(c->inFd, F_SETFL, fcntl(c->inFd, F_GETFL) | O_NONBLOCK);
	fcntl(c->out.fd, F_SETFL, fcntl(c->out.fd, F_GETFL) | O_NONBLOCK);
	if (c->err.fd >= 0) fcntl(c->err.fd, F_SETFL, fcntl(c->err.fd, F_GETFL) | O_NONBLOCK);
#if defined(F_SETNOSIGPIPE)
	fcntl(c->inFd, F_SETNOSIGPIPE, 1);
#endif
	return (int64_t)(intptr_t)c;
}

static inline int32_t msProcChildPid(int64_t h) { return (int32_t)_msProcChildOf(h)->pid; }
static inline int32_t msProcChildErrno(int64_t h) { return (int32_t)_msProcChildOf(h)->lastErrno; }
static inline int64_t msProcChildWritten(int64_t h) { return _msProcChildOf(h)->written; }

/* Sends every byte of `data` (its length, not a NUL-terminated view) or reports how far it got. */
static inline int32_t msProcChildWrite(int64_t h, msString data, int64_t timeoutMs) {
	msProcChild* c = _msProcChildOf(h);
	c->written = 0;
	if (c->closed || c->inFd < 0) return MS_PROC_CHILD_PIPE_CLOSED;
	const char* bytes = data.len > 0 ? data.p->data : "";
	size_t len = (size_t)data.len;
	size_t done = 0;
	double deadline = _msProcChildNowMs() + (double)timeoutMs;
	c->lastErrno = 0;
	do {
		_msProcChildPump(c, bytes, len, &done, _msProcChildRemainingMs(deadline));
		c->written = (int64_t)done;
		if (c->lastErrno == EPIPE) return MS_PROC_CHILD_PIPE_CLOSED;
		if (c->lastErrno != 0) return MS_PROC_CHILD_ERROR;
		if (done == len) return MS_PROC_CHILD_OK;
	} while (_msProcChildNowMs() < deadline);
	return MS_PROC_CHILD_TIMEOUT;
}

static inline void msProcChildCloseStdin(int64_t h) {
	_msProcChildCloseFd(&_msProcChildOf(h)->inFd);
}

/* OK when the stream buffer holds at least one byte (take it with msProcChildTake),
 * ENDED at EOF with nothing buffered, OVERFLOW once after the buffer filled. */
static inline int32_t msProcChildRead(int64_t h, int32_t stream, int64_t timeoutMs) {
	msProcChild* c = _msProcChildOf(h);
	if (c->closed) return MS_PROC_CHILD_PIPE_CLOSED;
	msProcChildStream* s = stream == 0 ? &c->out : &c->err;
	double deadline = _msProcChildNowMs() + (double)timeoutMs;
	c->lastErrno = 0;
	for (int polled = 0; ; polled = 1) {
		if (s->overflow) {
			s->overflow = 0;
			return MS_PROC_CHILD_OVERFLOW;
		}
		if (s->len > 0) return MS_PROC_CHILD_OK;
		if (c->lastErrno != 0) return MS_PROC_CHILD_ERROR;
		if (s->fd < 0) return MS_PROC_CHILD_ENDED;
		if (polled && _msProcChildNowMs() >= deadline) return MS_PROC_CHILD_TIMEOUT;
		_msProcChildPump(c, NULL, 0, NULL, _msProcChildRemainingMs(deadline));
	}
}

static inline msString msProcChildTake(int64_t h, int32_t stream) {
	msProcChild* c = _msProcChildOf(h);
	msProcChildStream* s = stream == 0 ? &c->out : &c->err;
	if (s->len == 0) return MS_EMPTY_STRING;
	msString taken = msStringNew(s->data, (int64_t)s->len);
	s->len = 0;
	return taken;
}

/* WNOHANG between pump rounds, backing off from 50 us to 50 ms; the deadline leaves the child running. */
static inline int32_t msProcChildWait(int64_t h, int64_t timeoutMs) {
	msProcChild* c = _msProcChildOf(h);
	double deadline = _msProcChildNowMs() + (double)timeoutMs;
	int64_t delayUs = 50;
	while (!c->reaped) {
		int status = 0;
		pid_t got = waitpid(c->pid, &status, WNOHANG);
		if (got == c->pid) {
			_msProcChildRecordStatus(c, status);
			break;
		}
		if (got < 0 && errno != EINTR) {
			c->lastErrno = errno;
			return MS_PROC_CHILD_ERROR;
		}
		int left = _msProcChildRemainingMs(deadline);
		if (left == 0) return MS_PROC_CHILD_TIMEOUT;
		int64_t sliceUs = delayUs < (int64_t)left * 1000 ? delayUs : (int64_t)left * 1000;
		if (sliceUs >= 1000) {
			_msProcChildPump(c, NULL, 0, NULL, (int)(sliceUs / 1000));
		} else {
			_msProcChildPump(c, NULL, 0, NULL, 0);
			struct timespec pause = { 0, (long)(sliceUs * 1000) };
			nanosleep(&pause, NULL);
		}
		delayUs = delayUs * 2 < 50000 ? delayUs * 2 : 50000;
	}
	return MS_PROC_CHILD_OK;
}

/* SIGKILL, then a blocking reap: after SIGKILL it returns unless the child sits in an
 * uninterruptible kernel sleep. A reaped pid is never signalled, so a recycled pid is safe. */
static inline int32_t msProcChildKill(int64_t h) {
	msProcChild* c = _msProcChildOf(h);
	if (c->reaped) return MS_PROC_CHILD_OK;
	kill(c->pid, SIGKILL);
	int status = 0;
	pid_t got;
	do { got = waitpid(c->pid, &status, 0); } while (got < 0 && errno == EINTR);
	if (got != c->pid) {
		c->lastErrno = errno;
		return MS_PROC_CHILD_ERROR;
	}
	_msProcChildRecordStatus(c, status);
	return MS_PROC_CHILD_OK;
}

static inline int32_t msProcChildExitCode(int64_t h) {
	int st = _msProcChildOf(h)->rawStatus;
	if (WIFEXITED(st)) return (int32_t)WEXITSTATUS(st);
	return WIFSIGNALED(st) ? 0 : -1;
}

static inline int32_t msProcChildSignal(int64_t h) {
	int st = _msProcChildOf(h)->rawStatus;
	return WIFSIGNALED(st) ? (int32_t)WTERMSIG(st) : 0;
}

/* Idempotent: kills and reaps a child still running, closes every pipe, drops the buffers.
 * The exit status stays readable until msProcChildFree. */
static inline void msProcChildClose(int64_t h) {
	msProcChild* c = _msProcChildOf(h);
	if (c->closed) return;
	msProcChildKill(h);
	_msProcChildCloseFd(&c->inFd);
	_msProcChildCloseFd(&c->out.fd);
	_msProcChildCloseFd(&c->err.fd);
	free(c->out.data);
	free(c->err.data);
	c->out.data = NULL; c->out.len = 0; c->out.cap = 0;
	c->err.data = NULL; c->err.len = 0; c->err.cap = 0;
	c->closed = 1;
}

static inline void msProcChildFree(int64_t h) {
	msProcChildClose(h);
	free(_msProcChildOf(h));
}
#else
/* No spawn on this target: msProcChildSpawn refuses with ENOSYS, so no handle ever reaches the rest. */
static inline int64_t msProcChildSpawn(msString path, msStringArray* args, msString cwd, int32_t mergeStderr) {
	(void)path; (void)args; (void)cwd; (void)mergeStderr;
	return -(int64_t)ENOSYS;
}
static inline int32_t msProcChildPid(int64_t h) { (void)h; return 0; }
static inline int32_t msProcChildErrno(int64_t h) { (void)h; return ENOSYS; }
static inline int64_t msProcChildWritten(int64_t h) { (void)h; return 0; }
static inline int32_t msProcChildWrite(int64_t h, msString data, int64_t timeoutMs) { (void)h; (void)data; (void)timeoutMs; return MS_PROC_CHILD_ERROR; }
static inline void msProcChildCloseStdin(int64_t h) { (void)h; }
static inline int32_t msProcChildRead(int64_t h, int32_t stream, int64_t timeoutMs) { (void)h; (void)stream; (void)timeoutMs; return MS_PROC_CHILD_ERROR; }
static inline msString msProcChildTake(int64_t h, int32_t stream) { (void)h; (void)stream; return MS_EMPTY_STRING; }
static inline int32_t msProcChildWait(int64_t h, int64_t timeoutMs) { (void)h; (void)timeoutMs; return MS_PROC_CHILD_ERROR; }
static inline int32_t msProcChildKill(int64_t h) { (void)h; return MS_PROC_CHILD_ERROR; }
static inline int32_t msProcChildExitCode(int64_t h) { (void)h; return -1; }
static inline int32_t msProcChildSignal(int64_t h) { (void)h; return 0; }
static inline void msProcChildClose(int64_t h) { (void)h; }
static inline void msProcChildFree(int64_t h) { (void)h; }
#endif

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

/**
 * Return the CPU this program was compiled for, spelled as `--cpu` spells it:
 * "amd64", "arm64", "i386", "arm", "wasm32", "riscv64", or "other".
 * Resolved at compile time via CPU macros — no syscall cost.
 */
static inline msString msProcessArch(void) {
#if defined(__x86_64__) || defined(_M_X64)
	return msStringFromCStr("amd64");
#elif defined(__aarch64__) || defined(_M_ARM64)
	return msStringFromCStr("arm64");
#elif defined(__i386__) || defined(_M_IX86)
	return msStringFromCStr("i386");
#elif defined(__arm__) || defined(_M_ARM)
	return msStringFromCStr("arm");
#elif defined(__wasm32__)
	return msStringFromCStr("wasm32");
#elif defined(__riscv) && __riscv_xlen == 64
	return msStringFromCStr("riscv64");
#else
	return msStringFromCStr("other");
#endif
}

#ifdef __cplusplus
}
#endif

#endif /* MS_STD_PROCESS_H */
