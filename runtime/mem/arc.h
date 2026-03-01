/*
 * MetaScript ARC Runtime — Reference Counting Primitives
 *
 * RefHeader prepended to all heap-allocated RC objects.
 * Layout: [rc:4][rootIdx:4][type:8] = 16 bytes on 64-bit
 */

#ifndef MS_ARC_H
#define MS_ARC_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "typeinfo.h"

/* Reference header — prepended to all heap-allocated RC objects */
typedef struct {
	int32_t rc;              /* Reference count (0 = unique, >0 = shared) */
	int32_t rootIdx;         /* ORC rootset index (-1 = not registered) */
	const msTypeInfo* type;  /* RTTI (NULL for untyped allocs) */
} msRefHeader;

/* Get header from user pointer: header lives right before the object */
static inline msRefHeader* msHeader(void* p) {
	return (msRefHeader*)((char*)p - sizeof(msRefHeader));
}

/* Allocate object with ref header. Returns pointer to user data (past header). */
static inline void* msAlloc(size_t size) {
	msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
	h->rc = 0;
	h->rootIdx = -1;
	h->type = NULL;
	return (void*)(h + 1);
}

/* Allocate with RTTI — for typed class instances (ORC-aware). */
static inline void* msAllocTyped(size_t size, const msTypeInfo* type) {
	msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
	h->rc = 0;
	h->rootIdx = -1;
	h->type = type;
	return (void*)(h + 1);
}

/* msIncRef — increment reference count */
static inline void msIncRef(void* p) {
	if (p != NULL) {
		msHeader(p)->rc++;
	}
}

/* msDecRefIsLast — decrement and test if last reference.
 * Returns true if this was the last reference. Caller handles destroy+free. */
static inline bool msDecRefIsLast(void* p) {
	if (p == NULL) return false;
	msRefHeader* h = msHeader(p);
	if (h->rc == 0) return true;
	h->rc--;
	return false;
}

/* msDestroyAndDispose — free the header+object memory.
 * Call after =destroy hook has cleaned up fields. */
static inline void msDestroyAndDispose(void* p) {
	if (p != NULL) {
		free(msHeader(p));
	}
}

/* msWasMoved — zero out a pointer variable after move */
#define msWasMoved(p) ((p) = NULL)

#endif /* MS_ARC_H */
