/*
 * MetaScript String Runtime — Implementation
 * Following the standard reference string patterns.
 */

#include "string.h"
#include "array.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include <math.h>

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
		if (msIsLiteral(*a) || (a->p->cap & ~MS_STRLIT_FLAG) < b.len) {
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
		int64_t oldCap = s->p->cap & ~MS_STRLIT_FLAG;
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
		msStringPrepareAdd(dest, src.len);
		memcpy(dest->p->data + dest->len, src.p->data, src.len);
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
			int64_t oldCap = s->p->cap & ~MS_STRLIT_FLAG;
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

bool msStringContains(msString s, msString sub) {
	if (sub.len == 0) return true;
	if (sub.len > s.len) return false;
	if (s.p == NULL) return false;
	return msStringIndexOf(s, sub, 0) >= 0;
}

/* ===== Search ===== */

int64_t msStringIndexOf(msString s, msString sub, int64_t start) {
	if (sub.len == 0) return start <= s.len ? start : -1;
	if (start < 0) start = 0;
	if (sub.len > s.len || s.p == NULL) return -1;

	const char* haystack = s.p->data;
	const char* needle = sub.p->data;
	int64_t limit = s.len - sub.len;

	for (int64_t i = start; i <= limit; i++) {
		if (memcmp(haystack + i, needle, sub.len) == 0) {
			return i;
		}
	}
	return -1;
}

int64_t msStringLastIndexOf(msString s, msString sub) {
	if (sub.len == 0) return s.len;
	if (sub.len > s.len || s.p == NULL) return -1;

	const char* haystack = s.p->data;
	const char* needle = sub.p->data;

	for (int64_t i = s.len - sub.len; i >= 0; i--) {
		if (memcmp(haystack + i, needle, sub.len) == 0) {
			return i;
		}
	}
	return -1;
}

int64_t msStringCount(msString s, msString sub) {
	if (sub.len == 0) return s.len + 1;
	int64_t count = 0;
	int64_t pos = 0;
	while (pos <= s.len - sub.len) {
		int64_t found = msStringIndexOf(s, sub, pos);
		if (found < 0) break;
		count++;
		pos = found + sub.len;
	}
	return count;
}

/* ===== Extraction ===== */

msString msStringCharAt(msString s, int64_t idx) {
	if (idx < 0 || idx >= s.len || s.p == NULL) return MS_EMPTY_STRING;
	return msStringNew(s.p->data + idx, 1);
}

int64_t msStringCharCodeAt(msString s, int64_t idx) {
	if (idx < 0 || idx >= s.len || s.p == NULL) return -1;
	return (int64_t)(unsigned char)s.p->data[idx];
}

msString msStringSlice(msString s, int64_t start, int64_t end) {
	/* Clamp to bounds */
	if (start < 0) start = s.len + start;
	if (end < 0) end = s.len + end;
	if (start < 0) start = 0;
	if (end > s.len) end = s.len;
	if (start >= end || s.p == NULL) return MS_EMPTY_STRING;

	return msStringNew(s.p->data + start, end - start);
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
	int64_t pos = msStringIndexOf(s, search, 0);
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
		int64_t found = msStringIndexOf(s, search, srcPos);
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

msString msStringConcatMany(int64_t count, ...) {
	if (count <= 0) return MS_EMPTY_STRING;

	/* First pass: calculate total length */
	va_list args;
	va_start(args, count);
	int64_t totalLen = 0;
	for (int64_t i = 0; i < count; i++) {
		msString s = va_arg(args, msString);
		totalLen += s.len;
	}
	va_end(args);

	if (totalLen == 0) return MS_EMPTY_STRING;

	/* Second pass: copy data */
	msString result = msStringNewCap(totalLen);
	va_start(args, count);
	int64_t pos = 0;
	for (int64_t i = 0; i < count; i++) {
		msString s = va_arg(args, msString);
		if (s.len > 0 && s.p != NULL) {
			memcpy(result.p->data + pos, s.p->data, s.len);
			pos += s.len;
		}
	}
	va_end(args);

	result.len = totalLen;
	result.p->data[totalLen] = '\0';
	return result;
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

msString msNumberToString(double value) {
	char buf[64];
	int len;
	/* Check if integer value */
	if (value == (double)(int64_t)value && value >= -1e15 && value <= 1e15) {
		len = snprintf(buf, sizeof(buf), "%lld", (long long)(int64_t)value);
	} else {
		len = snprintf(buf, sizeof(buf), "%.17g", value);
	}
	return msStringNew(buf, len);
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
		int64_t found = msStringIndexOf(s, delimiter, pos);
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
	return s.p->cap & ~MS_STRLIT_FLAG;
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
