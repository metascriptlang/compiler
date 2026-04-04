/*
 * MetaScript Manual Runtime — No RC, Optional Freestanding
 *
 * --gc=manual mode. No reference counting, no DRC injection.
 *
 * Two sub-modes controlled by MS_BARE (set via --os=bare):
 *   Without MS_BARE: malloc-backed allocation (like drc.h minus RC). Desktop use.
 *   With MS_BARE:    static arena, no malloc, no libc dependency. Freestanding.
 *
 * Uses same SYSTEM_H guard as core.h so prelude @include("runtime/core/system.h")
 * is a no-op when this header is included first.
 */

#ifndef SYSTEM_H
#define SYSTEM_H

/* Mark manual mode so .c files can skip DRC-specific implementations */
#define MS_MANUAL_MODE

/* Block all DRC/async headers via their guards */
#define MS_DRC_H
#define MS_ARC_H
#define MS_ORC_H
#define MS_FUTURE_H
#define MS_DISPATCH_H
#define MS_THREAD_H
#define MS_COMBINATOR_H
#define MS_ABORT_H
#define MS_LOCKER_H
#define MS_POOL_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "runtime/types.h"

/* ===== RefHeader (same layout as drc.h) ===== */

typedef struct {
    int32_t rc;
    int32_t rootIdx;
    const msTypeInfo* type;
} msRefHeader;

static inline msRefHeader* msHeader(void* p) {
    return (msRefHeader*)((char*)p - sizeof(msRefHeader));
}

/* ===== Allocation ===== */

#ifdef MS_BARE

/* --- Freestanding: static arena, no malloc --- */

#ifndef MS_ARENA_SIZE
#define MS_ARENA_SIZE (256 * 1024)  /* 256KB default */
#endif

static char   _ms_arena[MS_ARENA_SIZE];
static size_t _ms_arena_pos = 0;

static inline void* msArenaAlloc(size_t size) {
    size = (size + 7) & ~(size_t)7;
    if (_ms_arena_pos + size > MS_ARENA_SIZE) return (void*)0;
    void* p = &_ms_arena[_ms_arena_pos];
    _ms_arena_pos += size;
    __builtin_memset(p, 0, size);
    return p;
}

static inline void* msArenaRealloc(void* old, size_t old_size, size_t new_size) {
    void* p = msArenaAlloc(new_size);
    if (p && old && old_size > 0) {
        size_t copy_size = old_size < new_size ? old_size : new_size;
        __builtin_memcpy(p, old, copy_size);
    }
    return p;
}

static inline void msArenaReset(void) { _ms_arena_pos = 0; }

static inline void* msAlloc(size_t size) {
    void* block = msArenaAlloc(sizeof(msRefHeader) + size);
    if (!block) return (void*)0;
    return (void*)((char*)block + sizeof(msRefHeader));
}

static inline void* msAllocTyped(size_t size, const msTypeInfo* type) {
    void* block = msArenaAlloc(sizeof(msRefHeader) + size);
    if (!block) return (void*)0;
    msRefHeader* h = (msRefHeader*)block;
    h->type = type;
    return (void*)(h + 1);
}

#else /* !MS_BARE */

/* --- Desktop: malloc-backed, same as drc.h minus RC --- */

#include <stdlib.h>

static inline void* msAlloc(size_t size) {
    msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
    h->rc = 0;
    h->rootIdx = -1;
    h->type = NULL;
    return (void*)(h + 1);
}

static inline void* msAllocTyped(size_t size, const msTypeInfo* type) {
    msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
    h->rc = 0;
    h->rootIdx = -1;
    h->type = type;
    return (void*)(h + 1);
}

#endif /* MS_BARE */

/* ===== RC Operations (all no-ops in both modes) ===== */

static inline void  msIncRef(void* p)            { (void)p; }
static inline bool  msDecRefIsLast(void* p)       { (void)p; return false; }
static inline void  msDestroyAndDispose(void* p)  { (void)p; }
#define msWasMoved(p) ((p) = (void*)0)

/* ===== libc headers for string/array/buffer ===== */
#ifndef MS_BARE
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>
#else
/* Freestanding: system headers needed but malloc/free redirected to arena */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>

/* Redirect libc allocator to arena — only in freestanding mode.
   System headers already parsed above, so macros only affect
   function bodies in .h inlines and .c files compiled with -include. */
static inline void* _ms_manual_realloc(void* old, size_t new_size) {
    if (!old) return msArenaAlloc(new_size);
    return msArenaRealloc(old, new_size, new_size);
}
static inline void* _ms_manual_calloc(size_t n, size_t size) {
    return msArenaAlloc(n * size);
}
#define malloc(s)     msArenaAlloc(s)
#define calloc(n, s)  _ms_manual_calloc((n), (s))
#define realloc(p, s) _ms_manual_realloc((p), (s))
#define free(p)       ((void)(p))
#endif /* MS_BARE */

/* ===== String runtime ===== */
#include "runtime/core/string.h"

/* ===== Array runtime ===== */
#include "runtime/core/array.h"

/* ===== Buffer runtime ===== */
#include "runtime/core/buffer.h"

/* ===== Type Aliases ===== */
typedef bool MS_BOOL;
#define MS_TRUE  true
#define MS_FALSE false
#define MS_NIL   NULL

/* ===== Closure Types ===== */
typedef void    (*msClosureFn)(void*, ...);
typedef double  (*msClosureFnD)(void*, ...);
typedef MS_BOOL (*msClosureFnB)(void*, ...);
typedef msString (*msClosureFnS)(void*, ...);
typedef int32_t (*msClosureFnI)(void*, ...);
typedef int64_t (*msClosureFnI64)(void*, ...);
typedef void*   (*msClosureFnP)(void*, ...);

#ifndef MS_CLOSURE_DEFINED
#define MS_CLOSURE_DEFINED
typedef struct {
    msClosureFn fn;
    void* env;
} msClosure;
#endif

/* ===== Exception Handling (static, no TLS) ===== */
typedef struct {
    const char* message;
    int code;
} msException;

static bool msErr = false;
static msException* msCurrException = (msException*)0;

static inline void msClearException(void) {
    msErr = false;
    msCurrException = (msException*)0;
}

static inline void msThrow(msString msg) {
    (void)msg;
    msErr = true;
}

/* ===== I/O ===== */
static inline void msPrintln(msString s) {
    if (s.p != NULL && s.len > 0) {
        fwrite(s.p->data, 1, (size_t)s.len, stdout);
    }
    fputc('\n', stdout);
}

/* ===== DRC Lifecycle Macros (all no-ops) ===== */

#define msStringDecref(s)     ((void)0)
#define msStringIncref(s)     ((void)0)
static inline void msStringCopy(msString* dest, msString src) { *dest = src; }
#define msStringWasMoved(s)   do { (s).len = 0; (s).p = (msStrPayload*)0; } while(0)
#define msStringSink(d, s)    do { (d) = (s); } while(0)

#define msArrayDestroy(arr)            ((void)0)
#define msArrayWasMoved(arr)           do { (arr).len = 0; (arr).p = (void*)0; } while(0)
#define msArrayCopy1(arr)              /* no-op */
#define msArrayCopy2(d, s)             do { (d) = (s); } while(0)
#define msArrayCopy_GET(_1, _2, NAME, ...) NAME
#define msArrayCopy(...) msArrayCopy_GET(__VA_ARGS__, msArrayCopy2, msArrayCopy1)(__VA_ARGS__)
#define msArraySetLen(d, s)            do { (d).len = (s).len; } while(0)
#define msArrayNumberWasMoved(arr)     msArrayWasMoved(arr)
#define msArrayNumberSink(d, s)        do { (d) = (s); } while(0)
#define msArrayStringDestroy(arr)      ((void)0)
#define msArrayStringCopy(d, s)        do { (d) = (s); } while(0)
#define msArrayStringWasMoved(arr)     msArrayWasMoved(arr)
#define msArrayStringSink(d, s)        do { (d) = (s); } while(0)
#define msArrayRefDestroy(arr)         ((void)0)
#define msArrayRefCopy(d, s)           do { (d) = (s); } while(0)
#define msArrayRefTrace(arr, cb)       ((void)0)
#define msArrayRefWasMoved(arr)        msArrayWasMoved(arr)
#define msArrayUint8Destroy(arr)       ((void)0)
#define msArrayUint8WasMoved(arr)      msArrayWasMoved(arr)
#define msArrayUint8Sink(d, s)         do { (d) = (s); } while(0)

#define msIncref(p)           ((void)0)
#define msDecref(p)           ((void)0)
#define msPtrWasMoved(p)      do { (p) = (void*)0; } while(0)
#define msIncrefCyclic(p)     ((void)0)
#define msDecrefCyclic(p)     ((void)0)

#define msClosureDestroy(c)   do { (c).fn = (msClosureFn)0; (c).env = (void*)0; } while(0)
#define msClosureCopy(c)      ((void)0)
#define msClosureWasMoved(c)  do { (c).fn = (msClosureFn)0; (c).env = (void*)0; } while(0)
#define msClosureSink(d, s)   do { (d) = (s); } while(0)
#define msClosureTrace(c, e)  ((void)0)

#define msMapFree(m)          ((void)0)
#define msMapCopy(m)          ((void)0)
#define msMapWasMoved(m)      do { (m).len = 0; (m).p = (void*)0; } while(0)
#define msMapSink(d, s)       do { (d) = (s); } while(0)
#define msMapTrace(m)         ((void)0)

#define msObjectWasMoved(p)   /* no-op */

/* ===== Bounds-Checked Access ===== */
_Noreturn static inline void msRaiseIndexError(int64_t idx, int64_t len) {
    (void)idx; (void)len;
    __builtin_trap();
}

_Noreturn static inline void msRaiseRangeError(int64_t val, int64_t lo, int64_t hi) {
    (void)val; (void)lo; (void)hi;
    __builtin_trap();
}

#define msArrayAccess(a, i) (*({ \
    int32_t __idx = (i); \
    if ((uint32_t)__idx >= (uint32_t)(a).len) msRaiseIndexError(__idx, (a).len); \
    &((a).p->data[__idx]); \
}))
#define msNumberArrayAccess msArrayAccess
#define msStringArrayAccess msArrayAccess
#define msRefArrayAccess    msArrayAccess
#define msUint8ArrayAccess  msArrayAccess

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

#define msStringCharAccess(s, i) msStringCharAt((s), (i))

/* ===== Range-Checked Integer Casts ===== */
static inline int8_t   msCheckRangeI8(double v, int64_t lo, int64_t hi)  { int64_t iv=(int64_t)v; if(iv<lo||iv>hi) msRaiseRangeError(iv,lo,hi); return (int8_t)iv; }
static inline uint8_t  msCheckRangeU8(double v, int64_t lo, int64_t hi)  { int64_t iv=(int64_t)v; if(iv<lo||iv>hi) msRaiseRangeError(iv,lo,hi); return (uint8_t)iv; }
static inline int16_t  msCheckRangeI16(double v, int64_t lo, int64_t hi) { int64_t iv=(int64_t)v; if(iv<lo||iv>hi) msRaiseRangeError(iv,lo,hi); return (int16_t)iv; }
static inline uint16_t msCheckRangeU16(double v, int64_t lo, int64_t hi) { int64_t iv=(int64_t)v; if(iv<lo||iv>hi) msRaiseRangeError(iv,lo,hi); return (uint16_t)iv; }
static inline int32_t  msCheckRangeI32(double v, int64_t lo, int64_t hi) { int64_t iv=(int64_t)v; if(iv<lo||iv>hi) msRaiseRangeError(iv,lo,hi); return (int32_t)iv; }
static inline uint32_t msCheckRangeU32(double v, int64_t lo, int64_t hi) { int64_t iv=(int64_t)v; if(iv<lo||iv>hi) msRaiseRangeError(iv,lo,hi); return (uint32_t)iv; }

/* ===== Boxing ===== */
static inline void* msBoxString(msString v) {
#ifdef MS_BARE
    msString* p = (msString*)msArenaAlloc(sizeof(msString));
#else
    msString* p = (msString*)malloc(sizeof(msString));
#endif
    if (p) *p = v;
    return p;
}
static inline msString msUnboxString(void* p) {
    msString v = *(msString*)p;
#ifndef MS_BARE
    free(p);
#endif
    return v;
}
static inline void* msBoxStruct(const void* val, size_t size) {
#ifdef MS_BARE
    void* p = msArenaAlloc(size);
    if (p) __builtin_memcpy(p, val, size);
#else
    void* p = malloc(size);
    if (p) memcpy(p, val, size);
#endif
    return p;
}

/* ===== Locker stubs (no threading) ===== */
static inline void* msLockerCreate(int dataSize)             { return msAlloc((size_t)dataSize); }
static inline void* msLockerCreateFrom(const void* s, int n) { (void)s; return msAlloc((size_t)n); }
static inline void  msLockerLock(void* p)                    { (void)p; }
static inline void  msLockerUnlock(void* p)                  { (void)p; }
static inline double msLockerGetDouble(void* p)              { return *(double*)((char*)p + 16); }
static inline void  msLockerSetDouble(void* p, double v)     { *(double*)((char*)p + 16) = v; }
static inline int32_t msLockerGetInt32(void* p)              { return *(int32_t*)((char*)p + 16); }
static inline void  msLockerSetInt32(void* p, int32_t v)     { *(int32_t*)((char*)p + 16) = v; }
static inline void  msLockerDestroy(void* p)                 { (void)p; }

/* ===== ORC stubs ===== */
static inline void msOrcCollect(void) {}
static inline void msOrcTraceRef(void* child, void* env) { (void)child; (void)env; }

/* ===== Async stubs ===== */
#ifndef MS_THREAD_LOCAL
#define MS_THREAD_LOCAL
#endif

#define MS_FUTURE_STRUCT(name, valtype) \
    typedef struct { bool finished; bool failed; bool cancelled; bool isBoxed; void* error; valtype value; } name

typedef struct { bool finished; bool failed; bool cancelled; bool isBoxed; void* error; } msFutureBase;
typedef msFutureBase msFuture_void;
typedef struct { bool finished; bool failed; bool cancelled; bool isBoxed; void* error; void* value; } msFuture_ptr;
MS_FUTURE_STRUCT(msFuture_double, double);
MS_FUTURE_STRUCT(msFuture_int32, int32_t);
MS_FUTURE_STRUCT(msFuture_int64, int64_t);
MS_FUTURE_STRUCT(msFuture_bool, bool);
MS_FUTURE_STRUCT(msFuture_msString, msString);

static inline void* msWaitFor(void* fut)    { (void)fut; return (void*)0; }
static inline void msCallSoon(msClosure cb) { (void)cb; }
typedef void (*msCallSoonFn)(msClosure);
static msCallSoonFn msCallSoonProc = (msCallSoonFn)0;
static void* msErrPayload = (void*)0;

/* ===== Abort stub ===== */
static inline void msAbortThrow(void) { msErr = true; }

#endif /* SYSTEM_H */
