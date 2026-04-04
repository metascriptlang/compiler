#include "runtime/core/system.h"

/* Under --os=bare, manual.h provides all functions inline via -include.
   Skip this entire file to avoid redefinitions. */
#ifndef MS_BARE

#include <stdio.h>
#include <stdlib.h>

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

static msException __staticException;

void msThrow(msString msg) {
	__staticException.message = (msg.p != NULL) ? msg.p->data : "";
	__staticException.code = 1;
	msCurrException = &__staticException;
	msErr = true;
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

#endif /* MS_BARE */
