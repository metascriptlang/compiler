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
MS_THREAD_LOCAL msException* msCurrException = NULL;

/* Async future globals (declared extern in future.h) */
MS_THREAD_LOCAL msCallSoonFn msCallSoonProc = NULL;
MS_THREAD_LOCAL void* msErrPayload = NULL;

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
	msCurrException = NULL;
	exit(1);
}

void msFutureRaiseFrom(msFutureBase* f) {
	msErr = true;
	if (f != NULL) {
		atomic_store_explicit(&f->errorObserved, true, memory_order_relaxed);
		msClearOrphanFailure(f);
	}
	void* err = (f != NULL) ? f->error : NULL;
	if (err != NULL) {
		msCurrException = (msException*)err;
		f->error = NULL;
	} else {
		msCurrException = (msException*)msMakeError(msStringFromCStr("noproc"));
	}
	msErrPayload = (void*)msCurrException;
}

_Noreturn void msRaiseIndexError(int64_t idx, int64_t len) {
	fprintf(stderr, "Error: index %lld out of bounds (length %lld)\n",
		(long long)idx, (long long)len);
	exit(1);
}

/* Parity: standard reference range error handling */
_Noreturn void msRaiseRangeError(int64_t val, int64_t lo, int64_t hi) {
	fprintf(stderr, "Error: value %lld not in range %lld .. %lld\n",
		(long long)val, (long long)lo, (long long)hi);
	exit(1);
}

_Noreturn void msMapFatal(msString msg) {
	fprintf(stderr, "fatal error: %.*s\n",
		(int)msg.len, (msg.p != NULL) ? msg.p->data : "");
	exit(2);
}

#endif /* MSOS_BARE */
