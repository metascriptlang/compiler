#include "system.h"
#include <stdio.h>
#include <stdlib.h>

/* DRC / exception globals */
bool msErr = false;
msException* msCurrException = NULL;

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
