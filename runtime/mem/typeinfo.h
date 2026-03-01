/*
 * MetaScript Type Info — Lightweight RTTI for ORC
 *
 * One static const msTypeInfo per class type.
 * Provides destructor + trace function pointers for cycle collection.
 */

#ifndef MS_TYPEINFO_H
#define MS_TYPEINFO_H

#include <stdint.h>

/* Destructor: called to clean up object fields before freeing */
typedef void (*msDestroyProc)(void*);

/* Trace: called by ORC to visit child references for cycle detection.
 * Second arg is the visitor callback context (opaque). */
typedef void (*msTraceProc)(void*, void*);

typedef struct {
	msDestroyProc destroy;   /* TypeName_destroy function (NULL if no RC fields) */
	msTraceProc trace;       /* TypeName_trace function (NULL if acyclic) */
	uint32_t flags;          /* bit 0 = acyclic (no cycles possible) */
} msTypeInfo;

#define MS_ACYCLIC_FLAG 1

#endif /* MS_TYPEINFO_H */
