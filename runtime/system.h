/*
 * MetaScript System Header — Master Include
 * This is the single header that generated C code includes.
 * It pulls in ARC, String, and Array runtimes.
 */
#ifndef SYSTEM_H
#define SYSTEM_H

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

/* ARC foundation (refcount, alloc, typeinfo) */
#include "mem/arc.h"

/* ORC cycle collector (behind MS_ORC flag; no-op stubs otherwise) */
#include "mem/orc.h"

/* String runtime (msString, all string ops) */
#include "core/string.h"

/* Array runtime (msNumberArray, msStringArray, msRefArray) */
#include "core/array.h"

/* ===== Type Aliases (C89 portability + codegen convenience) ===== */
typedef bool MS_BOOL;
#define MS_TRUE true
#define MS_FALSE false
#define MS_NIL NULL

/* ===== I/O ===== */

void msPrintln(msString s);

/* ===== DRC Lifecycle Stubs ===== */

/* Global error flag (exception handling) */
extern bool msErr;

/* Closure type for lifecycle hooks */
typedef void (*msClosureFn)(void*, ...);
typedef struct {
	msClosureFn fn;
	void* env;
} msClosure;

/* Exception handling */
typedef struct {
	const char* message;
	int code;
} msException;

extern MS_BOOL msErr;
extern msException* msCurrException;
void msClearException(void);

/* ===== DRC Lifecycle Macros ===== */
/* DRC passes args by value — macros access the variable directly for mutation. */

/* --- String lifecycle --- */
#define msStringDecref(s)     msStringDestroy(s)
#define msStringIncref(s)     do { \
	if ((s).p != NULL && !msIsLiteral(s)) { \
		msString __c = msStringNew((s).p->data, (s).len); \
		(s) = __c; \
	} \
} while(0)
#define msStringWasMoved(s)   do { (s).len = 0; (s).p = NULL; } while(0)
#define msStringSink(d, s)    do { msStringDestroy(d); (d) = (s); } while(0)

/* --- Number array lifecycle --- */
#define msArrayDestroy(arr)            msNumberArrayDestroy(&(arr))
#define msArrayCopy(arr)               /* TODO: deep copy */
#define msArrayNumberWasMoved(arr)     do { (arr).len = 0; (arr).p = NULL; } while(0)
#define msArrayNumberSink(d, s)        do { msNumberArrayDestroy(&(d)); (d) = (s); } while(0)

/* --- String array lifecycle --- */
#define msArrayStringDestroy(arr)      msStringArrayDestroy(&(arr))
#define msArrayStringCopy(arr)         /* TODO: deep copy with per-element string copy */
#define msArrayStringWasMoved(arr)     do { (arr).len = 0; (arr).p = NULL; } while(0)
#define msArrayStringSink(d, s)        do { msStringArrayDestroy(&(d)); (d) = (s); } while(0)

/* --- Ref array lifecycle --- */
#define msArrayRefDestroy(arr)         msRefArrayDestroy(&(arr))
#define msArrayRefCopy(arr)            /* TODO: deep copy with per-element msIncRef */
#define msArrayRefWasMoved(arr)        do { (arr).len = 0; (arr).p = NULL; } while(0)
#define msArrayRefTrace(arr)           /* TODO: ORC trace */

/* --- Ref/Ptr lifecycle (generic heap objects) --- */
#define msIncref(p)           msIncRef(p)
#define msDecref(p)           do { \
	if ((p) != NULL && msDecRefIsLast(p)) { \
		const msTypeInfo* __t = msHeader(p)->type; \
		if (__t != NULL && __t->destroyFn != NULL) __t->destroyFn(p); \
		msDestroyAndDispose(p); \
	} \
} while(0)
#define msPtrWasMoved(p)      msWasMoved(p)

/* --- ORC-aware ref lifecycle for cyclic types (Nim's atomicRefOp parity) --- */
#ifdef MS_ORC
#define msIncrefCyclic(p)     do { if ((p) != NULL) msOrcIncRef(p); } while(0)
#define msDecrefCyclic(p)     do { \
	if ((p) != NULL && msOrcDecRefIsLast(p)) { \
		const msTypeInfo* __t = msHeader(p)->type; \
		if (__t != NULL && __t->destroyFn != NULL) __t->destroyFn(p); \
		msDestroyAndDispose(p); \
	} \
} while(0)
#else
#define msIncrefCyclic(p)     msIncref(p)
#define msDecrefCyclic(p)     msDecref(p)
#endif

/* --- Closure lifecycle --- */
#define msClosureDestroy(c)   do { if ((c).env != NULL) { msDecref((c).env); } (c).fn = NULL; (c).env = NULL; } while(0)
#define msClosureCopy(c)      do { if ((c).env != NULL) msIncRef((c).env); } while(0)
#define msClosureWasMoved(c)  do { (c).fn = NULL; (c).env = NULL; } while(0)
#define msClosureSink(d, s)   do { msClosureDestroy(d); (d) = (s); } while(0)
#define msClosureTrace(c)     /* TODO: ORC trace */

/* --- Map lifecycle (stubs) --- */
typedef struct { void* impl; } msMap;
#define msMapFree(m)          do { (m).impl = NULL; } while(0)
#define msMapCopy(m)          /* no-op stub */
#define msMapWasMoved(m)      do { (m).impl = NULL; } while(0)
#define msMapSink(d, s)       do { (d) = (s); } while(0)
#define msMapTrace(m)         /* no-op stub */

/* --- Set lifecycle (stubs) --- */
typedef struct { void* impl; } msSet;
#define msSetFree(s)          do { (s).impl = NULL; } while(0)
#define msSetCopy(s)          /* no-op stub */

/* --- Named object wasMoved (no-op for value-type named objects) --- */
#define msObjectWasMoved(p)   /* no-op */

/* ===== Error Reporting ===== */

/* Bounds check failure — prints error and exits */
_Noreturn void msRaiseIndexError(int64_t idx, int64_t len);

/* ===== Bounds-Checked Array Access Macros ===== */
/* GCC statement expressions returning lvalues via dereferenced-pointer trick.
   Both reads (x = msNumberArrayAccess(a, i)) and writes (msNumberArrayAccess(a, i) = x) work. */

#define msNumberArrayAccess(a, i) (*({ \
	int32_t __idx = (i); \
	if ((uint32_t)__idx >= (uint32_t)(a).len) msRaiseIndexError(__idx, (a).len); \
	&((a).p->data[__idx]); \
}))

#define msStringArrayAccess(a, i) (*({ \
	int32_t __idx = (i); \
	if ((uint32_t)__idx >= (uint32_t)(a).len) msRaiseIndexError(__idx, (a).len); \
	&((a).p->data[__idx]); \
}))

#define msRefArrayAccess(a, i) (*({ \
	int32_t __idx = (i); \
	if ((uint32_t)__idx >= (uint32_t)(a).len) msRaiseIndexError(__idx, (a).len); \
	&((a).p->data[__idx]); \
}))

#define msSizedArrayAccess(a, i, n) (*({ \
	int32_t __idx = (i); \
	if ((uint32_t)__idx >= (uint32_t)(n)) msRaiseIndexError(__idx, (n)); \
	&((a).data[__idx]); \
}))

#define msSpanAccess(a, i) (*({ \
	int32_t __idx = (i); \
	if ((uint32_t)__idx >= (uint32_t)(a).len) msRaiseIndexError(__idx, (a).len); \
	&((a).data[__idx]); \
}))

/* String char access is read-only — no lvalue trick needed */
#define msStringCharAccess(s, i) ({ \
	int32_t __idx = (i); \
	if ((uint32_t)__idx >= (uint32_t)(s).len) msRaiseIndexError(__idx, (s).len); \
	msStringCharAt((s), __idx); \
})

#endif /* SYSTEM_H */
