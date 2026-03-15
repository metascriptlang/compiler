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

/* Destructor: called to clean up object fields before freeing */
typedef void (*msDestroyProc)(void*);

/* Trace: called by ORC to visit child references for cycle detection.
 * Second arg is the visitor callback context (opaque). */
typedef void (*msTraceProc)(void*, void*);

typedef struct {
	const char* name;        /* Class name for diagnostics */
	bool isCyclic;           /* True if type can form reference cycles */
	msTraceProc traceFn;     /* TypeName_trace function (NULL if acyclic) */
	msDestroyProc destroyFn; /* TypeName_destroy function (NULL if no RC fields) */
} msTypeInfo;

/* Convenience flags for isCyclic field */
#define MS_ACYCLIC_FLAG false
#define MS_CYCLIC_FLAG true

#endif /* MS_TYPEINFO_H */
