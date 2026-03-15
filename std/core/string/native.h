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

#include "std/runtime/arc.h"
#include <stdio.h>
#include <ctype.h>
#include <stdarg.h>

/* Forward declare array type for split/join */
typedef struct msStringArray msStringArray;

/* ===== Core Types ===== */

/* Reference: msStrPayload { cap: int; data: UncheckedArray[char] } */
typedef struct {
	int64_t cap;
	char data[];    /* flexible array member */
} msStrPayload;

/* Reference: msString { len: int; p: ptr msStrPayload } */
typedef struct {
	int64_t len;
	msStrPayload* p;    /* NULL if len == 0 */
} msString;

/* ===== Constants ===== */

/* High bit of cap marks string literals (COW) */
#define MS_STRLIT_FLAG ((int64_t)1 << 62)

/* Empty string */
#define MS_EMPTY_STRING ((msString){0, NULL})

/* ===== Literal Support ===== */

#define msIsLiteral(s) ((s).p == NULL || ((s).p->cap & MS_STRLIT_FLAG) != 0)

/*
 * Static string literal constructor.
 * Codegen emits a static payload struct, then uses this to make msString.
 * Usage:
 *   static struct { int64_t cap; char data[6]; } _str_1 = { MS_STRLIT_FLAG | 5, "hello" };
 *   msString s = MS_STRING_LIT(&_str_1, 5);
 */
#define MS_STRING_LIT(payload, slen) ((msString){ .len = (slen), .p = (msStrPayload*)(payload) })

/* ===== Inline Helpers ===== */

/* Get C string from msString (always null-terminated or "") */
static inline const char* msCStr(msString s) {
	if (s.p == NULL) return "";
	return s.p->data;
}

/* Check if empty */
static inline bool msStringIsEmpty(msString s) {
	return s.len == 0;
}

/* DJB2 hash — used by match lowering for string switch optimization.
 * Must match the compile-time djb2Hash in matchLower.ms. */
static inline int32_t msStringHash(msString s) {
	int32_t h = 5381;
	const char* data = (s.p != NULL) ? s.p->data : "";
	for (int64_t i = 0; i < s.len; i++) {
		h = (h * 33 + (unsigned char)data[i]);
	}
	return h;
}

/* Capacity growth — Standard reference resize pattern */
static inline int64_t msStringResizeCap(int64_t old) {
	if (old <= 0) return 4;
	if (old <= 32767) return old * 2;
	return old + old / 2;  /* x3/2 for large strings */
}

/* Content size including null terminator + payload header */
static inline int64_t msStrContentSize(int64_t cap) {
	return (int64_t)sizeof(int64_t) + cap + 1;
}

/* ===== Lifecycle Functions ===== */

/* Allocate + copy from raw bytes */
msString msStringNew(const char* data, int64_t len);

/* From null-terminated C string */
msString msStringFromCStr(const char* cstr);

/* Preallocate with capacity */
msString msStringNewCap(int64_t cap);

/* Create zero-filled string of given length */
msString msStringNewLen(int64_t len);

/* Free if not literal */
void msStringDestroy(msString s);

/* Deep copy assignment */
void msStringAssign(msString* a, msString b);

/* COW: copy literal before mutation */
void msStringPrepareMutation(msString* s);

/* Grow buffer for appending */
void msStringPrepareAdd(msString* s, int64_t addLen);

/* Append string */
void msStringAppend(msString* dest, msString src);

/* Append single char */
void msStringAppendChar(msString* dest, char c);

/* ===== Comparison ===== */

/* Byte-equal comparison */
bool msStringEquals(msString a, msString b);

/* Case-insensitive equality */
bool msStringEqualsIgnoreCase(msString a, msString b);

/* Lexicographic compare (< 0, 0, > 0) */
int msStringCompare(msString a, msString b);

/* Prefix check */
bool msStringStartsWith(msString s, msString prefix);

/* Suffix check */
bool msStringEndsWith(msString s, msString suffix);

/* Substring check */
bool msStringContains(msString s, msString sub);

/* ===== Search ===== */

/* Find first occurrence, starting from `start`. Returns -1 if not found. */
int64_t msStringIndexOf(msString s, msString sub, int64_t start);

/* Find last occurrence. Returns -1 if not found. */
int64_t msStringLastIndexOf(msString s, msString sub);

/* Count non-overlapping occurrences */
int64_t msStringCount(msString s, msString sub);

/* ===== Extraction ===== */

/* Single character as new string */
msString msStringCharAt(msString s, int64_t idx);

/* Character code at index (UTF-16 code unit, TypeScript parity). Returns -1 if out of range. */
int64_t msStringCharCodeAt(msString s, int64_t idx);

/* Raw byte at byte offset. Returns -1 if out of range. */
int64_t msStringByteAt(msString s, int64_t idx);

/* Single byte as new string (byte-level, for lexer/scanner). */
msString msStringByteCharAt(msString s, int64_t idx);

/* Create a string from a Unicode codepoint (UTF-8 encoded). */
msString msStringFromCodePoint(int64_t cp);

/* Substring [start, end) by character position. TypeScript parity. */
msString msStringSlice(msString s, int64_t start, int64_t end);

/* Substring [start, end) by byte offset. For lexer/binary protocols. */
msString msStringByteSlice(msString s, int64_t start, int64_t end);

/* Alias for slice */
msString msStringSubstring(msString s, int64_t start, int64_t end);

/* ===== Transformation ===== */

msString msStringToLower(msString s);
msString msStringToUpper(msString s);
msString msStringTrim(msString s);
msString msStringTrimStart(msString s);
msString msStringTrimEnd(msString s);
msString msStringRepeat(msString s, int64_t count);
msString msStringReplace(msString s, msString search, msString replacement);
msString msStringReplaceAll(msString s, msString search, msString replacement);
msString msStringReverse(msString s);
msString msStringPadStart(msString s, int64_t targetLen, msString pad);
msString msStringPadEnd(msString s, int64_t targetLen, msString pad);

/* ===== Length (Encoding-Aware) ===== */

/* Count UTF-16 code units (TypeScript .length parity) */
/* BMP chars (1-3 UTF-8 bytes) = 1 unit, supplementary (4 bytes) = 2 units */
int64_t msStringLength(msString s);

/* Count Unicode scalar values (codepoints) */
int64_t msStringUnicodeLength(msString s);

/* Byte length (for binary protocols like LSP Content-Length) */
static inline int64_t msStringByteLength(msString s) {
	return s.len;
}

/* ===== Building ===== */

/* Concatenate two strings into a new one */
msString msStringConcat(msString a, msString b);

/* Concatenate N strings (variadic) — for concat chain fusion */
msString msStringConcatMany(int64_t count, ...);

/* Set character at index (mutating) — requires prior msStringPrepareMutation */
void msStringSetChar(msString* s, int64_t idx, msString ch);

/* Number/bool to string */
msString msIntToString(int64_t value);
msString msNumberToString(double value);
msString msNumberToStringRadix(double value, double radix);
/* msNumberToString is the no-radix fast path; msNumberToStringRadix handles arbitrary base */
msString msBoolToString(int value);
#define msIntToStr msIntToString
#define msBoolToStr msBoolToString

/* ===== Splitting & Joining ===== */

/* Split string by delimiter */
msStringArray msStringSplit(msString s, msString delimiter);

/* Join string array with separator */
msString msStringJoin(msStringArray arr, msString sep);

/* ===== Parsing ===== */

double msStringParseFloat(msString s);
int64_t msStringParseInt(msString s);

/* ===== Set Length ===== */

/* Resize string, zero-filling on growth */
void msStringSetLength(msString* s, int64_t newLen);

/* ===== Capacity ===== */

/* Return allocated capacity, stripping literal flag */
int64_t msStringCapacity(msString s);

/* ===== In-Place Operations (Standard reference patterns) ===== */

/* In-place substring via memmove */
void msStringSetSlice(msString* s, int64_t start, int64_t end);

/* In-place strip whitespace */
void msStringStripInPlace(msString* s);

#endif /* MS_STRING_H */
