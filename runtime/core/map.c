/*
 * MetaScript Map Runtime — Hash Map with String Keys
 *
 * Open-addressing with linear probing, SoA layout.
 * Phase 1: msString keys only, void* values.
 */

#include "map.h"
#include <string.h>
#include <stdlib.h>

/* ===== Internal Helpers ===== */

static msMapPayload* msMapAllocPayload(int64_t cap) {
	msMapPayload* p = (msMapPayload*)malloc(sizeof(msMapPayload));
	p->cap = cap;
	p->states = (uint8_t*)calloc(cap, sizeof(uint8_t));   /* zero = MS_MAP_EMPTY */
	p->keys = (msString*)calloc(cap, sizeof(msString));
	p->values = (void**)calloc(cap, sizeof(void*));
	return p;
}

static void msMapFreePayload(msMapPayload* p) {
	if (p == NULL) return;
	/* Destroy all active keys */
	for (int64_t i = 0; i < p->cap; i++) {
		if (p->states[i] == MS_MAP_USED) {
			msStringDestroy(p->keys[i]);
		}
	}
	free(p->states);
	free(p->keys);
	free(p->values);
	free(p);
}

/* Find slot for key. Returns slot index.
 * If found: states[slot] == MS_MAP_USED && keys match.
 * If not found: returns first EMPTY or DELETED slot suitable for insertion.
 * Sets *found to true/false. */
static int64_t msMapFindSlot(msMapPayload* p, msString key, bool* found) {
	uint64_t h = msHashString(key);
	int64_t mask = p->cap - 1;
	int64_t idx = (int64_t)(h & (uint64_t)mask);
	int64_t firstDeleted = -1;

	for (int64_t i = 0; i < p->cap; i++) {
		int64_t slot = (idx + i) & mask;
		uint8_t state = p->states[slot];

		if (state == MS_MAP_EMPTY) {
			*found = false;
			return (firstDeleted >= 0) ? firstDeleted : slot;
		}
		if (state == MS_MAP_DELETED) {
			if (firstDeleted < 0) firstDeleted = slot;
			continue;
		}
		/* MS_MAP_USED — compare keys */
		if (msStringEquals(p->keys[slot], key)) {
			*found = true;
			return slot;
		}
	}

	/* Table is full (shouldn't happen with proper load factor) */
	*found = false;
	return (firstDeleted >= 0) ? firstDeleted : 0;
}

static bool msMapNeedsRehash(int64_t len, int64_t cap) {
	/* len * 10 > cap * 7  <==>  load > 0.7 */
	return len * MS_MAP_LOAD_FACTOR_DEN > cap * MS_MAP_LOAD_FACTOR_NUM;
}

static void msMapRehash(msMap* m, int64_t newCap) {
	msMapPayload* oldP = m->p;
	msMapPayload* newP = msMapAllocPayload(newCap);

	if (oldP != NULL) {
		for (int64_t i = 0; i < oldP->cap; i++) {
			if (oldP->states[i] == MS_MAP_USED) {
				bool found;
				int64_t slot = msMapFindSlot(newP, oldP->keys[i], &found);
				newP->states[slot] = MS_MAP_USED;
				newP->keys[slot] = oldP->keys[i];     /* transfer ownership, no copy */
				newP->values[slot] = oldP->values[i];
			}
		}
		/* Free old payload arrays without destroying keys (transferred) */
		free(oldP->states);
		free(oldP->keys);
		free(oldP->values);
		free(oldP);
	}

	m->p = newP;
}

/* ===== Public API ===== */

msMap msMapNew(void) {
	return MS_EMPTY_MAP;
}

void msMapDestroy(msMap* m) {
	if (m->p != NULL) {
		msMapFreePayload(m->p);
		m->p = NULL;
	}
	m->len = 0;
}

msMap msMapCopyFn(msMap m) {
	if (m.p == NULL) return MS_EMPTY_MAP;

	msMap copy;
	copy.len = m.len;
	copy.p = msMapAllocPayload(m.p->cap);

	memcpy(copy.p->states, m.p->states, m.p->cap * sizeof(uint8_t));
	memcpy(copy.p->values, m.p->values, m.p->cap * sizeof(void*));

	/* Deep-copy string keys (incref) */
	for (int64_t i = 0; i < m.p->cap; i++) {
		if (m.p->states[i] == MS_MAP_USED) {
			msString keyCopy = MS_EMPTY_STRING;
			msStringAssign(&keyCopy, m.p->keys[i]);
			copy.p->keys[i] = keyCopy;
		} else {
			copy.p->keys[i] = MS_EMPTY_STRING;
		}
	}

	return copy;
}

void msMapSet(msMap* m, msString key, void* value) {
	/* Lazy init */
	if (m->p == NULL) {
		m->p = msMapAllocPayload(MS_MAP_INITIAL_CAP);
	}

	/* Check load factor before insert */
	if (msMapNeedsRehash(m->len + 1, m->p->cap)) {
		msMapRehash(m, m->p->cap * 2);
	}

	bool found;
	int64_t slot = msMapFindSlot(m->p, key, &found);

	if (found) {
		/* Update existing — value only (key already matches) */
		m->p->values[slot] = value;
	} else {
		/* Insert new */
		m->p->states[slot] = MS_MAP_USED;
		msString keyCopy = MS_EMPTY_STRING;
		msStringAssign(&keyCopy, key);
		m->p->keys[slot] = keyCopy;
		m->p->values[slot] = value;
		m->len++;
	}
}

void* msMapGet(msMap m, msString key) {
	if (m.p == NULL) return NULL;

	bool found;
	int64_t slot = msMapFindSlot(m.p, key, &found);
	if (found) {
		return m.p->values[slot];
	}
	return NULL;
}

bool msMapHas(msMap m, msString key) {
	if (m.p == NULL) return false;

	bool found;
	msMapFindSlot(m.p, key, &found);
	return found;
}

bool msMapDelete(msMap* m, msString key) {
	if (m->p == NULL) return false;

	bool found;
	int64_t slot = msMapFindSlot(m->p, key, &found);
	if (!found) return false;

	/* Tombstone deletion */
	m->p->states[slot] = MS_MAP_DELETED;
	msStringDestroy(m->p->keys[slot]);
	m->p->keys[slot] = MS_EMPTY_STRING;
	m->p->values[slot] = NULL;
	m->len--;
	return true;
}

int64_t msMapSize(msMap m) {
	return m.len;
}

void msMapClear(msMap* m) {
	if (m->p == NULL) return;

	for (int64_t i = 0; i < m->p->cap; i++) {
		if (m->p->states[i] == MS_MAP_USED) {
			msStringDestroy(m->p->keys[i]);
			m->p->keys[i] = MS_EMPTY_STRING;
			m->p->values[i] = NULL;
		}
		m->p->states[i] = MS_MAP_EMPTY;
	}
	m->len = 0;
}
