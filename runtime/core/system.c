#include "runtime/core/system.h"

#if defined(MSOS_BARE) && defined(MSGC_MANUAL)
#ifndef MSOS_SOLANA
bool msErr = false;
msException* msCurrException = NULL;
#endif
msCallSoonFn msCallSoonProc = NULL;
void* msErrPayload = NULL;
#endif

/* A bare manual build force-includes manual.h, which provides all functions inline.
   Skip the rest of this file to avoid redefinitions. */
#if !defined(MSOS_BARE) || !defined(MSGC_MANUAL)

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include "runtime/core/errorf.h"

#ifdef MS_ERRORF_OWN_FORMATTER
typedef struct {
	char text[256];
	size_t len;
} msErrorLine;

static void msErrorPut(msErrorLine* line, const char* bytes, size_t count) {
	while (count > 0) {
		if (line->len == sizeof(line->text)) {
			fwrite(line->text, 1, line->len, stderr);
			line->len = 0;
		}
		size_t room = sizeof(line->text) - line->len;
		size_t take = count < room ? count : room;
		memcpy(line->text + line->len, bytes, take);
		line->len += take;
		bytes += take;
		count -= take;
	}
}

static void msErrorUnsigned(msErrorLine* line, unsigned long long value, unsigned base) {
	char digits[20];
	size_t at = sizeof(digits);
	do {
		unsigned digit = (unsigned)(value % base);
		digits[--at] = (char)(digit < 10 ? '0' + digit : 'a' + (digit - 10));
		value /= base;
	} while (value != 0);
	msErrorPut(line, digits + at, sizeof(digits) - at);
}

void msErrorf(const char* format, ...) {
	msErrorLine line;
	line.len = 0;
	va_list args;
	va_start(args, format);
	for (const char* at = format; *at != '\0'; at++) {
		if (*at != '%') {
			msErrorPut(&line, at, 1);
			continue;
		}
		at++;
		int precision = -1;
		if (at[0] == '.' && at[1] == '*') {
			precision = va_arg(args, int);
			at += 2;
		}
		int longs = 0;
		while (*at == 'l') {
			longs++;
			at++;
		}
		if (*at == 's') {
			const char* text = va_arg(args, const char*);
			if (text == NULL) text = "(null)";
			size_t count = 0;
			while ((precision < 0 || count < (size_t)precision) && text[count] != '\0') count++;
			msErrorPut(&line, text, count);
		} else if (*at == 'd') {
			long long value = longs == 0 ? va_arg(args, int) : longs == 1 ? va_arg(args, long) : va_arg(args, long long);
			if (value < 0) msErrorPut(&line, "-", 1);
			msErrorUnsigned(&line, value < 0 ? 0ULL - (unsigned long long)value : (unsigned long long)value, 10);
		} else if (*at == 'u') {
			unsigned long long value = longs == 0 ? va_arg(args, unsigned) : longs == 1 ? va_arg(args, unsigned long) : va_arg(args, unsigned long long);
			msErrorUnsigned(&line, value, 10);
		} else if (*at == 'p') {
			msErrorPut(&line, "0x", 2);
			msErrorUnsigned(&line, (unsigned long long)(uintptr_t)va_arg(args, void*), 16);
		} else if (*at == '%') {
			msErrorPut(&line, "%", 1);
		} else {
			msErrorPut(&line, "%?", 2);
			if (*at == '\0') break;
		}
	}
	va_end(args);
	fwrite(line.text, 1, line.len, stderr);
}
#endif

#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
/* stdout/stderr stay in the CRT's default TEXT mode on Windows: every '\n'
 * becomes CRLF on redirect, while the JS lane (node) and every POSIX target
 * emit plain LF — byte-parity across lanes breaks (corpus c-vs-js diff was
 * exactly the trailing \r set). Node writes LF everywhere even on Windows;
 * matching it is the one-right-place fix (runtime once), not a runner
 * normalization. Runs before main via the constructor the runtime already
 * relies on elsewhere. */
__attribute__((constructor)) static void msStdStreamsBinaryMode(void) {
	_setmode(_fileno(stdin), _O_BINARY);
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
}
#endif

/* DRC / exception globals — thread-local for multi-threaded safety */
MS_THREAD_LOCAL bool msErr = false;
MS_TLS_PUBLISH(msErr)
MS_THREAD_LOCAL msException* msCurrException = NULL;
MS_TLS_PUBLISH(msCurrException)

/* Async future globals (declared extern in future.h) */
MS_THREAD_LOCAL msCallSoonFn msCallSoonProc = NULL;
MS_TLS_PUBLISH(msCallSoonProc)
MS_THREAD_LOCAL void* msErrPayload = NULL;
MS_TLS_PUBLISH(msErrPayload)

/* Future callback-list spinlock (declared extern in future.h). Guards the
 * check-then-append of msFutureAddCallback against the grab-and-NULL of
 * msFutureFireCallbacks/msFutureCancel on a different thread: actor async
 * methods are dispatched on stolen pool-worker visits, so a callback can be
 * appended to a future at the exact moment another thread completes and
 * fires it — the appended node would be stranded on the finished future and
 * never run (lost wakeup; proven by the spawn-inside-actor hang, 2026-09-05).
 * Held only for list-pointer swaps, never while callbacks execute. */
_Atomic(int) gMsFutCbLock = 0;

/* One spawn lock for the whole program, declared in runtime/spawnLock.h and taken by std/process
 * around pipe creation and spawn: a lock defined in a module would be one per C file. */
#ifdef _WIN32
#include <windows.h>
SRWLOCK _msSpawnCreateLock = SRWLOCK_INIT;
#elif !defined(__EMSCRIPTEN__) && !defined(__wasi__) && !defined(MSOS_BARE)
#include <pthread.h>
pthread_mutex_t _msSpawnCreateLock = PTHREAD_MUTEX_INITIALIZER;
#endif

#if defined(_WIN32) && !defined(MSOS_BARE)
/* WaitOnAddress/WakeByAddressAll (Amendment E Tier 1's Windows arm) live in
 * api-ms-win-core-synch-l1-2-0 (Win8+; forwarded from kernel32 on newer
 * builds) — but the mingw import libs zig cc links do not carry them, so a
 * static __declspec(dllimport) reference is an undefined symbol at link
 * time (probed: linker error on every -l candidate). Resolve dynamically:
 * one GetProcAddress pair at first use, spin fallback when absent. The
 * fallback is the pre-Tier-1 pure-spin behaviour — degraded (contended
 * waiters burn their spin budget instead of parking) but sound, same shape
 * as the non-Windows fallback in runtime/promise/locked.h. */
typedef BOOL  (WINAPI *msWaitOnAddressFn)(volatile void*, void*, size_t, DWORD);
typedef void  (WINAPI *msWakeByAddressFn)(void*);
static msWaitOnAddressFn msWaitOnAddressP = NULL;
static msWakeByAddressFn msWakeByAddressAllP = NULL;
static LONG msFutexFnState = 0;  /* 0 = unresolved, 1 = resolving, 2 = done */
static void msFutexResolve(void) {
	if (msFutexFnState == 2) return;
	if (InterlockedCompareExchange(&msFutexFnState, 1, 0) == 0) {
		HMODULE k32 = GetModuleHandleA("kernel32.dll");
		HMODULE syn = GetModuleHandleA("api-ms-win-core-synch-l1-2-0.dll");
		if (k32 != NULL) {
			msWaitOnAddressP   = (msWaitOnAddressFn)(void*)GetProcAddress(k32, "WaitOnAddress");
			msWakeByAddressAllP = (msWakeByAddressFn)(void*)GetProcAddress(k32, "WakeByAddressAll");
		}
		if (msWaitOnAddressP == NULL && syn != NULL) {
			msWaitOnAddressP   = (msWaitOnAddressFn)(void*)GetProcAddress(syn, "WaitOnAddress");
			msWakeByAddressAllP = (msWakeByAddressFn)(void*)GetProcAddress(syn, "WakeByAddressAll");
		}
		InterlockedExchange(&msFutexFnState, 2);
	} else {
		while (msFutexFnState == 1) msCpuRelax();
	}
}
void msFutexWait(int* addr, int expected) {
	msFutexResolve();
	if (msWaitOnAddressP != NULL) {
		int cmp = expected;
		msWaitOnAddressP((volatile void*)addr, &cmp, sizeof(int), INFINITE);
	} else {
		/* No WaitOnAddress on this OS: keep polling like the pre-Tier-1 spin
	   * path. The acquire load pairs with the release store in
	   * msTicketLockRelease, so we never sleep past our turn. */
		while (msAtomicLoad(addr) == expected) msCpuRelax();
	}
}
void msFutexWakeAll(int* addr) {
	if (msWakeByAddressAllP != NULL) msWakeByAddressAllP((void*)addr);
}
void msFutexWaitUs(int* addr, int expected, uint32_t us) {
	msFutexResolve();
	int cmp = expected;
	if (msWaitOnAddressP != NULL) msWaitOnAddressP((volatile void*)addr, &cmp, sizeof(int), (DWORD)((us + 999u) / 1000u));
	else msCpuRelax();
}

int64_t msLockedSelf(void) { return (int64_t)GetCurrentThreadId(); }
#endif

#if defined(__ANDROID__)
#define MS_ANDROID5_FLOCKFILE_DEADLOCKS 1
#else
#define MS_ANDROID5_FLOCKFILE_DEADLOCKS 0
#endif

#ifdef _WIN32
static SRWLOCK msLineLock = SRWLOCK_INIT;
#define MS_LINE_LOCK(f) AcquireSRWLockExclusive(&msLineLock)
#define MS_LINE_UNLOCK(f) ReleaseSRWLockExclusive(&msLineLock)
#elif defined(__EMSCRIPTEN__) || defined(__wasi__) || defined(MSOS_BARE) || MS_ANDROID5_FLOCKFILE_DEADLOCKS
#define MS_LINE_LOCK(f) ((void)0)
#define MS_LINE_UNLOCK(f) ((void)0)
#else
#define MS_LINE_LOCK(f) flockfile(f)
#define MS_LINE_UNLOCK(f) funlockfile(f)
#endif

static void msWriteLine(FILE* f, msString s) {
	MS_LINE_LOCK(f);
	if (msStrLen(s) > 0) {
		fwrite(msStrData(&s), 1, msStrLen(s), f);
	}
	fputc('\n', f);
	fflush(f);
	MS_LINE_UNLOCK(f);
}

#ifndef MS_FREESTANDING_LIBC
void msPrintln(msString s) {
	msWriteLine(stdout, s);
}
#endif

void msEprintln(msString s) {
	fflush(stdout);
	msWriteLine(stderr, s);
}

void msWarnln(msString s) {
	msEprintln(s);
}

void msClearException(void) {
	msErr = false;
	msCurrException = NULL;
}

/* Reference popCurrentException, reduced to the single-slot representation: a
 * handler with no owning catch-var (bare `catch {}`) consumes the current
 * exception's sole reference here — decref then null. Named catch-vars instead
 * MOVE the reference into the binding and the analyzer decrefs it at handler
 * scope-end, so those keep using msClearException (null only). */
void msDiscardCurrentException(void) {
	msDecrefAny((void*)msCurrException);
	msErr = false;
	msCurrException = NULL;
}

static void msErrorDestroy(void* p) {
	msError* e = (msError*)p;
	msStringDecref(e->message);
	msStringDecref(e->name);
}

const msTypeInfo msErrorTypeInfo = {
	.name = "Error",
	.isCyclic = false,
	.traceFn = NULL,
	.destroyFn = (msDestroyProc)msErrorDestroy,
	.flags = 0,
};

msError* msMakeError(msString message) {
	msError* e = (msError*)msAllocTyped(sizeof(msError), &msErrorTypeInfo);
	static const struct { int64_t cap; char data[6]; } errorName = { MS_STRLIT_FLAG | MS_ASCII_BITS | 5, "Error" };
	e->message = message;
	e->name = MS_STRING_LIT(&errorName, 5);
	return e;
}

void msThrow(msString msg) {
	msCurrException = (msException*)msMakeError(msg);
	msErr = true;
}

void msExit(int32_t code) {
	msTestErrorFlag();
	exit((int)code);
}

int32_t msModuleEvalDepth = 0;
void (*msModuleGuard)(msModuleRecord* record, void (*fn)(void)) = NULL;

void msTestErrorFlag(void) {
	if (!msErr || msCurrException == NULL || msModuleEvalDepth > 0) return;
	msString m = ((msError*)msCurrException)->message;
	fputs("Error: unhandled exception: ", stderr);
	if (msStrLen(m) > 0) fwrite(msStrData(&m), 1, (size_t)msStrLen(m), stderr);
	fputc('\n', stderr);
	msDecrefAny((void*)msCurrException);
	msCurrException = NULL;
	exit(1);
}

void msFutureDecref(void* fut) { msFutureDeferredRelease(fut); }

void msRaiseAwaitedError(void* err) {
	msErr = true;
	msCurrException = err != NULL ? (msException*)err : (msException*)msMakeError(msStringFromCStr("noproc"));
	msErrPayload = (void*)msCurrException;
}

void msFutureRaiseFrom(msFutureBase* f) {
	if (f != NULL) {
		atomic_store_explicit(&f->errorObserved, true, memory_order_relaxed);
#ifndef MSOS_BARE
		msClearOrphanFailure(f);
#endif
	}
	void* err = (f != NULL) ? f->error : NULL;
	if (f != NULL && f->crossThreadPublished) f->error = NULL;
	else msIncRef(err);
	msRaiseAwaitedError(err);
}

void msFutureDropError(msFutureBase* f) {
	void* err = f->error;
	f->error = NULL;
	msDecrefAny(err);
}

void (*msFatalTrap)(void) = NULL;

_Noreturn void msRaiseOutOfMemory(void) {
	fputs("Error: out of memory\n", stderr);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseIndexError(int64_t idx, int64_t len) {
	msErrorf("Error: index %lld out of bounds (length %lld)\n",
		(long long)idx, (long long)len);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

static const char* msTypeInfoShownName(const msTypeInfo* t) {
	if (t == NULL) return "<untyped>";
	if (t->displayName != NULL) return t->displayName;
	return t->name != NULL ? t->name : "<untyped>";
}

_Noreturn void msRaiseObjectConversionError(void* p, const msTypeInfo* target) {
	const msTypeInfo* t = msHeader(p)->type;
	msErrorf("Error: invalid object conversion: %s is not %s\n", msTypeInfoShownName(t), msTypeInfoShownName(target));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseDestroyKeptSelf(void* p) {
	msErrorf("Error: onDestroy kept a reference to the %s it destroys; that reference would dangle once the object is freed\n", msTypeInfoShownName(msHeader(p)->type));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseOwnedCycle(const msTypeInfo** types, int32_t count) {
	msErrorf("Error: an owned cycle became garbage:");
	for (int32_t i = 0; i < count; i++) msErrorf("%s %s", i == 0 ? "" : ",", msTypeInfoShownName(types[i]));
	msErrorf(" objects own each other only through Owned<T> edges, so a release build would leak them; make the edge back up the cycle Unowned<T>\n");
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseUnownedDead(void* p) {
	msErrorf("Error: an Unowned<%s> edge was read after its %s was destroyed\n", msTypeInfoShownName(msHeader(p)->type), msTypeInfoShownName(msHeader(p)->type));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseCellTooLarge(size_t total) {
	msErrorf("Error: an object of %llu bytes is larger than the 2 GiB an object can be\n", (unsigned long long)total);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseUnownedOverflow(void* p) {
	msErrorf("Error: too many Unowned<%s> edges point at one %s\n", msTypeInfoShownName(msHeader(p)->type), msTypeInfoShownName(msHeader(p)->type));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseSliceError(int64_t start, int64_t end, int64_t len) {
	msErrorf("Error: slice %lld..%lld out of bounds (length %lld)\n",
		(long long)start, (long long)end, (long long)len);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseDivByZero(void) {
	msErrorf("Error: division by zero\n");
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseOverflow(void) {
	msErrorf("Error: over- or underflow\n");
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

/* Parity: standard reference range error handling */
_Noreturn void msRaiseRangeError(int64_t val, int64_t lo, int64_t hi) {
	msErrorf("Error: value %lld not in range %lld .. %lld\n",
		(long long)val, (long long)lo, (long long)hi);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseRangeErrorF(double val, int64_t lo, int64_t hi) {
	msString text = msNumberToString(val);
	msErrorf("Error: value %.*s not in range %lld .. %lld\n",
		(int)msStrLen(text), msStrData(&text), (long long)lo, (long long)hi);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseRangeErrorFToU64(double val) {
	msString text = msNumberToString(val);
	msErrorf("Error: value %.*s not in range 0 .. 18446744073709551615\n",
		(int)msStrLen(text), msStrData(&text));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseRangeErrorU64(uint64_t val, int64_t lo, int64_t hi) {
	msErrorf("Error: value %llu not in range %lld .. %lld\n",
		(unsigned long long)val, (long long)lo, (long long)hi);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseVariantError(int64_t tag, int64_t expected) {
	msErrorf("Error: invalid union conversion: value holds member %lld, target expects %lld\n",
		(long long)tag, (long long)expected);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseStrLitError(msString s, msString target) {
	msErrorf("Error: invalid union conversion: \"%.*s\" is not %.*s\n", (int)msStrLen(s), msStrData(&s),
		(int)msStrLen(target), msStrData(&target));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

msString msStrLitConv(msString s, msString members, msString target) {
	const char* list = msStrData(&members);
	const char* text = msStrData(&s);
	int64_t i = 0;
	while (i < msStrLen(members)) {
		int64_t n = 0;
		while (i < msStrLen(members) && list[i] != ':') {
			n = n * 10 + (list[i] - '0');
			i += 1;
		}
		i += 1;
		if (n == msStrLen(s) && i + n <= msStrLen(members) && memcmp(list + i, text, (size_t)n) == 0) return s;
		i += n;
	}
	msRaiseStrLitError(s, target);
}

_Noreturn void msRaiseNumLitError(double v, msString target) {
	msString shown = msNumberToString(v);
	msErrorf("Error: invalid union conversion: %.*s is not %.*s\n", (int)msStrLen(shown), msStrData(&shown),
		(int)msStrLen(target), msStrData(&target));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

double msNumLitConv(double v, const double* members, int64_t n, msString target) {
	for (int64_t i = 0; i < n; i += 1) {
		if (members[i] == v) return v;
	}
	msRaiseNumLitError(v, target);
}

_Noreturn void msRaiseUnreachable(const char* text) {
	msErrorf("Error: %s\n", text);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msRaiseFieldError(msString head, msString labels, int64_t tag) {
	const char* text = msStrData(&labels);
	int64_t start = 0;
	int64_t seen = 0;
	for (int64_t i = 0; i < msStrLen(labels) && seen < tag; i += 1) {
		if (text[i] == '|') { seen += 1; start = i + 1; }
	}
	int64_t end = start;
	while (end < msStrLen(labels) && text[end] != '|') end += 1;
	if (seen < tag || tag < 0) end = start;
	msErrorf("Error: %.*s%.*s'\n", (int)msStrLen(head), msStrData(&head),
		(int)(end - start), text + start);
	if (msFatalTrap != NULL) msFatalTrap();
	exit(1);
}

_Noreturn void msMapFatal(msString msg) {
	msErrorf("fatal error: %.*s\n",
		(int)msStrLen(msg), msStrData(&msg));
	if (msFatalTrap != NULL) msFatalTrap();
	exit(2);
}

__attribute__((noinline)) void msStringCopy(msString* dest, msString src) {
	/* Identity: same pointer + same length = same string */
	if (msStrSameBuffer(*dest, src) && msStrLen(*dest) == msStrLen(src)) return;
	/* Shared payload (e.g. after bitwise copy): both point to same buffer.
	   Don't free — source still owns it. Must allocate a fresh independent copy. */
	if (msStrSameBuffer(*dest, src)) {
		*dest = msStringDup(src);
		return;
	}
	/* Source is literal (or interned char): shallow copy — pointer only */
	if (msStrNeedsNoFree(src)) {
		msStringDestroy(*dest);
		*dest = src;
		return;
	}
	/* Source is heap: try buffer reuse (reuse if capacity sufficient) */
	if (msStrIsHeap(*dest) && msStrCap(*dest) >= msStrLen(src)) {
		msStrSetLen(dest, msStrLen(src));
		memcpy(msStrWritable(dest), msStrData(&src), msStrLen(src) + 1);
		msStringInheritAscii(*dest, src);
		return;
	}
	/* Must allocate new buffer */
	msString newStr = msStrDupHeap(src);
	msStringDestroy(*dest);
	*dest = newStr;
}

#endif /* !MSOS_BARE || !MSGC_MANUAL */
