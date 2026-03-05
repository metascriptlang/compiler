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

/* ===== Slot States ===== */

#define MS_MAP_EMPTY   0
#define MS_MAP_DELETED 1
#define MS_MAP_USED    2

/* ===== Payload (SoA layout) ===== */

typedef struct {
	int64_t cap;          /* slot count (always power of 2) */
	uint8_t* states;      /* per-slot state: EMPTY / DELETED / USED */
	msString* keys;       /* key array */
	void** values;        /* value array (type-erased) */
} msMapPayload;

/* ===== Map Value Type ===== */

typedef struct {
	int64_t len;          /* number of active (USED) entries */
	msMapPayload* p;      /* NULL if empty */
} msMap;

/* ===== Constants ===== */

#define MS_EMPTY_MAP ((msMap){0, NULL})
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

msMap msMapNew(void);
void msMapDestroy(msMap* m);
msMap msMapCopyFn(msMap m);  /* DRC uses msMapCopy macro in system.h */

/* ===== Operations ===== */

void msMapSet(msMap* m, msString key, void* value);
void* msMapGet(msMap m, msString key);
bool msMapHas(msMap m, msString key);
bool msMapDelete(msMap* m, msString key);
int64_t msMapSize(msMap m);
void msMapClear(msMap* m);

#endif /* MS_MAP_H */
