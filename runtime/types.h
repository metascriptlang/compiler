/*
 * MetaScript Type Info — Lightweight RTTI for ORC
 *
 * One static const msTypeInfo per class type.
 * Provides destructor + trace function pointers for cycle collection.
 */

#ifndef MS_TYPEINFO_H
#define MS_TYPEINFO_H

#include <stdint.h>
#include <stdbool.h>

/* Display size for the constant-time subtype test (arc-style). Chains deeper
 * than MS_TYPE_DISPLAY_MAX keep a correct depth but fill only the first MAX
 * display slots; msIsInstance falls back to the base walk for targets at or
 * beyond MAX. */
#define MS_TYPE_DISPLAY_MAX 32
/* Destructor: called to clean up object fields before freeing */
typedef void (*msDestroyProc)(void*);

/* Trace: called by ORC to visit child references for cycle detection.
 * Second arg is the visitor callback context (opaque). */
typedef void (*msTraceProc)(void*, void*);

typedef struct msTypeInfo {
	const char* name;        /* Class name for diagnostics */
	bool isCyclic;           /* True if type can form reference cycles */
	msTraceProc traceFn;     /* TypeName_trace function (NULL if acyclic) */
	msDestroyProc destroyFn; /* TypeName_destroy function (NULL if no RC fields) */
	uint8_t flags;           /* Amendment H: MS_TYPE_FLAG_FUTURE — defer decref to dispatcher */
	const struct msTypeInfo* base; /* superclass chain (NULL at root; kept for destroy/dispatch and the >display fallback) */
	int16_t depth;           /* inheritance depth (root = 0) — constant-time subtype test */
	const struct msTypeInfo* display[MS_TYPE_DISPLAY_MAX]; /* display[i] = ancestor at depth i; display[depth] = self (valid for i < min(depth+1, MAX)) */
} msTypeInfo;

#define MS_ACYCLIC_FLAG false
#define MS_CYCLIC_FLAG true
#define MS_TYPE_FLAG_FUTURE 1  /* Object is a future — msDecref routes to msFutureDeferredRelease */


/* Fill the display where `base` is assigned (module DatInit). NULL base = root:
 * depth 0, display[0] = self. Hand-written runtime TypeInfos (no inheritance)
 * stay zero-filled — the exact-self compare in msIsInstance covers them. */
static inline void msTypeFillDisplay(msTypeInfo* t, const msTypeInfo* base) {
	if (base == NULL) {
		t->depth = 0;
		t->display[0] = t;
		return;
	}
	int32_t d = base->depth + 1;
	t->depth = (int16_t)d;
	int32_t n = d < MS_TYPE_DISPLAY_MAX ? d : MS_TYPE_DISPLAY_MAX;
	for (int32_t i = 0; i < n; i++) t->display[i] = base->display[i];
	if (d < MS_TYPE_DISPLAY_MAX) t->display[d] = t;
}
#endif /* MS_TYPEINFO_H */
