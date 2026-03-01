/*
 * MetaScript String Runtime
 * Following Nim's NimStringV2 layout from strs_v2.nim
 *
 * msString = { len, p } where p -> msStrPayload { cap, data[] }
 * String literals use strlitFlag in cap's high bit (COW).
 * Growth: <=0 -> 4, <=32K -> x2, else -> x3/2
 */

#ifndef MS_STRING_H
#define MS_STRING_H

#include "../mem/arc.h"
#include <stdio.h>
#include <ctype.h>
#include <stdarg.h>

/* Forward declare array type for split/join */
typedef struct msStringArray msStringArray;

/* ===== Core Types ===== */

/* Nim: NimStrPayload { cap: int; data: UncheckedArray[char] } */
typedef struct {
	int64_t cap;
	char data[];    /* flexible array member */
} msStrPayload;

/* Nim: NimStringV2 { len: int; p: ptr NimStrPayload } */
typedef struct {
	int64_t len;
	msStrPayload* p;    /* NULL if len == 0 */
} msString;

/* ===== Constants ===== */

/* Nim's strlitFlag — high bit of cap marks string literals (COW) */
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

/* Capacity growth — Nim: resize() in strs_v2.nim */
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

/* Allocate + copy from raw bytes — Nim: toNimStr */
msString msStringNew(const char* data, int64_t len);

/* From null-terminated C string — Nim: cstrToNimstr */
msString msStringFromCStr(const char* cstr);

/* Preallocate with capacity — Nim: rawNewString */
msString msStringNewCap(int64_t cap);

/* Create zero-filled string of given length — Nim: mnewString */
msString msStringNewLen(int64_t len);

/* Free if not literal — Nim: nimDestroyStrV1 */
void msStringDestroy(msString s);

/* Deep copy assignment — Nim: nimAsgnStrV2 */
void msStringAssign(msString* a, msString b);

/* COW: copy literal before mutation — Nim: nimPrepareStrMutationV2 */
void msStringPrepareMutation(msString* s);

/* Grow buffer for appending — Nim: prepareAdd */
void msStringPrepareAdd(msString* s, int64_t addLen);

/* Append string — Nim: nimAddStrV1 */
void msStringAppend(msString* dest, msString src);

/* Append single char — Nim: nimAddCharV1 */
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

/* Character code at index. Returns -1 if out of range. */
int64_t msStringCharCodeAt(msString s, int64_t idx);

/* Substring [start, end). Clamps to bounds. */
msString msStringSlice(msString s, int64_t start, int64_t end);

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

/* ===== Building ===== */

/* Concatenate two strings into a new one */
msString msStringConcat(msString a, msString b);

/* Concatenate N strings (variadic) — for concat chain fusion */
msString msStringConcatMany(int64_t count, ...);

/* Set character at index (mutating) — requires prior msStringPrepareMutation */
void msStringSetChar(msString* s, int64_t idx, msString ch);

/* Number to string */
msString msIntToString(int64_t value);
msString msNumberToString(double value);

/* ===== Splitting & Joining ===== */

/* Split string by delimiter */
msStringArray msStringSplit(msString s, msString delimiter);

/* Join string array with separator */
msString msStringJoin(msStringArray arr, msString sep);

/* ===== Parsing ===== */

double msStringParseFloat(msString s);
int64_t msStringParseInt(msString s);

/* ===== Set Length ===== */

/* Resize string, zero-filling on growth — Nim: setLengthStrV2 */
void msStringSetLength(msString* s, int64_t newLen);

/* ===== Capacity ===== */

/* Return allocated capacity, stripping literal flag — Nim: capacity(string) */
int64_t msStringCapacity(msString s);

/* ===== In-Place Operations (Nim strbasics.nim) ===== */

/* In-place substring via memmove — Nim: strbasics.setSlice */
void msStringSetSlice(msString* s, int64_t start, int64_t end);

/* In-place strip whitespace — Nim: strbasics.strip */
void msStringStripInPlace(msString* s);

#endif /* MS_STRING_H */
