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

/* Zeroing realloc — zeros only [oldCap+1..newCap) region.
   Standard reference implementation: reallocPayload0(old, contentSize(oldLen), contentSize(newLen)) */
static msStrPayload* reallocPayload0(msStrPayload* old, int64_t oldCap, int64_t newCap) {
	checkCap(newCap);
	msStrPayload* p = (msStrPayload*)msRealloc(old, msStrContentSize(oldCap), msStrContentSize(newCap));
	p->cap = newCap;
	if (newCap > oldCap) {
		memset(p->data + oldCap + 1, 0, newCap - oldCap);
	}
	return p;
}

/* ===== ASCII cache invariant =====
   The cached answer describes the payload's CURRENT bytes, so any in-place
   content change must retract it. Gateways (PrepareAdd/PrepareMutation) retract;
   appenders re-derive by composition (ascii(a ++ b) = ascii(a) and ascii(b)).
   Retracting too often only costs a rescan; keeping a stale bit makes .length
   lie. Literal payloads are never written — their bytes cannot change, and they
   may live in .rodata. */

static inline bool msStrKnownAscii(const msStrPayload* p) {
	if (p == NULL) return false;
	const int64_t cap = msStrCapLoad(p);
	return (cap & MS_ASCII_CHECKED) != 0 && (cap & MS_ASCII_FLAG) != 0;
}

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

static int64_t msUtf8WellFormedStep(const unsigned char* s, int64_t i, int64_t n) {
	unsigned char b = s[i];
	if (b < 0x80) return 1;
	int need;
	unsigned char lo = 0x80, hi = 0xBF;
	if (b >= 0xC2 && b <= 0xDF) need = 1;
	else if (b >= 0xE0 && b <= 0xEF) { need = 2; if (b == 0xE0) lo = 0xA0; else if (b == 0xED) hi = 0x9F; }
	else if (b >= 0xF0 && b <= 0xF4) { need = 3; if (b == 0xF0) lo = 0x90; else if (b == 0xF4) hi = 0x8F; }
	else return -1;
	int64_t j = i + 1;
	for (int k = 0; k < need; k++, j++) {
		if (j >= n || s[j] < lo || s[j] > hi) return -(j - i);
		lo = 0x80;
		hi = 0xBF;
	}
	return j - i;
}

msString msStringFromUtf8Lossy(const char* data, int64_t n) {
	if (n <= 0) return MS_EMPTY_STRING;
	const unsigned char* s = (const unsigned char*)data;
	bool ascii = true;
	int64_t i = 0;
	while (i < n) {
		if (s[i] < 0x80) { i++; continue; }
		ascii = false;
		int64_t k = msUtf8WellFormedStep(s, i, n);
		if (k < 0) break;
		i += k;
	}
	if (i == n) {
		msString whole = msStringNew(data, n);
		if (ascii) msStrMarkAscii(whole.p); else msStrMarkNonAscii(whole.p);
		return whole;
	}
	msStrPayload* p = allocPayload(n * 3);
	memcpy(p->data, s, (size_t)i);
	int64_t o = i;
	while (i < n) {
		int64_t k = msUtf8WellFormedStep(s, i, n);
		if (k > 0) {
			memcpy(p->data + o, s + i, (size_t)k);
			o += k;
			i += k;
		} else {
			p->data[o++] = (char)0xEF;
			p->data[o++] = (char)0xBF;
			p->data[o++] = (char)0xBD;
			i -= k;
		}
	}
	p->data[o] = '\0';
	msStrMarkNonAscii(p);
	return (msString){ .len = o, .p = p };
}

msString msStringFromLatin1(const char* data, int64_t n) {
	if (n <= 0) return MS_EMPTY_STRING;
	const unsigned char* s = (const unsigned char*)data;
	int64_t high = 0;
	for (int64_t i = 0; i < n; i++) high += s[i] >> 7;
	msStrPayload* p = allocPayload(n + high);
	int64_t o = 0;
	for (int64_t i = 0; i < n; i++) {
		if (s[i] < 0x80) {
			p->data[o++] = (char)s[i];
		} else {
			p->data[o++] = (char)(0xC0 | (s[i] >> 6));
			p->data[o++] = (char)(0x80 | (s[i] & 0x3F));
		}
	}
	p->data[o] = '\0';
	if (high == 0) msStrMarkAscii(p); else msStrMarkNonAscii(p);
	return (msString){ .len = o, .p = p };
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

void msStringPrepareMutation(msString* s) {
	if (s->p != NULL && (s->p->cap & MS_STRLIT_FLAG) != 0) {
		msStrPayload* oldP = s->p;
		s->p = allocPayload(s->len);
		s->p->cap = s->len;
		memcpy(s->p->data, oldP->data, s->len + 1);
	}
	msStrInvalidateAscii(s->p);
}

void msStringPrepareAdd(msString* s, int64_t addLen) {
	int64_t newLen = s->len + addLen;
	if (msIsLiteral(*s)) {
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
		bool destAscii = dest->len == 0 || msStrKnownAscii(dest->p);
		bool srcAscii = msStrScanAscii(src.p, src.len);
		msStringPrepareAdd(dest, src.len);
		const char* srcData = aliased ? dest->p->data : src.p->data;
		memcpy(dest->p->data + dest->len, srcData, src.len);
		dest->len += src.len;
		dest->p->data[dest->len] = '\0';
		if (!srcAscii || (destKnown && !destAscii)) msStrMarkNonAscii(dest->p);
		else if (destKnown) msStrMarkAscii(dest->p);
	}
}

void msStringAppendCharSlow(msString* dest, char c) {
	bool destKnown = dest->len == 0 || (dest->p != NULL && (dest->p->cap & MS_ASCII_CHECKED) != 0);
	bool destAscii = dest->len == 0 || msStrKnownAscii(dest->p);
	bool cAscii = (unsigned char)c < 0x80;
	msStringPrepareAdd(dest, 1);
	dest->p->data[dest->len] = c;
	dest->len++;
	dest->p->data[dest->len] = '\0';
	if (!cAscii || (destKnown && !destAscii)) msStrMarkNonAscii(dest->p);
	else if (destKnown) msStrMarkAscii(dest->p);
}

void msStringSetLength(msString* s, int64_t newLen) {
	if (newLen == 0) {
		/* Don't free — common pattern: s.setLen(0) to reuse buffer */
	} else {
		if (msIsLiteral(*s)) {
			msStrPayload* oldP = s->p;
			s->p = allocPayload(newLen);
			s->p->cap = newLen;
			if (s->len > 0) {
				int64_t copyLen = s->len < newLen ? s->len : newLen;
				memcpy(s->p->data, oldP->data, copyLen);
				if (newLen > s->len) {
					memset(s->p->data + s->len, 0, newLen - s->len + 1);
				} else {
					s->p->data[newLen] = '\0';
				}
			} else {
				memset(s->p->data, 0, newLen + 1);
			}
		} else if (newLen > s->len) {
			int64_t oldCap = s->p->cap & MS_CAP_MASK;
			if (newLen > oldCap) {
				int64_t newCap = newLen;
				int64_t resized = msStringResizeCap(oldCap);
				if (resized > newCap) newCap = resized;
				s->p = reallocPayload0(s->p, oldCap, newCap);
			}
			memset(s->p->data + s->len, 0, newLen - s->len);
		}
		if (s->p) s->p->data[newLen] = '\0';
		msStrInvalidateAscii(s->p);
	}
	s->len = newLen;
}

/* ===== Comparison ===== */

bool msStringEquals(msString a, msString b) {
	if (a.len != b.len) return false;
	if (a.len == 0) return true;
	if (a.p == b.p) return true;
	return memcmp(a.p->data, b.p->data, a.len) == 0;
}

int msStringCompareBytes(msString a, msString b) {
	if (a.p == b.p && a.len == b.len) return 0;
	int64_t minLen = a.len < b.len ? a.len : b.len;
	if (minLen > 0) {
		const char* ad = a.p ? a.p->data : "";
		const char* bd = b.p ? b.p->data : "";
		int cmp = memcmp(ad, bd, minLen);
		if (cmp != 0) return cmp;
	}
	if (a.len < b.len) return -1;
	if (a.len > b.len) return 1;
	return 0;
}

/* UTF-16 code unit order (TypeScript string ordering). It differs from UTF-8 byte order only where
   the first differing code points are a supplementary one (lead 0xF0..0xF4, surrogate pair) against
   a BMP one at or above U+E000 (lead 0xEE/0xEF): the pair sorts below. */
int msStringCompare(msString a, msString b) {
	if (a.p == b.p && a.len == b.len) return 0;
	int64_t minLen = a.len < b.len ? a.len : b.len;
	if (minLen > 0) {
		const unsigned char* ad = (const unsigned char*)(a.p ? a.p->data : "");
		const unsigned char* bd = (const unsigned char*)(b.p ? b.p->data : "");
		int64_t i = 0;
		while (i + 8 <= minLen) {
			uint64_t wa, wb;
			memcpy(&wa, ad + i, 8);
			memcpy(&wb, bd + i, 8);
			if (wa != wb) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && defined(__GNUC__)
				i += __builtin_ctzll(wa ^ wb) >> 3;
#endif
				break;
			}
			i += 8;
		}
		while (i < minLen && ad[i] == bd[i]) i++;
		if (i < minLen) {
			unsigned char x = ad[i], y = bd[i];
			if (x >= 0xF0 && (y == 0xEE || y == 0xEF)) return -1;
			if (y >= 0xF0 && (x == 0xEE || x == 0xEF)) return 1;
			return x < y ? -1 : 1;
		}
	}
	if (a.len < b.len) return -1;
	if (a.len > b.len) return 1;
	return 0;
}

/* ===== Extraction ===== */

/* ---- Byte-level access (for lexer, hashing, protocol parsing) ---- */

int64_t msStringByteAt(msString s, int64_t idx) {
	if (idx < 0 || idx >= s.len || s.p == NULL) return -1;
	return (int64_t)(unsigned char)s.p->data[idx];
}

/* Byte-level slice: direct byte offsets into the underlying buffer.
 * Used by lexer, hashing, protocol parsing via .byteSlice() extension. */
msString msStringByteSlice(msString s, int64_t start, int64_t end) {
	if (start < 0) start = s.len + start;
	if (end < 0) end = s.len + end;
	if (start < 0) start = 0;
	if (end > s.len) end = s.len;
	if (start >= end || s.p == NULL) return MS_EMPTY_STRING;
	msString slice = msStringNew(s.p->data + start, end - start);
	if (msStrKnownAscii(s.p)) msStrMarkAscii(slice.p);
	return slice;
}

/* ===== Transformation ===== */

/* ===== Length (Encoding-Aware) ===== */

/* Count UTF-16 code units — TypeScript .length parity.
   UTF-8 lead byte patterns:
   0xxxxxxx = 1-byte (ASCII) → 1 UTF-16 unit
   110xxxxx = 2-byte → 1 UTF-16 unit
   1110xxxx = 3-byte → 1 UTF-16 unit (BMP)
   11110xxx = 4-byte → 2 UTF-16 units (surrogate pair) */
/* Stride-1 on purpose: a lead-byte skip loop (p += 1/2/3/4) gets if-converted
   to csel under LTO, serializing every step on the load (~6x). With a fixed
   advance there is nothing to serialize. Each codepoint counts via its lead
   byte; a 4-byte lead adds one more for the surrogate pair. */
__attribute__((noinline))
static int64_t msStringLengthWalk(const unsigned char* p, int64_t len) {
	int64_t count = 0;
	for (int64_t i = 0; i < len; i++) {
		unsigned char c = p[i];
		count += ((c & 0xC0) != 0x80);
		count += (c >= 0xF0);
	}
	return count;
}

int64_t msStringLength(msString s) {
	if (s.len == 0 || s.p == NULL) return 0;
	if (msStringIsAscii(s)) return s.len;  /* O(1) for ASCII strings */
	return msStringLengthWalk((const unsigned char*)s.p->data, s.len);
}

/* ===== Building ===== */

msString msStringConcat(msString a, msString b) {
	if (a.len == 0 && b.len == 0) return MS_EMPTY_STRING;
	if (a.len == 0) return msStringNew(b.p->data, b.len);
	if (b.len == 0) return msStringNew(a.p->data, a.len);

	int64_t totalLen = a.len + b.len;
	msString result = msStringNewCap(totalLen);
	memcpy(result.p->data, a.p->data, a.len);
	memcpy(result.p->data + a.len, b.p->data, b.len);
	result.len = totalLen;
	result.p->data[totalLen] = '\0';
	return result;
}

msString msStringConcatArr(const msString* arr, int64_t count) {
	if (count <= 0) return MS_EMPTY_STRING;

	int64_t totalLen = 0;
	for (int64_t i = 0; i < count; i++) totalLen += arr[i].len;
	if (totalLen == 0) return MS_EMPTY_STRING;

	msString result = msStringNewCap(totalLen);
	int64_t pos = 0;
	for (int64_t i = 0; i < count; i++) {
		if (arr[i].len > 0 && arr[i].p != NULL) {
			memcpy(result.p->data + pos, arr[i].p->data, arr[i].len);
			pos += arr[i].len;
		}
	}
	result.len = totalLen;
	result.p->data[totalLen] = '\0';
	return result;
}

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

void msStringSetChar(msString* s, int64_t idx, msString ch) {
	if (idx < 0 || idx >= s->len || s->p == NULL) return;
	msStringPrepareMutation(s);
	if (ch.len > 0 && ch.p != NULL) {
		s->p->data[idx] = ch.p->data[0];
	} else {
		s->p->data[idx] = '\0';
	}
}

/* ===== Splitting & Joining ===== */

/* ===== Parsing ===== */

#ifndef MSOS_SOLANA
double msStringParseFloat(msString s) {
	if (s.len == 0 || s.p == NULL) return 0.0;
	/* Ensure null-terminated (it should be, but be safe) */
	return strtod(s.p->data, NULL);
}
#endif

/* ===== Capacity ===== */

int64_t msStringCapacity(msString s) {
	if (s.p == NULL) return 0;
	return msStrCapLoad(s.p) & MS_CAP_MASK;
}

/* ===== In-Place Operations (Standard reference patterns) ===== */

void msStringSetSlice(msString* s, int64_t start, int64_t end) {
	if (start < 0) start = 0;
	if (end > s->len) end = s->len;
	if (start >= end) {
		s->len = 0;
		if (msIsLiteral(*s)) {
			s->p = NULL;
		} else {
			s->p->data[0] = '\0';
		}
		return;
	}
	int64_t newLen = end - start;
	if (start > 0 || msIsLiteral(*s)) {
		msStringPrepareMutation(s);
	}
	if (start > 0) {
		memmove(s->p->data, s->p->data + start, newLen);
	}
	s->len = newLen;
	s->p->data[newLen] = '\0';
}

void msStringStripInPlace(msString* s) {
	if (s->len == 0 || s->p == NULL) return;
	int64_t first = 0;
	int64_t last = s->len - 1;
	while (first <= last && isspace((unsigned char)s->p->data[first])) first++;
	while (last >= first && isspace((unsigned char)s->p->data[last])) last--;
	msStringSetSlice(s, first, last + 1);
}
