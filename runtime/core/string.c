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

static struct { int64_t cap; char data[2]; } msCharPayloads[128];
msString msCharTable[128];
static bool msCharTableInit = false;

void msEnsureCharTable(void) {
	if (msCharTableInit) return;
	for (int i = 0; i < 128; i++) {
		msCharPayloads[i].cap = MS_STRLIT_FLAG | 1;
		msCharPayloads[i].data[0] = (char)i;
		msCharPayloads[i].data[1] = '\0';
		msCharTable[i].len = 1;
		msCharTable[i].p = (msStrPayload*)&msCharPayloads[i];
	}
	msCharTableInit = true;
}

/* Auto-initialize at program start — avoids branch in hot path */
__attribute__((constructor))
static void msCharTableAutoInit(void) {
	msEnsureCharTable();
}

/* ===== Internal Allocation Helpers ===== */

static msStrPayload* allocPayload(int64_t cap) {
	msStrPayload* p = (msStrPayload*)malloc(msStrContentSize(cap));
	if (p) p->cap = cap;
	return p;
}

static msStrPayload* allocPayload0(int64_t cap) {
	msStrPayload* p = (msStrPayload*)calloc(1, msStrContentSize(cap));
	if (p) p->cap = cap;
	return p;
}

static msStrPayload* reallocPayload(msStrPayload* old, int64_t newCap) {
	msStrPayload* p = (msStrPayload*)realloc(old, msStrContentSize(newCap));
	if (p) p->cap = newCap;
	return p;
}

/* Zeroing realloc — zeros only [oldCap+1..newCap) region.
   Standard reference implementation: reallocPayload0(old, contentSize(oldLen), contentSize(newLen)) */
static msStrPayload* reallocPayload0(msStrPayload* old, int64_t oldCap, int64_t newCap) {
	msStrPayload* p = (msStrPayload*)realloc(old, msStrContentSize(newCap));
	if (p) {
		p->cap = newCap;
		if (newCap > oldCap) {
			memset(p->data + oldCap + 1, 0, newCap - oldCap);
		}
	}
	return p;
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

void msStringDestroy(msString s) {
	if (!msIsLiteral(s)) {
		free(s.p);
	}
}

void msStringAssign(msString* a, msString b) {
	if (a->p == b.p && a->len == b.len) return;
	if (msIsLiteral(b)) {
		/* Shallow copy for literals */
		if (!msIsLiteral(*a)) free(a->p);
		a->len = b.len;
		a->p = b.p;
	} else {
		if (msIsLiteral(*a) || (a->p->cap & MS_CAP_MASK) < b.len) {
			if (!msIsLiteral(*a)) free(a->p);
			a->p = allocPayload(b.len);
			a->p->cap = b.len;
		}
		a->len = b.len;
		memcpy(a->p->data, b.p->data, b.len + 1);
	}
}

void msStringPrepareMutation(msString* s) {
	if (s->p != NULL && (s->p->cap & MS_STRLIT_FLAG) != 0) {
		msStrPayload* oldP = s->p;
		s->p = allocPayload(s->len);
		s->p->cap = s->len;
		memcpy(s->p->data, oldP->data, s->len + 1);
	}
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
			s->p = reallocPayload(s->p, newCap);
			/* Zero tail after growth — standard reference patterns */
			if (s->p && newCap > s->len) {
				memset(s->p->data + s->len + 1, 0, newCap - s->len);
			}
		}
	}
}

void msStringAppend(msString* dest, msString src) {
	if (src.len > 0) {
		/* Self-append (`s = s + s`, `s += s`): stringOpLower rewrites self-first concat to an
		   in-place append, so src may alias dest. msStringPrepareAdd can realloc dest's payload,
		   freeing the buffer src points at — read the preserved bytes from dest's grown buffer
		   (prepareAdd copies existing content forward), like std::string::append(*this). */
		int aliased = (src.p == dest->p);
		msStringPrepareAdd(dest, src.len);
		const char* srcData = aliased ? dest->p->data : src.p->data;
		memcpy(dest->p->data + dest->len, srcData, src.len);
		dest->len += src.len;
		dest->p->data[dest->len] = '\0';
	}
}

void msStringAppendChar(msString* dest, char c) {
	msStringPrepareAdd(dest, 1);
	dest->p->data[dest->len] = c;
	dest->len++;
	dest->p->data[dest->len] = '\0';
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

bool msStringEqualsIgnoreCase(msString a, msString b) {
	if (a.len != b.len) return false;
	if (a.len == 0) return true;
	if (a.p == b.p) return true;
	for (int64_t i = 0; i < a.len; i++) {
		if (tolower((unsigned char)a.p->data[i]) != tolower((unsigned char)b.p->data[i]))
			return false;
	}
	return true;
}

int msStringCompare(msString a, msString b) {
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

bool msStringStartsWith(msString s, msString prefix) {
	if (prefix.len == 0) return true;
	if (prefix.len > s.len) return false;
	if (s.p == NULL) return false;
	return memcmp(s.p->data, prefix.p->data, prefix.len) == 0;
}

bool msStringEndsWith(msString s, msString suffix) {
	if (suffix.len == 0) return true;
	if (suffix.len > s.len) return false;
	if (s.p == NULL) return false;
	return memcmp(s.p->data + s.len - suffix.len, suffix.p->data, suffix.len) == 0;
}

static int64_t msStringByteIndexOf(msString s, msString sub, int64_t byteStart);

bool msStringContains(msString s, msString sub) {
	if (sub.len == 0) return true;
	if (sub.len > s.len) return false;
	if (s.p == NULL) return false;
	return msStringByteIndexOf(s, sub, 0) >= 0;
}

/* ===== Search ===== */

/* Internal byte-based indexOf — for C runtime use (replace, split, count).
 * start and return value are byte offsets. */
static int64_t msStringByteIndexOf(msString s, msString sub, int64_t byteStart) {
	if (sub.len == 0) return byteStart <= s.len ? byteStart : -1;
	if (byteStart < 0) byteStart = 0;
	if (sub.len > s.len || s.p == NULL) return -1;
	const char* haystack = s.p->data;
	const char* needle = sub.p->data;
	int64_t limit = s.len - sub.len;
	for (int64_t i = byteStart; i <= limit; i++) {
		if (memcmp(haystack + i, needle, sub.len) == 0) {
			return i;
		}
	}
	return -1;
}

/* Public char-based indexOf — JavaScript/TypeScript semantics.
 * start and return value are char positions (UTF-16 code units). */
int64_t msStringIndexOf(msString s, msString sub, int64_t start) {
	if (sub.len == 0) return start <= s.len ? start : -1;
	if (start < 0) start = 0;
	if (sub.len > s.len || s.p == NULL) return -1;

	/* ASCII fast path: byte positions == char positions */
	if (msStringIsAscii(s)) {
		return msStringByteIndexOf(s, sub, start);
	}

	/* Non-ASCII: walk by UTF-8 chars, return char position. */
	const unsigned char* haystack = (const unsigned char*)s.p->data;
	const unsigned char* pend = haystack + s.len;
	const unsigned char* p = haystack;
	int64_t charPos = 0;

	/* Advance to start char position */
	while (p < pend && charPos < start) {
		unsigned char b = *p;
		if (b < 0x80) p++;
		else if (b < 0xE0) p += 2;
		else if (b < 0xF0) p += 3;
		else { p += 4; charPos++; } /* surrogate pair = 2 UTF-16 units */
		charPos++;
	}

	/* Search from current byte position, tracking char position */
	while (p + sub.len <= pend) {
		if (memcmp(p, (const unsigned char*)sub.p->data, sub.len) == 0) {
			return charPos;
		}
		unsigned char b = *p;
		if (b < 0x80) p++;
		else if (b < 0xE0) p += 2;
		else if (b < 0xF0) p += 3;
		else { p += 4; charPos++; }
		charPos++;
	}
	return -1;
}

int64_t msStringLastIndexOf(msString s, msString sub, int64_t startIdx) {
	if (sub.len == 0) return msStringIsAscii(s) ? s.len : msStringLength(s);
	if (sub.len > s.len || s.p == NULL) return -1;

	/* Determine start byte position for backward search */
	int64_t startByte = s.len - sub.len;
	if (startIdx >= 0 && msStringIsAscii(s) && startIdx < startByte) {
		startByte = startIdx;
	} else if (startIdx >= 0 && !msStringIsAscii(s)) {
		/* Convert char position to byte position for non-ASCII */
		const unsigned char* p = (const unsigned char*)s.p->data;
		int64_t bytePos = 0, charPos = 0;
		while (bytePos < s.len && charPos < startIdx) {
			unsigned char b = p[bytePos];
			if (b < 0x80) bytePos++;
			else if (b < 0xE0) bytePos += 2;
			else if (b < 0xF0) bytePos += 3;
			else bytePos += 4;
			charPos++;
		}
		if (bytePos < startByte) startByte = bytePos;
	}

	/* ASCII fast path */
	if (msStringIsAscii(s)) {
		const char* haystack = s.p->data;
		const char* needle = sub.p->data;
		for (int64_t i = startByte; i >= 0; i--) {
			if (memcmp(haystack + i, needle, sub.len) == 0) {
				return i;
			}
		}
		return -1;
	}

	/* Non-ASCII: find last byte match, convert to char position */
	const char* haystack = s.p->data;
	const char* needle = sub.p->data;
	int64_t lastBytePos = -1;
	for (int64_t i = startByte; i >= 0; i--) {
		if (memcmp(haystack + i, needle, sub.len) == 0) {
			lastBytePos = i;
			break;
		}
	}
	if (lastBytePos < 0) return -1;

	/* Convert byte position to char position */
	const unsigned char* p = (const unsigned char*)haystack;
	int64_t charPos = 0;
	int64_t bytePos = 0;
	while (bytePos < lastBytePos) {
		unsigned char b = p[bytePos];
		if (b < 0x80) bytePos++;
		else if (b < 0xE0) bytePos += 2;
		else if (b < 0xF0) bytePos += 3;
		else { bytePos += 4; charPos++; }
		charPos++;
	}
	return charPos;
}

int64_t msStringCount(msString s, msString sub) {
	if (sub.len == 0) return s.len + 1;
	int64_t count = 0;
	int64_t pos = 0;
	while (pos <= s.len - sub.len) {
		int64_t found = msStringByteIndexOf(s, sub, pos);
		if (found < 0) break;
		count++;
		pos = found + sub.len;
	}
	return count;
}

/* ===== Extraction ===== */

/* ---- Byte-level access (for lexer, hashing, protocol parsing) ---- */

int64_t msStringByteAt(msString s, int64_t idx) {
	if (idx < 0 || idx >= s.len || s.p == NULL) return -1;
	return (int64_t)(unsigned char)s.p->data[idx];
}

msString msStringByteCharAt(msString s, int64_t idx) {
	if (idx < 0 || idx >= s.len || s.p == NULL) return MS_EMPTY_STRING;
	unsigned char byte = (unsigned char)s.p->data[idx];
	if (byte < 128) {
		return msCharTable[byte];  /* interned — zero alloc */
	}
	return msStringNew(s.p->data + idx, 1);
}

/* ---- Character-level access (TypeScript parity, UTF-16 code unit indexed) ---- */

/* Helper: decode UTF-8 codepoint starting at p, return codepoint and advance p */
static uint32_t msUtf8Decode(const unsigned char* p, const unsigned char* end, int* seqlen) {
	unsigned char b = *p;
	if (b < 0x80) { *seqlen = 1; return b; }
	if (b < 0xE0 && p + 1 < end) {
		*seqlen = 2;
		return ((uint32_t)(b & 0x1F) << 6) | (p[1] & 0x3F);
	}
	if (b < 0xF0 && p + 2 < end) {
		*seqlen = 3;
		return ((uint32_t)(b & 0x0F) << 12) | ((uint32_t)(p[1] & 0x3F) << 6) | (p[2] & 0x3F);
	}
	if (p + 3 < end) {
		*seqlen = 4;
		return ((uint32_t)(b & 0x07) << 18) | ((uint32_t)(p[1] & 0x3F) << 12) |
		       ((uint32_t)(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
	}
	*seqlen = 1; /* invalid sequence, skip 1 byte */
	return 0xFFFD; /* replacement character */
}

msString msStringCharAt(msString s, int64_t idx) {
	if (idx < 0 || s.p == NULL || idx >= s.len) return MS_EMPTY_STRING;
	const unsigned char* p = (const unsigned char*)s.p->data;
	const unsigned char* end = p + s.len;
	/* ASCII fast path: O(1) when string is known ASCII (cached check) */
	if (msStringIsAscii(s)) {
		return msCharTable[p[idx]];  /* zero alloc — interned */
	}
	/* Full scan: find the idx-th UTF-16 code unit */
	int64_t charPos = 0;
	while (p < end) {
		int seqlen;
		uint32_t cp = msUtf8Decode(p, end, &seqlen);
		if (cp >= 0x10000) {
			/* Surrogate pair: 2 UTF-16 code units */
			if (charPos == idx || charPos + 1 == idx) {
				return msStringNew((const char*)(p), seqlen);
			}
			charPos += 2;
		} else {
			if (charPos == idx) {
				return msStringNew((const char*)(p), seqlen);
			}
			charPos++;
		}
		p += seqlen;
	}
	return MS_EMPTY_STRING;
}

int64_t msStringCharCodeAt(msString s, int64_t idx) {
	if (idx < 0 || s.p == NULL || idx >= s.len) return -1;
	const unsigned char* p = (const unsigned char*)s.p->data;
	/* ASCII fast path: O(1) when string is known ASCII (cached check) */
	if (msStringIsAscii(s)) {
		return (int64_t)p[idx];
	}
	/* Full scan: find the idx-th UTF-16 code unit */
	const unsigned char* end = p + s.len;
	int64_t charPos = 0;
	while (p < end) {
		int seqlen;
		uint32_t cp = msUtf8Decode(p, end, &seqlen);
		if (cp >= 0x10000) {
			/* Surrogate pair */
			uint32_t hi = 0xD800 + ((cp - 0x10000) >> 10);
			uint32_t lo = 0xDC00 + ((cp - 0x10000) & 0x3FF);
			if (charPos == idx) return (int64_t)hi;
			if (charPos + 1 == idx) return (int64_t)lo;
			charPos += 2;
		} else {
			if (charPos == idx) return (int64_t)cp;
			charPos++;
		}
		p += seqlen;
	}
	return -1;
}

msString msStringFromCodePoint(int64_t cp) {
	uint8_t buf[4];
	int len;
	if (cp < 0x80) {
		buf[0] = (uint8_t)cp;
		len = 1;
	} else if (cp < 0x800) {
		buf[0] = 0xC0 | (uint8_t)(cp >> 6);
		buf[1] = 0x80 | (uint8_t)(cp & 0x3F);
		len = 2;
	} else if (cp < 0x10000) {
		buf[0] = 0xE0 | (uint8_t)(cp >> 12);
		buf[1] = 0x80 | (uint8_t)((cp >> 6) & 0x3F);
		buf[2] = 0x80 | (uint8_t)(cp & 0x3F);
		len = 3;
	} else if (cp < 0x110000) {
		buf[0] = 0xF0 | (uint8_t)(cp >> 18);
		buf[1] = 0x80 | (uint8_t)((cp >> 12) & 0x3F);
		buf[2] = 0x80 | (uint8_t)((cp >> 6) & 0x3F);
		buf[3] = 0x80 | (uint8_t)(cp & 0x3F);
		len = 4;
	} else {
		/* Invalid codepoint — replacement character U+FFFD */
		buf[0] = 0xEF; buf[1] = 0xBF; buf[2] = 0xBD;
		len = 3;
	}
	return msStringNew((const char*)buf, len);
}

/* Byte-level slice: direct byte offsets into the underlying buffer.
 * Used by lexer, hashing, protocol parsing via .byteSlice() extension. */
msString msStringByteSlice(msString s, int64_t start, int64_t end) {
	if (start < 0) start = s.len + start;
	if (end < 0) end = s.len + end;
	if (start < 0) start = 0;
	if (end > s.len) end = s.len;
	if (start >= end || s.p == NULL) return MS_EMPTY_STRING;
	return msStringNew(s.p->data + start, end - start);
}

/* Character-level slice: TypeScript String.prototype.slice() parity.
 * Positions are UTF-16 code unit indices. ASCII fast path for O(1). */
msString msStringSlice(msString s, int64_t start, int64_t end) {
	if (s.p == NULL || s.len == 0) return MS_EMPTY_STRING;

	/* ASCII fast path: char positions == byte positions, skip msStringLength */
	if (msStringIsAscii(s)) {
		if (start < 0) start = s.len + start;
		if (end < 0) end = s.len + end;
		if (start < 0) start = 0;
		if (end > s.len) end = s.len;
		if (start >= end) return MS_EMPTY_STRING;
		return msStringNew(s.p->data + start, end - start);
	}

	int64_t charLen = msStringLength(s);

	/* Handle negative indices (from end) */
	if (start < 0) start = charLen + start;
	if (end < 0) end = charLen + end;
	if (start < 0) start = 0;
	if (end > charLen) end = charLen;
	if (start >= end) return MS_EMPTY_STRING;

	/* Full path: walk UTF-8 to find byte offsets for char positions */
	const unsigned char* data = (const unsigned char*)s.p->data;
	const unsigned char* p = data;
	const unsigned char* pend = data + s.len;
	int64_t charPos = 0;
	int64_t byteStart = -1, byteEnd = -1;

	while (p < pend && charPos <= end) {
		if (charPos == start) byteStart = (int64_t)(p - data);
		if (charPos == end) { byteEnd = (int64_t)(p - data); break; }

		unsigned char b = *p;
		int seqlen;
		if (b < 0x80) { seqlen = 1; }
		else if (b < 0xE0) { seqlen = 2; }
		else if (b < 0xF0) { seqlen = 3; }
		else { seqlen = 4; charPos++; } /* supplementary = 2 UTF-16 units */
		charPos++;
		p += seqlen;
	}

	if (byteStart < 0) return MS_EMPTY_STRING;
	if (byteEnd < 0) byteEnd = s.len; /* end beyond string → clamp to end */

	return msStringNew(s.p->data + byteStart, byteEnd - byteStart);
}

msString msStringSubstring(msString s, int64_t start, int64_t end) {
	return msStringSlice(s, start, end);
}

/* ===== Transformation ===== */

msString msStringToLower(msString s) {
	if (s.len == 0) return MS_EMPTY_STRING;
	msString result = msStringNew(s.p->data, s.len);
	for (int64_t i = 0; i < result.len; i++) {
		result.p->data[i] = (char)tolower((unsigned char)result.p->data[i]);
	}
	return result;
}

msString msStringToUpper(msString s) {
	if (s.len == 0) return MS_EMPTY_STRING;
	msString result = msStringNew(s.p->data, s.len);
	for (int64_t i = 0; i < result.len; i++) {
		result.p->data[i] = (char)toupper((unsigned char)result.p->data[i]);
	}
	return result;
}

msString msStringTrim(msString s) {
	if (s.len == 0 || s.p == NULL) return MS_EMPTY_STRING;
	int64_t start = 0;
	int64_t end = s.len;
	while (start < end && isspace((unsigned char)s.p->data[start])) start++;
	while (end > start && isspace((unsigned char)s.p->data[end - 1])) end--;
	if (start >= end) return MS_EMPTY_STRING;
	return msStringNew(s.p->data + start, end - start);
}

msString msStringTrimStart(msString s) {
	if (s.len == 0 || s.p == NULL) return MS_EMPTY_STRING;
	int64_t start = 0;
	while (start < s.len && isspace((unsigned char)s.p->data[start])) start++;
	if (start >= s.len) return MS_EMPTY_STRING;
	return msStringNew(s.p->data + start, s.len - start);
}

msString msStringTrimEnd(msString s) {
	if (s.len == 0 || s.p == NULL) return MS_EMPTY_STRING;
	int64_t end = s.len;
	while (end > 0 && isspace((unsigned char)s.p->data[end - 1])) end--;
	if (end <= 0) return MS_EMPTY_STRING;
	return msStringNew(s.p->data, end);
}

msString msStringRepeat(msString s, int64_t count) {
	if (count <= 0 || s.len == 0) return MS_EMPTY_STRING;
	if (count == 1) return msStringNew(s.p->data, s.len);

	int64_t totalLen = s.len * count;
	msString result = msStringNewCap(totalLen);
	for (int64_t i = 0; i < count; i++) {
		memcpy(result.p->data + i * s.len, s.p->data, s.len);
	}
	result.len = totalLen;
	result.p->data[totalLen] = '\0';
	return result;
}

msString msStringReplace(msString s, msString search, msString replacement) {
	if (s.len == 0 || search.len == 0) {
		return s.len > 0 ? msStringNew(s.p->data, s.len) : MS_EMPTY_STRING;
	}
	int64_t pos = msStringByteIndexOf(s, search, 0);
	if (pos < 0) {
		return msStringNew(s.p->data, s.len);
	}

	int64_t newLen = s.len - search.len + replacement.len;
	msString result = msStringNewCap(newLen);
	/* Before match */
	if (pos > 0) memcpy(result.p->data, s.p->data, pos);
	/* Replacement */
	if (replacement.len > 0) memcpy(result.p->data + pos, replacement.p->data, replacement.len);
	/* After match */
	int64_t afterStart = pos + search.len;
	int64_t afterLen = s.len - afterStart;
	if (afterLen > 0) memcpy(result.p->data + pos + replacement.len, s.p->data + afterStart, afterLen);

	result.len = newLen;
	result.p->data[newLen] = '\0';
	return result;
}

msString msStringReplaceAll(msString s, msString search, msString replacement) {
	if (s.len == 0 || search.len == 0) {
		return s.len > 0 ? msStringNew(s.p->data, s.len) : MS_EMPTY_STRING;
	}

	/* Count occurrences first to preallocate */
	int64_t count = msStringCount(s, search);
	if (count == 0) return msStringNew(s.p->data, s.len);

	int64_t newLen = s.len + count * (replacement.len - search.len);
	msString result = msStringNewCap(newLen);
	int64_t srcPos = 0;
	int64_t dstPos = 0;

	while (srcPos <= s.len - search.len) {
		int64_t found = msStringByteIndexOf(s, search, srcPos);
		if (found < 0) break;
		/* Copy segment before match */
		int64_t segLen = found - srcPos;
		if (segLen > 0) {
			memcpy(result.p->data + dstPos, s.p->data + srcPos, segLen);
			dstPos += segLen;
		}
		/* Copy replacement */
		if (replacement.len > 0) {
			memcpy(result.p->data + dstPos, replacement.p->data, replacement.len);
			dstPos += replacement.len;
		}
		srcPos = found + search.len;
	}
	/* Copy remainder */
	int64_t remaining = s.len - srcPos;
	if (remaining > 0) {
		memcpy(result.p->data + dstPos, s.p->data + srcPos, remaining);
		dstPos += remaining;
	}

	result.len = dstPos;
	result.p->data[dstPos] = '\0';
	return result;
}

msString msStringReverse(msString s) {
	if (s.len <= 1) {
		return s.len == 1 ? msStringNew(s.p->data, 1) : MS_EMPTY_STRING;
	}
	msString result = msStringNew(s.p->data, s.len);
	for (int64_t i = 0; i < s.len; i++) {
		result.p->data[i] = s.p->data[s.len - 1 - i];
	}
	return result;
}

msString msStringPadStart(msString s, int64_t targetLen, msString pad) {
	if (s.len >= targetLen) return msStringNew(s.p->data, s.len);
	if (pad.len == 0) return msStringNew(s.p->data, s.len);

	int64_t padTotal = targetLen - s.len;
	msString result = msStringNewCap(targetLen);
	int64_t pos = 0;
	while (pos < padTotal) {
		int64_t chunk = pad.len;
		if (pos + chunk > padTotal) chunk = padTotal - pos;
		memcpy(result.p->data + pos, pad.p->data, chunk);
		pos += chunk;
	}
	memcpy(result.p->data + padTotal, s.p->data, s.len);
	result.len = targetLen;
	result.p->data[targetLen] = '\0';
	return result;
}

msString msStringPadEnd(msString s, int64_t targetLen, msString pad) {
	if (s.len >= targetLen) return msStringNew(s.p->data, s.len);
	if (pad.len == 0) return msStringNew(s.p->data, s.len);

	int64_t padTotal = targetLen - s.len;
	msString result = msStringNewCap(targetLen);
	memcpy(result.p->data, s.p->data, s.len);
	int64_t pos = 0;
	while (pos < padTotal) {
		int64_t chunk = pad.len;
		if (pos + chunk > padTotal) chunk = padTotal - pos;
		memcpy(result.p->data + s.len + pos, pad.p->data, chunk);
		pos += chunk;
	}
	result.len = targetLen;
	result.p->data[targetLen] = '\0';
	return result;
}

/* ===== Length (Encoding-Aware) ===== */

/* Count UTF-16 code units — TypeScript .length parity.
   UTF-8 lead byte patterns:
   0xxxxxxx = 1-byte (ASCII) → 1 UTF-16 unit
   110xxxxx = 2-byte → 1 UTF-16 unit
   1110xxxx = 3-byte → 1 UTF-16 unit (BMP)
   11110xxx = 4-byte → 2 UTF-16 units (surrogate pair) */
int64_t msStringLength(msString s) {
	if (s.len == 0 || s.p == NULL) return 0;
	if (msStringIsAscii(s)) return s.len;  /* O(1) for ASCII strings */
	const unsigned char* p = (const unsigned char*)s.p->data;
	const unsigned char* end = p + s.len;
	int64_t count = 0;
	while (p < end) {
		unsigned char c = *p;
		if (c < 0x80) {
			p += 1;
			count += 1;
		} else if ((c & 0xE0) == 0xC0) {
			p += 2;
			count += 1;
		} else if ((c & 0xF0) == 0xE0) {
			p += 3;
			count += 1;
		} else {
			p += 4;
			count += 2; /* surrogate pair */
		}
	}
	return count;
}

/* Count Unicode scalar values (codepoints) */
int64_t msStringUnicodeLength(msString s) {
	if (s.len == 0 || s.p == NULL) return 0;
	const unsigned char* p = (const unsigned char*)s.p->data;
	const unsigned char* end = p + s.len;
	int64_t count = 0;
	while (p < end) {
		unsigned char c = *p;
		if (c < 0x80) p += 1;
		else if ((c & 0xE0) == 0xC0) p += 2;
		else if ((c & 0xF0) == 0xE0) p += 3;
		else p += 4;
		count += 1;
	}
	return count;
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

msString msIntToString(int64_t value) {
	char buf[32];
	int len = snprintf(buf, sizeof(buf), "%lld", (long long)value);
	return msStringNew(buf, len);
}

static int msShortestRoundTripDigits(double value, char* digits, int* decExp) {
	char sci[64];
	int prec = 0;
	for (; prec < 16; prec++) {
		snprintf(sci, sizeof(sci), "%.*e", prec, value);
		if (strtod(sci, NULL) == value) break;
	}
	if (prec == 16) snprintf(sci, sizeof(sci), "%.16e", value);
	const char* q = sci;
	int k = 0;
	digits[k++] = *q++;
	if (*q == '.') {
		q++;
		while (*q != 'e' && *q != 'E') digits[k++] = *q++;
	}
	while (*q != 'e' && *q != 'E') q++;
	*decExp = (int)strtol(q + 1, NULL, 10);
	while (k > 1 && digits[k - 1] == '0') k--;
	return k;
}

msString msNumberToString(double value) {
	char buf[64];
	if (isnan(value)) return msStringNew("NaN", 3);
	if (value == 0.0) return msStringNew("0", 1);
	if (isinf(value)) return value < 0.0 ? msStringNew("-Infinity", 9) : msStringNew("Infinity", 8);
	if (value >= -1e15 && value <= 1e15 && value == (double)(int64_t)value) {
		int len = snprintf(buf, sizeof(buf), "%lld", (long long)(int64_t)value);
		return msStringNew(buf, len);
	}

	char* p = buf;
	if (value < 0.0) {
		*p++ = '-';
		value = -value;
	}
	char digits[32];
	int decExp = 0;
	int k = msShortestRoundTripDigits(value, digits, &decExp);
	int n = decExp + 1;
	if (k <= n && n <= 21) {
		memcpy(p, digits, (size_t)k);
		p += k;
		for (int i = 0; i < n - k; i++) *p++ = '0';
	} else if (n > 0 && n <= 21) {
		memcpy(p, digits, (size_t)n);
		p += n;
		*p++ = '.';
		memcpy(p, digits + n, (size_t)(k - n));
		p += k - n;
	} else if (n > -6 && n <= 0) {
		*p++ = '0';
		*p++ = '.';
		for (int i = 0; i < -n; i++) *p++ = '0';
		memcpy(p, digits, (size_t)k);
		p += k;
	} else {
		*p++ = digits[0];
		if (k > 1) {
			*p++ = '.';
			memcpy(p, digits + 1, (size_t)(k - 1));
			p += k - 1;
		}
		*p++ = 'e';
		*p++ = n > 0 ? '+' : '-';
		p += snprintf(p, 8, "%d", n > 0 ? n - 1 : -(n - 1));
	}
	return msStringNew(buf, (int)(p - buf));
}

msString msNumberToStringRadix(double value, double radix) {
	int r = (int)radix;
	if (r < 2 || r > 36) r = 10;
	if (r == 10) return msNumberToString(value);
	int64_t iv = (int64_t)value;
	if ((double)iv != value) return msNumberToString(value); /* non-integer: fallback to base 10 */
	char buf[66]; /* enough for 64-bit binary + sign + null */
	int neg = iv < 0;
	uint64_t uv = neg ? (uint64_t)(-(iv + 1)) + 1 : (uint64_t)iv;
	static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
	int pos = 65;
	buf[pos] = '\0';
	do {
		buf[--pos] = digits[uv % r];
		uv /= r;
	} while (uv > 0);
	if (neg) buf[--pos] = '-';
	return msStringNew(buf + pos, 65 - pos);
}

msString msBoolToString(int value) {
	if (value) return msStringNew("true", 4);
	return msStringNew("false", 5);
}

/* ===== Splitting & Joining ===== */

msStringArray msStringSplit(msString s, msString delimiter) {
	msStringArray arr = msStringArrayNew(8);

	if (s.len == 0) {
		msStringArrayPush(&arr, MS_EMPTY_STRING);
		return arr;
	}

	if (delimiter.len == 0) {
		/* Split into individual characters */
		for (int64_t i = 0; i < s.len; i++) {
			msStringArrayPush(&arr, msStringNew(s.p->data + i, 1));
		}
		return arr;
	}

	int64_t pos = 0;
	while (pos <= s.len) {
		int64_t found = msStringByteIndexOf(s, delimiter, pos);
		if (found < 0) {
			msStringArrayPush(&arr, msStringNew(s.p->data + pos, s.len - pos));
			break;
		}
		msStringArrayPush(&arr, msStringNew(s.p->data + pos, found - pos));
		pos = found + delimiter.len;
		if (pos > s.len) {
			msStringArrayPush(&arr, MS_EMPTY_STRING);
		}
	}
	return arr;
}

msString msStringJoin(msStringArray arr, msString sep) {
	if (arr.len == 0) return MS_EMPTY_STRING;

	/* Calculate total length */
	int64_t totalLen = 0;
	for (int64_t i = 0; i < arr.len; i++) {
		totalLen += arr.p->data[i].len;
		if (i > 0) totalLen += sep.len;
	}

	if (totalLen == 0) return MS_EMPTY_STRING;

	msString result = msStringNewCap(totalLen);
	int64_t pos = 0;
	for (int64_t i = 0; i < arr.len; i++) {
		if (i > 0 && sep.len > 0) {
			memcpy(result.p->data + pos, sep.p->data, sep.len);
			pos += sep.len;
		}
		if (arr.p->data[i].len > 0) {
			memcpy(result.p->data + pos, arr.p->data[i].p->data, arr.p->data[i].len);
			pos += arr.p->data[i].len;
		}
	}
	result.len = totalLen;
	result.p->data[totalLen] = '\0';
	return result;
}

/* ===== Parsing ===== */

double msStringParseFloat(msString s) {
	if (s.len == 0 || s.p == NULL) return 0.0;
	/* Ensure null-terminated (it should be, but be safe) */
	return strtod(s.p->data, NULL);
}

int64_t msStringParseInt(msString s) {
	if (s.len == 0 || s.p == NULL) return 0;
	return strtoll(s.p->data, NULL, 10);
}

/* ===== Capacity ===== */

int64_t msStringCapacity(msString s) {
	if (s.p == NULL) return 0;
	return s.p->cap & MS_CAP_MASK;
}

/* ===== In-Place Operations (Standard reference patterns) ===== */

void msStringSetSlice(msString* s, int64_t start, int64_t end) {
	if (start < 0) start = 0;
	if (end > s->len) end = s->len;
	if (start >= end) {
		s->len = 0;
		if (s->p != NULL) s->p->data[0] = '\0';
		return;
	}
	int64_t newLen = end - start;
	if (start > 0) {
		msStringPrepareMutation(s);
		memmove(s->p->data, s->p->data + start, newLen);
	}
	s->len = newLen;
	if (s->p != NULL) s->p->data[newLen] = '\0';
}

void msStringStripInPlace(msString* s) {
	if (s->len == 0 || s->p == NULL) return;
	int64_t first = 0;
	int64_t last = s->len - 1;
	while (first <= last && isspace((unsigned char)s->p->data[first])) first++;
	while (last >= first && isspace((unsigned char)s->p->data[last])) last--;
	msStringSetSlice(s, first, last + 1);
}
