/*
 * MetaScript Map Runtime — Hash Map with String Keys
 *
 * Phase 1: msString keys, void* values (type-erased).
 * Layout follows msArray pattern: value-type struct { len, p }.
 * SoA (Structure of Arrays) for cache-friendly linear probing.
 * Growth: rehash at load > 0.7, double capacity (power of 2).
 * Hash: DJB2 on string bytes.
 */

#ifndef MS_MAP_H
#define MS_MAP_H

#include "../mem/arc.h"
#include "string.h"
#include <stdlib.h>

/* ===== Slot States ===== */

#define MS_MAP_EMPTY   0
#define MS_MAP_DELETED 1
#define MS_MAP_USED    2

/* ===== Value Destructor Callback ===== */
/* Called when a managed value is removed (overwrite, delete, clear, destroy). */
/* NULL = no-op (primitives, Set values). */
typedef void (*msMapValueDestructor)(void*);

/* ===== Payload (SoA layout) ===== */

typedef struct {
	int64_t cap;          /* slot count (always power of 2) */
	uint8_t* states;      /* per-slot state: EMPTY / DELETED / USED */
	msString* keys;       /* key array */
	void** values;        /* value array (type-erased) */
} msMapPayload;

/* ===== Map Value Type ===== */

typedef struct {
	int64_t len;              /* number of active (USED) entries */
	msMapPayload* p;          /* NULL if empty */
	msMapValueDestructor valDestroy;  /* called on value removal (NULL = no-op) */
} msMap;

/* ===== Constants ===== */

#define MS_EMPTY_MAP ((msMap){0, NULL, NULL})
#define MS_MAP_INITIAL_CAP 8
#define MS_MAP_LOAD_FACTOR_NUM 7
#define MS_MAP_LOAD_FACTOR_DEN 10

/* ===== Hash Function ===== */

static inline uint64_t msHashString(msString s) {
	if (s.len == 0 || s.p == NULL) return 5381;
	uint64_t h = 5381;
	const char* data = s.p->data;
	for (int64_t i = 0; i < s.len; i++) {
		h = h * 33 + (uint8_t)data[i];
	}
	return h;
}

/* ===== Lifecycle ===== */

msMap msMapNew(msMapValueDestructor valDestroy);
void msMapDestroy(msMap* m);
msMap msMapCopyFn(msMap m);  /* DRC uses msMapCopy macro in system.h */

/* ===== Operations ===== */

void msMapSet(msMap* m, msString key, void* value);
void* msMapGet(msMap m, msString key);
bool msMapHas(msMap m, msString key);
bool msMapDelete(msMap* m, msString key);
int64_t msMapSize(msMap m);
void msMapClear(msMap* m);

/* ===== Iteration Helpers ===== */
/* Used by for-of lowering to scan occupied slots. */

static inline int64_t msMapCap(msMap m) { return m.p ? m.p->cap : 0; }
static inline uint8_t msMapSlotState(msMap m, int64_t i) { return m.p->states[i]; }
static inline msString msMapSlotKey(msMap m, int64_t i) { return m.p->keys[i]; }
static inline void* msMapSlotValue(msMap m, int64_t i) { return m.p->values[i]; }

/* ===== Numeric Key Helpers ===== */
/* Store numeric keys as their string representation via snprintf.        */
/* This reuses all existing string-key infrastructure (DJB2, comparison). */

static inline msString msNumToKey(double v) {
	char buf[32];
	int n = snprintf(buf, sizeof(buf), "%.17g", v);
	return msStringNew(buf, (int64_t)n);
}

static inline double msKeyToNum(msString s) {
	if (s.len == 0 || s.p == NULL) return 0.0;
	return strtod(s.p->data, NULL);
}

#endif /* MS_MAP_H */
