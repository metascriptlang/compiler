/*
 * MetaScript String Runtime
 * Following the standard reference string layout
 *
 * msString = { len, p } where p -> msStrPayload { cap, data[] }
 * String literals use strlitFlag in cap's high bit (COW).
 * Growth: <=0 -> 4, <=32K -> x2, else -> x3/2
 */

#ifndef MS_STRING_H
#define MS_STRING_H

#include "runtime/drc.h"
#include "runtime/core/stringRep.h"
#include <stdio.h>
#include <ctype.h>
#include <string.h>

/* Forward declare array type for split/join */
typedef struct msStringArray msStringArray;

/* Answer bits of a ++ b: ASCII when both are, non-ASCII when either is, unknown otherwise. */
static inline int64_t msAsciiBitsJoin(int64_t a, int64_t b) {
	if ((a & b) == MS_ASCII_BITS) return MS_ASCII_BITS;
	if ((a == MS_ASCII_CHECKED) | (b == MS_ASCII_CHECKED)) return MS_ASCII_CHECKED;
	return 0;
}

/* The ASCII answer of `to`, a fresh a ++ b. */
static inline void msStringInheritAsciiJoin(msString to, msString a, msString b) {
	msStringSetAsciiBits(to, msAsciiBitsJoin(msStringAsciiBits(a), msStringAsciiBits(b)));
}

/* DJB2 hash — used by match lowering for string switch optimization.
 * Must match the compile-time djb2Hash in matchLower.ms. */
static inline int32_t msStringHash(msString s) {
	unsigned int h = 5381;
	const char* data = msStrData(&s);
	for (int64_t i = 0; i < msStrLen(s); i++) {
		h = (h * 33 + (unsigned char)data[i]);
	}
	return (int32_t)h;
}

/* `.length` is int32 on every backend, so no string, array or buffer grows past
   it: the allocation sites refuse a larger count instead of wrapping the length. */
#define MS_LEN_MAX INT32_MAX

/* Capacity growth — Standard reference resize pattern */
static inline int64_t msStringResizeCap(int64_t old) {
	if (old <= 0) return 4;
	if (old <= 32767) return old * 2;
	int64_t grown = old + old / 2;  /* x3/2 for large strings */
	return grown < MS_LEN_MAX ? grown : MS_LEN_MAX;
}

/* ===== Lifecycle Functions ===== */

/* From null-terminated C string */
msString msStringFromCStr(const char* cstr);

/* Create zero-filled string of given length */
msString msStringNewLen(int64_t len);

/* ===== Comparison ===== */

/* Byte-equal comparison */
bool msStringEquals(msString a, msString b);

static inline bool msEqualMem(const uint8_t* a, int64_t aLen, const uint8_t* b, int64_t bLen) {
	(void)bLen;
	return aLen == 0 || memcmp(a, b, (size_t)aLen) == 0;
}

/* Ordering in UTF-16 code units (< 0, 0, > 0) */
int32_t msStringCompare(msString a, msString b);

/* Ordering in raw bytes, for binary data held in a string */
int32_t msStringCompareBytes(msString a, msString b);

/* Index of the first differing byte of `a` and `b`, or the shorter length when one is a prefix of the other. */
static inline int64_t msMemMismatch(const uint8_t* a, int64_t aLen, const uint8_t* b, int64_t bLen) {
	int64_t n = aLen < bLen ? aLen : bLen;
	if (a == b) return n;
	int64_t i = 0;
	while (i + 32 <= n) {
		uint64_t x[4], y[4];
		memcpy(x, a + i, 32);
		memcpy(y, b + i, 32);
		if (((x[0] ^ y[0]) | (x[1] ^ y[1]) | (x[2] ^ y[2]) | (x[3] ^ y[3])) != 0) break;
		i += 32;
	}
	while (i + 8 <= n) {
		uint64_t wa, wb;
		memcpy(&wa, a + i, 8);
		memcpy(&wb, b + i, 8);
		if (wa != wb) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && defined(__GNUC__)
			return i + (__builtin_ctzll(wa ^ wb) >> 3);
#endif
			break;
		}
		i += 8;
	}
	while (i < n && a[i] == b[i]) i++;
	return i;
}

/* Operator overload helpers — prelude `<` and `<=` base operators */
static inline bool msStringCompareLt(msString a, msString b) { return msStringCompare(a, b) < 0; }
static inline bool msStringCompareLe(msString a, msString b) { return msStringCompare(a, b) <= 0; }

/* ===== Search ===== */

/* Byte offsets in and out; an empty `sub` answers `start`. */
int64_t msStringByteIndexOf(msString s, msString sub, int64_t start);

static inline int64_t msMemChr(const uint8_t* hay, int64_t hayLen, int64_t from, int64_t end, uint8_t byte) {
	(void)hayLen;
	if (end <= from) return -1;
	const uint8_t* hit = (const uint8_t*)memchr(hay + from, byte, (size_t)(end - from));
	return hit ? (int64_t)(hit - hay) : -1;
}

static inline bool msMemEqAt(const uint8_t* hay, int64_t hayLen, int64_t at, const uint8_t* needle, int64_t needleLen) {
	(void)hayLen;
	return needleLen == 0 || memcmp(hay + at, needle, (size_t)needleLen) == 0;
}

static inline void msMemCopyTo(uint8_t* dst, int64_t at, const uint8_t* src, int64_t srcLen, int64_t from, int64_t n) {
	(void)srcLen;
	if (n > 0) memcpy(dst + at, src + from, (size_t)n);
}

/* ===== Extraction ===== */

static inline msString msCharTableAt(uint8_t byte) { return msCharTable[byte & 0x7F]; }

/* An already-verified-ASCII string indexes by byte, so the interned table
   answers without a call. Unknown/false flag, non-ASCII or out of range goes
   out of line — including the flag-computing path, which must stay one place. */
static inline msString msStringAsciiChar(uint8_t byte) { return msCharTable[byte]; }

/* Raw byte at byte offset. Returns -1 if out of range. */
int64_t msStringByteAt(msString s, int64_t idx);

/* Create a string from a Unicode codepoint (UTF-8 encoded). */
msString msStringFromCodePoint(int64_t cp);
void msStringAppendCodePoint(msString* dest, int64_t cp);

/* Substring [start, end) by character position. TypeScript parity. */
msString msStringSlice(msString s, int64_t start, int64_t end);

/* Substring [start, end) by byte offset. For lexer/binary protocols. */
msString msStringByteSlice(msString s, int64_t start, int64_t end);

/* ===== Transformation ===== */


/* ===== Length (Encoding-Aware) ===== */

/* Count Unicode scalar values (codepoints) */
int64_t msStringUnicodeLength(msString s);

/* UTF-16 units of well-formed WTF-8: one per non-continuation byte, one more per 4-byte lead. */
static inline int64_t msUtf16Units(const unsigned char* p, int64_t len) {
	const uint64_t high = 0x8080808080808080ull;
	int64_t units = 0;
	int64_t i = 0;
	for (; i + 8 <= len; i += 8) {
		uint64_t w;
		memcpy(&w, p + i, 8);
		const uint64_t cont = w & ~(w << 1) & high;
		const uint64_t astral = w & (w << 1) & (w << 2) & (w << 3) & high;
		units += 8 - __builtin_popcountll(cont) + __builtin_popcountll(astral);
	}
	for (; i < len; i++) {
		units += (p[i] & 0xC0) != 0x80;
		units += p[i] >= 0xF0;
	}
	return units;
}

/* Byte length (for binary protocols like LSP Content-Length) */
static inline int64_t msStringByteLength(msString s) {
	return msStrLen(s);
}

/* ===== Building ===== */

/* Concatenate two strings into a new one */
msString msStringConcat(msString a, msString b);

/* Concatenate N strings from an array — ABI-portable (no variadic struct passing) */
msString msStringConcatArr(msString* arr, int64_t count);

/* Append N strings from an array to dest in place — single prepareAdd sized
 * exactly to total addition, then loop memcpy. Used by stringOpLower to lower
 * self-append chains (`x = x + a + b + c` or `x = `${x}${y}${z}``) to one
 * amortized in-place call instead of allocating a fresh buffer via
 * msStringConcatArr. */
void msStringAppendArr(msString* dest, const msString* arr, int64_t count);

/* Number/bool to string */
msString msIntToString(int64_t value);
msString msUint64ToString(uint64_t value);
msString msIntToStringRadix(int64_t value, double radix);
msString msUint64ToStringRadix(uint64_t value, double radix);
msString msNumberToString(double value);
msString msNumberToStringRadix(double value, double radix);
/* msNumberToString is the no-radix fast path; msNumberToStringRadix handles arbitrary base */
msString msBoolToString(int value);
#define msIntToStr msIntToString
#define msBoolToStr msBoolToString

/* ===== Splitting & Joining ===== */

/* Join string array with separator; the body is std/core/string/editNative.cms */
msString msStringJoin(msStringArray* arr, msString sep);

/* ===== Parsing ===== */

double msStringParseFloat(msString s);

/* Empty a string but keep its buffer, for a reused response or request buffer */
void msStringClear(msString* s);

/* Trim and case conversion with the ECMAScript result (runtime/core/stringCase.c) */
msString msStringTrim(msString s);
msString msStringTrimStart(msString s);
msString msStringTrimEnd(msString s);
msString msStringToUpperCase(msString s);
msString msStringToLowerCase(msString s);

/* ===== Single-Char Interning Table ===== */
/* 128 precomputed ASCII single-char strings, const payloads (.rodata),
   statically initialized — no init guard, no constructor. Each has
   MS_STRLIT_FLAG set so DRC treats them as literals (no dealloc, shallow
   copy on share). Eliminates malloc-per-char in s[i] loops. */
extern const msString msCharTable[128];

#endif /* MS_STRING_H */
