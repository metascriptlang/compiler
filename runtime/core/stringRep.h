#ifndef MS_STRING_REP_H
#define MS_STRING_REP_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

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

/* High bit of cap marks string literals (COW) */
#define MS_STRLIT_FLAG ((int64_t)1 << 62)

/* Bit 61 of cap: ASCII-checked flag (set once we've verified ASCII status) */
#define MS_ASCII_CHECKED ((int64_t)1 << 61)
/* Bit 60 of cap: is-ASCII flag (valid only when ASCII_CHECKED is set) */
#define MS_ASCII_FLAG    ((int64_t)1 << 60)
/* Mask to extract actual capacity from cap field */
#define MS_CAP_MASK (~(MS_STRLIT_FLAG | MS_ASCII_CHECKED | MS_ASCII_FLAG))
#define MS_ASCII_BITS (MS_ASCII_CHECKED | MS_ASCII_FLAG)

/* msStringIsAscii fills the ASCII bits of a payload other threads may be reading:
   every read of cap on a payload this thread does not own exclusively goes through here. */
#ifdef MSGC_MANUAL
#define msStrCapLoad(p) ((p)->cap)
#else
#define msStrCapLoad(p) __atomic_load_n(&(p)->cap, __ATOMIC_RELAXED)
#endif

#define MS_EMPTY_STRING ((msString){0, NULL})

/*
 * Static string literal constructor.
 * Codegen emits a const payload struct (.rodata), then uses this to make msString.
 * Literals are COW: MS_STRLIT_FLAG tells the runtime to copy before any mutation.
 * Usage:
 *   static const struct { int64_t cap; char data[6]; } _str_1 = { MS_STRLIT_FLAG | 5, "hello" };
 *   msString s = MS_STRING_LIT(&_str_1, 5);
 */
#define MS_STRING_LIT(payload, slen) ((msString){ .len = (slen), .p = (msStrPayload*)(payload) })

/* Content size including null terminator + payload header */
static inline int64_t msStrContentSize(int64_t cap) {
	return (int64_t)sizeof(int64_t) + cap + 1;
}

static inline int64_t msStrLen(msString s) { return s.len; }
static inline bool msStrIsEmpty(msString s) { return s.len == 0; }

/* The bytes of s, NUL-terminated: "" for an empty string. */
static inline const char* msStrData(const msString* s) { return s->len != 0 ? s->p->data : ""; }

/* The data pointer of a Span over s; NULL for a string without a buffer. */
static inline uint8_t* msStrBytes(const msString* s) { return s->p != NULL ? (uint8_t*)s->p->data : NULL; }
#define msStringBytesOf(s) msStrBytes((const msString[1]){ (s) })

static inline bool msStrNeedsNoFree(msString s) {
	return s.p == NULL || (msStrCapLoad(s.p) & MS_STRLIT_FLAG) != 0;
}
static inline bool msStrIsHeap(msString s) { return !msStrNeedsNoFree(s); }
static inline bool msStrSameBuffer(msString a, msString b) { return a.p == b.p; }

/* Builder phase only: s is private to the caller and holds a heap buffer. */
static inline char* msStrWritable(msString* s) { return s->p->data; }
static inline void msStrSetLen(msString* s, int64_t len) { s->len = len; }
static inline int64_t msStrCap(msString s) { return s.p->cap & MS_CAP_MASK; }

/* Grow buffer for appending */
void msStringPrepareAdd(msString* s, int64_t addLen);

/* Room for n bytes after the end of s, to be filled and then published by msStrCommit. */
static inline char* msStrReserve(msString* s, int64_t n) {
	msStringPrepareAdd(s, n);
	return s->p->data + s->len;
}
static inline void msStrCommit(msString* s, int64_t n) {
	s->len += n;
	s->p->data[s->len] = '\0';
}

/* A cache-owned heap string that callers share as a literal; only msStringDestroyForce frees it. */
static inline void msStrMarkLiteral(msString* s) {
	if (s->p != NULL) s->p->cap |= MS_STRLIT_FLAG;
}

/* True when no byte of p[0, len) has the high bit set: 32-byte blocks, then words, then bytes. */
static inline bool msBytesAscii(const unsigned char* p, int64_t len) {
	const uint64_t high = 0x8080808080808080ull;
	int64_t i = 0;
	while (i + 32 <= len) {
		uint64_t a, b, c, d;
		memcpy(&a, p + i, 8);
		memcpy(&b, p + i + 8, 8);
		memcpy(&c, p + i + 16, 8);
		memcpy(&d, p + i + 24, 8);
		if (((a | b | c | d) & high) != 0) return false;
		i += 32;
	}
	while (i + 8 <= len) {
		uint64_t a;
		memcpy(&a, p + i, 8);
		if ((a & high) != 0) return false;
		i += 8;
	}
	for (; i < len; i++) {
		if (p[i] >= 0x80) return false;
	}
	return true;
}

/* Check and cache whether a string is pure ASCII. O(n) first call, O(1) after. */
static inline bool msStringIsAscii(msString s) {
	if (s.p == NULL || s.len == 0) return true;
	const int64_t cap = msStrCapLoad(s.p);
	if (cap & MS_ASCII_CHECKED) {
		return (cap & MS_ASCII_FLAG) != 0;
	}
	/* Scan once, cache result */
	const bool ascii = msBytesAscii((const unsigned char*)s.p->data, s.len);
	__atomic_store_n(&s.p->cap, cap | MS_ASCII_CHECKED | (ascii ? MS_ASCII_FLAG : 0), __ATOMIC_RELAXED);
	return ascii;
}

static inline bool msStringKnownAscii(msString s) {
	if (s.p == NULL) return false;
	const int64_t cap = msStrCapLoad(s.p);
	return (cap & MS_ASCII_CHECKED) != 0 && (cap & MS_ASCII_FLAG) != 0;
}

static inline void msStringMarkAscii(msString s) {
	if (s.p != NULL && (s.p->cap & MS_STRLIT_FLAG) == 0) {
		s.p->cap |= MS_ASCII_CHECKED | MS_ASCII_FLAG;
	}
}

static inline void msStringMarkNonAscii(msString s) {
	if (s.p != NULL && (s.p->cap & MS_STRLIT_FLAG) == 0) {
		s.p->cap = (s.p->cap | MS_ASCII_CHECKED) & ~MS_ASCII_FLAG;
	}
}

/* The cached ASCII answer of s as cap bits: the empty string is ASCII, an unchecked payload has none. */
static inline int64_t msStringAsciiBits(msString s) {
	if (s.p == NULL || s.len == 0) return MS_ASCII_BITS;
	return msStrCapLoad(s.p) & MS_ASCII_BITS;
}

/* Record `bits` on a payload this thread just allocated and owns exclusively (never a literal). */
static inline void msStringSetAsciiBits(msString s, int64_t bits) {
	if (s.p != NULL) s.p->cap = (s.p->cap & ~MS_ASCII_BITS) | bits;
}

/* string → cstring conversion (always null-terminated or "") */
static inline const char* msStringToCString(msString s) {
	if (s.p == NULL) return "";
	return s.p->data;
}

msString msStringNew(const char* data, int64_t len);
msString msStringNewCap(int64_t cap);

/* The ASCII answer of the bytes copied from `from` to `to`, a fresh string, byte for byte. */
static inline void msStringInheritAscii(msString to, msString from) {
	msStringSetAsciiBits(to, msStringAsciiBits(from));
}

/* A fresh payload with the bytes of the heap string s and its cached ASCII answer, so a copy never rescans for .length. */
static inline msString msStrDupHeap(msString s) {
	msString r = msStringNew(s.p->data, s.len);
	msStringInheritAscii(r, s);
	return r;
}

static inline msString msStringDup(msString s) {
	return msStrIsHeap(s) ? msStrDupHeap(s) : s;
}

/* Free if not literal */
static inline void msStringDestroy(msString s) {
	if (msStrIsHeap(s)) {
		free(s.p);
	}
}

/* Force-free a cache-owned msString that has MS_STRLIT_FLAG set.
 * Caches (e.g. static response cache in net/socket.h) flag their entries as
 * literal so MS callers don't refcount-touch them, but the cache still owns
 * the heap allocation and must free it on eviction. msStringDestroy refuses
 * to free literals (correct for actual literals), so callers needing the
 * eviction semantic use this helper. Not for general use. */
static inline void msStringDestroyForce(msString s) {
	if (s.p != NULL) free(s.p);
}

/* Append string — slow path: grow, literal COW, self-alias, or src without a
   cached ASCII answer. The inline fast path below covers the common in-place
   case in the caller's TU, like the reference runtime's in-TU add. */
void msStringAppendSlow(msString* dest, msString src);

static inline void msStringAppend(msString* dest, msString src) {
	if (src.len == 0) return;
	msStrPayload* p = dest->p;
	if (p == NULL) { msStringAppendSlow(dest, src); return; }
	int64_t cap = p->cap;
	int64_t scap = msStrCapLoad(src.p);
	/* one branch: bitwise-or folds literal | alias | unchecked src | no room */
	if (((cap & MS_STRLIT_FLAG) != 0) | (p == src.p) |
	    ((scap & MS_ASCII_CHECKED) == 0) |
	    (dest->len + src.len > (cap & MS_CAP_MASK))) {
		msStringAppendSlow(dest, src);
		return;
	}
	memcpy(p->data + dest->len, src.p->data, src.len);
	dest->len += src.len;
	p->data[dest->len] = '\0';
	/* ascii(dest ++ src): appending ASCII changes no cached answer — zero flag
	   writes. A non-ASCII src makes the result non-ASCII for any dest state. */
	if ((scap & MS_ASCII_FLAG) == 0) {
		p->cap = (cap | MS_ASCII_CHECKED) & ~MS_ASCII_FLAG;
	}
}

/* Append single char — slow path (grow or literal COW) */
void msStringAppendCharSlow(msString* dest, char c);

static inline void msStringAppendChar(msString* dest, char c) {
	msStrPayload* p = dest->p;
	if (p == NULL) { msStringAppendCharSlow(dest, c); return; }
	int64_t cap = p->cap;
	if (((cap & MS_STRLIT_FLAG) != 0) | (dest->len + 1 > (cap & MS_CAP_MASK))) {
		msStringAppendCharSlow(dest, c);
		return;
	}
	p->data[dest->len] = c;
	dest->len += 1;
	p->data[dest->len] = '\0';
	if ((unsigned char)c >= 0x80) {
		p->cap = (cap | MS_ASCII_CHECKED) & ~MS_ASCII_FLAG;
	}
}

/* A string of `len` bytes whose content the caller fills before use (no zeroing). */
static inline msString msStringNewUninit(int64_t len) {
	msString r = msStringNewCap(len);
	if (len > 0) {
		r.len = len;
		r.p->data[len] = '\0';
	}
	return r;
}

/* Single character as new string */
msString msStringCharAtSlow(msString s, int64_t idx);

extern const msString msCharTable[128];

static inline msString msStringCharAt(msString s, int64_t idx) {
	if (s.p != NULL && (uint64_t)idx < (uint64_t)s.len) {
		const int64_t cap = msStrCapLoad(s.p);
		if ((cap & (MS_ASCII_CHECKED | MS_ASCII_FLAG)) == (MS_ASCII_CHECKED | MS_ASCII_FLAG)) {
			return msCharTable[(unsigned char)s.p->data[idx]];
		}
	}
	return msStringCharAtSlow(s, idx);
}

/* Character code at index (UTF-16 code unit, TypeScript parity). Returns -1 if out of range. */
int64_t msStringCharCodeAtSlow(msString s, int64_t idx);

static inline int64_t msStringCharCodeAt(msString s, int64_t idx) {
	if (s.p != NULL && (uint64_t)idx < (uint64_t)s.len &&
	    (msStrCapLoad(s.p) & MS_ASCII_BITS) == MS_ASCII_BITS) {
		return (unsigned char)s.p->data[idx];
	}
	return msStringCharCodeAtSlow(s, idx);
}

/* Count UTF-16 code units (TypeScript .length parity) */
/* BMP chars (1-3 UTF-8 bytes) = 1 unit, supplementary (4 bytes) = 2 units */
int64_t msStringLengthSlow(msString s);

static inline int64_t msStringLength(msString s) {
	if (s.p == NULL) return 0;
	if ((msStrCapLoad(s.p) & MS_ASCII_BITS) == MS_ASCII_BITS) return s.len;
	return msStringLengthSlow(s);
}

#endif /* MS_STRING_REP_H */
