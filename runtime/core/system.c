#include "runtime/core/system.h"

/* Under --os=bare, manual.h provides all functions inline via -include.
   Skip this entire file to avoid redefinitions. */
#ifndef MSOS_BARE

#include <stdio.h>
#include <stdlib.h>

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

void msPrintln(msString s) {
	if (s.p != NULL && s.len > 0) {
		fwrite(s.p->data, 1, s.len, stdout);
	}
	putchar('\n');
	fflush(stdout);
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
	msDecref((void*)msCurrException);
	msErr = false;
	msCurrException = NULL;
}

static void msErrorDestroy(void* p) {
	msError* e = (msError*)p;
	msStringDecref(e->message);
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
	e->message = message;
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

void msTestErrorFlag(void) {
	if (!msErr || msCurrException == NULL) return;
	msString m = ((msError*)msCurrException)->message;
	fputs("Error: unhandled exception: ", stderr);
	if (m.p != NULL && m.len > 0) fwrite(m.p->data, 1, (size_t)m.len, stderr);
	fputc('\n', stderr);
	msDecref((void*)msCurrException);
	msCurrException = NULL;
	exit(1);
}

void msRaiseAwaitedError(void* err) {
	msErr = true;
	msCurrException = err != NULL ? (msException*)err : (msException*)msMakeError(msStringFromCStr("noproc"));
	msErrPayload = (void*)msCurrException;
}

void msFutureRaiseFrom(msFutureBase* f) {
	if (f != NULL) {
		atomic_store_explicit(&f->errorObserved, true, memory_order_relaxed);
		msClearOrphanFailure(f);
	}
	void* err = (f != NULL) ? f->error : NULL;
	if (f != NULL) f->error = NULL;
	msRaiseAwaitedError(err);
}

_Noreturn void msRaiseIndexError(int64_t idx, int64_t len) {
	fprintf(stderr, "Error: index %lld out of bounds (length %lld)\n",
		(long long)idx, (long long)len);
	exit(1);
}

_Noreturn void msRaiseObjectConversionError(void* p, const msTypeInfo* target) {
	const msTypeInfo* t = msHeader(p)->type;
	fprintf(stderr, "Error: invalid object conversion: %s is not %s\n",
		(t != NULL && t->name != NULL) ? t->name : "<untyped>",
		target->name != NULL ? target->name : "<untyped>");
	exit(1);
}

_Noreturn void msRaiseSliceError(int64_t start, int64_t end, int64_t len) {
	fprintf(stderr, "Error: slice %lld..%lld out of bounds (length %lld)\n",
		(long long)start, (long long)end, (long long)len);
	exit(1);
}

_Noreturn void msRaiseDivByZero(void) {
	fprintf(stderr, "Error: division by zero\n");
	exit(1);
}

_Noreturn void msRaiseOverflow(void) {
	fprintf(stderr, "Error: over- or underflow\n");
	exit(1);
}

/* Parity: standard reference range error handling */
_Noreturn void msRaiseRangeError(int64_t val, int64_t lo, int64_t hi) {
	fprintf(stderr, "Error: value %lld not in range %lld .. %lld\n",
		(long long)val, (long long)lo, (long long)hi);
	exit(1);
}

_Noreturn void msRaiseRangeErrorF(double val, int64_t lo, int64_t hi) {
	if (val >= -9223372036854775808.0 && val < 9223372036854775808.0 && val == (double)(int64_t)val) {
		msRaiseRangeError((int64_t)val, lo, hi);
	}
	fprintf(stderr, "Error: value %.17g not in range %lld .. %lld\n",
		val, (long long)lo, (long long)hi);
	exit(1);
}

_Noreturn void msRaiseStrLitError(msString s, msString target) {
	fprintf(stderr, "Error: invalid union conversion: \"%.*s\" is not %.*s\n", (int)s.len, s.p != NULL ? s.p->data : "",
		(int)target.len, target.p != NULL ? target.p->data : "");
	exit(1);
}

msString msStrLitConv(msString s, msString members, msString target) {
	const char* list = members.p != NULL ? members.p->data : "";
	const char* text = s.p != NULL ? s.p->data : "";
	int64_t i = 0;
	while (i < members.len) {
		int64_t n = 0;
		while (i < members.len && list[i] != ':') {
			n = n * 10 + (list[i] - '0');
			i += 1;
		}
		i += 1;
		if (n == s.len && i + n <= members.len && memcmp(list + i, text, (size_t)n) == 0) return s;
		i += n;
	}
	msRaiseStrLitError(s, target);
}

_Noreturn void msRaiseFieldError(msString head, msString labels, int64_t tag) {
	const char* text = labels.p != NULL ? labels.p->data : "";
	int64_t start = 0;
	int64_t seen = 0;
	for (int64_t i = 0; i < labels.len && seen < tag; i += 1) {
		if (text[i] == '|') { seen += 1; start = i + 1; }
	}
	int64_t end = start;
	while (end < labels.len && text[end] != '|') end += 1;
	if (seen < tag || tag < 0) end = start;
	fprintf(stderr, "Error: %.*s%.*s'\n", (int)head.len, head.p != NULL ? head.p->data : "",
		(int)(end - start), text + start);
	exit(1);
}

_Noreturn void msMapFatal(msString msg) {
	fprintf(stderr, "fatal error: %.*s\n",
		(int)msg.len, (msg.p != NULL) ? msg.p->data : "");
	exit(2);
}

#endif /* MSOS_BARE */
