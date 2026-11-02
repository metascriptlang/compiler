/*
 * MetaScript String Runtime — Implementation
 * Following the standard reference string patterns.
 */

#include "runtime/core/system.h"
#include "runtime/core/array.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include <math.h>

/* ===== Single-Char Interning Table (zero-alloc s[i]) ===== */

#define MS_CHAR_CAP (MS_STRLIT_FLAG | MS_ASCII_CHECKED | MS_ASCII_FLAG | 1)
#define MS_CP(c) { MS_CHAR_CAP, { (char)(c), '\0' } }
#define MS_CP_ROW(b) MS_CP(b), MS_CP((b)+1), MS_CP((b)+2), MS_CP((b)+3), \
	MS_CP((b)+4), MS_CP((b)+5), MS_CP((b)+6), MS_CP((b)+7)

static const struct { int64_t cap; char data[2]; } msCharPayloads[128] = {
	MS_CP_ROW(0),   MS_CP_ROW(8),   MS_CP_ROW(16),  MS_CP_ROW(24),
	MS_CP_ROW(32),  MS_CP_ROW(40),  MS_CP_ROW(48),  MS_CP_ROW(56),
	MS_CP_ROW(64),  MS_CP_ROW(72),  MS_CP_ROW(80),  MS_CP_ROW(88),
	MS_CP_ROW(96),  MS_CP_ROW(104), MS_CP_ROW(112), MS_CP_ROW(120)
};

#define MS_CS(c) { 1, (msStrPayload*)&msCharPayloads[c] }
#define MS_CS_ROW(b) MS_CS(b), MS_CS((b)+1), MS_CS((b)+2), MS_CS((b)+3), \
	MS_CS((b)+4), MS_CS((b)+5), MS_CS((b)+6), MS_CS((b)+7)

const msString msCharTable[128] = {
	MS_CS_ROW(0),   MS_CS_ROW(8),   MS_CS_ROW(16),  MS_CS_ROW(24),
	MS_CS_ROW(32),  MS_CS_ROW(40),  MS_CS_ROW(48),  MS_CS_ROW(56),
	MS_CS_ROW(64),  MS_CS_ROW(72),  MS_CS_ROW(80),  MS_CS_ROW(88),
	MS_CS_ROW(96),  MS_CS_ROW(104), MS_CS_ROW(112), MS_CS_ROW(120)
};

/* ===== Internal Allocation Helpers ===== */

static void checkCap(int64_t cap) {
	if (cap < 0 || cap > MS_LEN_MAX) msRaiseRangeError(cap, 0, MS_LEN_MAX);
}

static msStrPayload* allocPayload(int64_t cap) {
	checkCap(cap);
	msStrPayload* p = (msStrPayload*)msMemAlloc(msStrContentSize(cap));
	p->cap = cap;
	return p;
}

static msStrPayload* allocPayload0(int64_t cap) {
	checkCap(cap);
	msStrPayload* p = (msStrPayload*)msMemAlloc0(msStrContentSize(cap));
	p->cap = cap;
	return p;
}

static msStrPayload* reallocPayload(msStrPayload* old, int64_t oldCap, int64_t newCap) {
	checkCap(newCap);
	msStrPayload* p = (msStrPayload*)msRealloc(old, msStrContentSize(oldCap), msStrContentSize(newCap));
	p->cap = newCap;
	return p;
}

/* ===== ASCII cache invariant =====
   The cached answer describes the payload's CURRENT bytes, so any in-place
   content change must retract it. Gateways (PrepareAdd, Clear) retract;
   appenders re-derive by composition (ascii(a ++ b) = ascii(a) and ascii(b)).
   Retracting too often only costs a rescan; keeping a stale bit makes .length
   lie. Literal payloads are never written — their bytes cannot change, and they
   may live in .rodata. */

/* Answer for the SOURCE of an append without writing to it: the cached bit when
   present, else a scan bounded by the appended chunk (so a build loop stays
   linear overall). Deciding the destination the same way would rescan the whole
   accumulator on every append — quadratic — so the destination only ever uses
   its cached bit. */
static inline bool msStrScanAscii(const msStrPayload* p, int64_t len) {
	if (p == NULL || len == 0) return true;
	const int64_t cap = msStrCapLoad(p);
	if ((cap & MS_ASCII_CHECKED) != 0) return (cap & MS_ASCII_FLAG) != 0;
	for (int64_t i = 0; i < len; i++) {
		if ((unsigned char)p->data[i] >= 0x80) return false;
	}
	return true;
}

static inline void msStrInvalidateAscii(msStrPayload* p) {
	if (p != NULL && (p->cap & MS_STRLIT_FLAG) == 0) {
		p->cap &= ~(MS_ASCII_CHECKED | MS_ASCII_FLAG);
	}
}

/* ===== Lifecycle ===== */

msString msStringNew(const char* data, int64_t len) {
	if (len <= 0) return MS_EMPTY_STRING;
	msStrPayload* p = allocPayload(len);
	memcpy(p->data, data, len);
	p->data[len] = '\0';
	return (msString){ .len = len, .p = p };
}

msString msStringFromCStr(const char* cstr) {
	if (cstr == NULL) return MS_EMPTY_STRING;
	int64_t len = (int64_t)strlen(cstr);
	return msStringNew(cstr, len);
}

msString msStringNewCap(int64_t cap) {
	if (cap <= 0) return MS_EMPTY_STRING;
	msStrPayload* p = allocPayload(cap);
	p->data[0] = '\0';
	return (msString){ .len = 0, .p = p };
}

msString msStringNewLen(int64_t len) {
	if (len <= 0) return MS_EMPTY_STRING;
	msStrPayload* p = allocPayload0(len);
	return (msString){ .len = len, .p = p };
}

void msStringPrepareAdd(msString* s, int64_t addLen) {
	int64_t newLen = s->len + addLen;
	if (msStrNeedsNoFree(*s)) {
		msStrPayload* oldP = s->p;
		s->p = allocPayload(newLen);
		s->p->cap = newLen;
		if (s->len > 0) {
			memcpy(s->p->data, oldP->data, s->len < newLen ? s->len : newLen);
		} else if (oldP == NULL) {
			s->p->data[0] = '\0';
		}
	} else {
		int64_t oldCap = s->p->cap & MS_CAP_MASK;
		if (newLen > oldCap) {
			int64_t newCap = newLen;
			int64_t resized = msStringResizeCap(oldCap);
			if (resized > newCap) newCap = resized;
			s->p = reallocPayload(s->p, oldCap, newCap);
			/* Zero tail after growth — standard reference patterns */
			if (s->p && newCap > s->len) {
				memset(s->p->data + s->len + 1, 0, newCap - s->len);
			}
		}
	}
	msStrInvalidateAscii(s->p);
}

void msStringAppendSlow(msString* dest, msString src) {
	if (src.len > 0) {
		/* Self-append (`s = s + s`, `s += s`): stringOpLower rewrites self-first concat to an
		   in-place append, so src may alias dest. msStringPrepareAdd can realloc dest's payload,
		   freeing the buffer src points at — read the preserved bytes from dest's grown buffer
		   (prepareAdd copies existing content forward), like std::string::append(*this). */
		int aliased = (src.p == dest->p);
		bool destKnown = dest->len == 0 || (dest->p != NULL && (dest->p->cap & MS_ASCII_CHECKED) != 0);
		bool destAscii = dest->len == 0 || msStringKnownAscii(*dest);
		bool srcAscii = msStrScanAscii(src.p, src.len);
		msStringPrepareAdd(dest, src.len);
		const char* srcData = aliased ? dest->p->data : src.p->data;
		memcpy(dest->p->data + dest->len, srcData, src.len);
		dest->len += src.len;
		dest->p->data[dest->len] = '\0';
		if (!srcAscii || (destKnown && !destAscii)) msStringMarkNonAscii(*dest);
		else if (destKnown) msStringMarkAscii(*dest);
	}
}

void msStringAppendCharSlow(msString* dest, char c) {
	bool destKnown = dest->len == 0 || (dest->p != NULL && (dest->p->cap & MS_ASCII_CHECKED) != 0);
	bool destAscii = dest->len == 0 || msStringKnownAscii(*dest);
	bool cAscii = (unsigned char)c < 0x80;
	msStringPrepareAdd(dest, 1);
	dest->p->data[dest->len] = c;
	dest->len++;
	dest->p->data[dest->len] = '\0';
	if (!cAscii || (destKnown && !destAscii)) msStringMarkNonAscii(*dest);
	else if (destKnown) msStringMarkAscii(*dest);
}

void msStringClear(msString* s) {
	if (s->p != NULL && (s->p->cap & MS_STRLIT_FLAG) == 0) {
		s->p->data[0] = '\0';
		msStrInvalidateAscii(s->p);
	}
	s->len = 0;
}

/* ===== Comparison ===== */

bool msStringEquals(msString a, msString b) {
	if (msStrLen(a) != msStrLen(b)) return false;
	if (msStrIsEmpty(a)) return true;
	if (msStrSameBuffer(a, b)) return true;
	return memcmp(msStrData(&a), msStrData(&b), msStrLen(a)) == 0;
}

/* ===== Extraction ===== */

/* ---- Byte-level access (for lexer, hashing, protocol parsing) ---- */


/* ===== Transformation ===== */

/* ===== Building ===== */

void msStringAppendArr(msString* dest, const msString* arr, int64_t count) {
	/* Multi-part self-append (`s = s + mid + s`): an element may alias dest's ORIGINAL
	   payload. msStringAppend's own self-guard only catches an element that still equals
	   dest->p — but a prior element's append can realloc dest, freeing the buffer a LATER
	   aliased element points at (its pointer no longer equals the moved dest->p). Snapshot
	   the original content once and serve every original-aliased element from the snapshot. */
	const msStrPayload* origP = dest->p;
	int anyAlias = 0;
	for (int64_t i = 0; i < count; i++) {
		if (arr[i].len > 0 && arr[i].p == origP) { anyAlias = 1; break; }
	}
	if (!anyAlias) {
		for (int64_t i = 0; i < count; i++) msStringAppend(dest, arr[i]);
		return;
	}
	msString snap = msStringNew(dest->p->data, dest->len);
	for (int64_t i = 0; i < count; i++) {
		if (arr[i].len > 0 && arr[i].p == origP) {
			msString view = { .len = arr[i].len, .p = snap.p };
			msStringAppend(dest, view);
		} else {
			msStringAppend(dest, arr[i]);
		}
	}
	msStringDecref(snap);
}

/* ===== Splitting & Joining ===== */

/* ===== Parsing ===== */

#ifndef MSOS_SOLANA
double msStringParseFloat(msString s) {
	if (msStrIsEmpty(s)) return 0.0;
	return strtod(msStrData(&s), NULL);
}
#endif

