/*
 * MetaScript Manual Runtime — No RC, Optional Freestanding
 *
 * --gc=manual mode. No reference counting, no DRC injection.
 *
 * Two sub-modes controlled by MSOS_BARE (set via --os=bare):
 *   Without MSOS_BARE: malloc-backed allocation (like drc.h minus RC). Desktop use.
 *   With MSOS_BARE:    static arena, no malloc, no libc dependency. Freestanding.
 *
 * Uses same SYSTEM_H guard as core.h so prelude @include("runtime/core/system.h")
 * is a no-op when this header is included first.
 */

#ifndef SYSTEM_H
#define SYSTEM_H

/* Mark manual mode — no ARC, no ORC */
#define MSGC_MANUAL

/* Block DRC/async headers via their guards */
#define MSGC_DRC_H
#define MS_FUTURE_H
#define MS_DISPATCH_H
#define MS_THREAD_H
#define MS_COMBINATOR_H
#define MS_ABORT_H
#define MS_LOCKED_H
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
    uint32_t allocSize;
} msRefHeader;

static inline msRefHeader* msHeader(void* p) {
    return (msRefHeader*)((char*)p - sizeof(msRefHeader));
}

/* ===== Allocation ===== */

#ifdef MSOS_BARE

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

#else /* !MSOS_BARE */

/* --- Desktop: malloc-backed, same as drc.h minus RC --- */

#include <stdlib.h>

static inline void* msAlloc(size_t size) {
    msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
    h->rc = 0;
    h->rootIdx = -1;
    h->type = NULL;
    h->allocSize = (uint32_t)(sizeof(msRefHeader) + size);
    return (void*)(h + 1);
}

static inline void* msAllocTyped(size_t size, const msTypeInfo* type) {
    msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
    h->rc = 0;
    h->rootIdx = -1;
    h->type = type;
    h->allocSize = (uint32_t)(sizeof(msRefHeader) + size);
    return (void*)(h + 1);
}

#endif /* MSOS_BARE */

/* Arc<T> box: manual mode has no RC and never frees, so the rc start value is
 * irrelevant — delegate to msAllocTyped. */
static inline void* msAllocArc(size_t size, const msTypeInfo* type) {
    return msAllocTyped(size, type);
}

/* drc.h's counterpart only skips the zero-fill; the arena and the calloc path
 * both hand back zeroed memory anyway, so there is nothing to skip here. */
static inline void* msAllocTypedUninit(size_t size, const msTypeInfo* type) {
    return msAllocTyped(size, type);
}

/* ===== RC Operations (all no-ops in both modes) ===== */

static inline void  msIncRef(void* p)            { (void)p; }
static inline bool  msDecRefIsLast(void* p)       { (void)p; return false; }
static inline void  msDestroyAndDispose(void* p)  { (void)p; }
#define msWasMoved(p) ((p) = (void*)0)

/* ===== libc headers for string/array/buffer ===== */
#ifdef MSOS_SOLANA

/* Solana/BPF: truly freestanding — no libc headers available.
   Use -isystem runtime/freestanding to provide stub headers.
   Provide minimal libc functions inline. */
static inline void* memcpy(void* dst, const void* src, size_t n) {
    char* d = (char*)dst;
    const char* s = (const char*)src;
    while (n--) *d++ = *s++;
    return dst;
}
static inline void* memset(void* dst, int c, size_t n) {
    char* d = (char*)dst;
    while (n--) *d++ = (char)c;
    return dst;
}
static inline size_t strlen(const char* s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}
static inline int memcmp(const void* a, const void* b, size_t n) {
    const unsigned char *pa = (const unsigned char*)a, *pb = (const unsigned char*)b;
    while (n--) { if (*pa != *pb) return *pa - *pb; pa++; pb++; }
    return 0;
}

/* Redirect libc allocator to arena */
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

#elif defined(MSOS_BARE)

/* Freestanding: system headers available but malloc/free redirected to arena */
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

#else

/* Desktop: standard libc */
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>

#endif

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

static inline void msTestErrorFlag(void) {
    if (msErr) __builtin_trap();
}

static inline void msExit(int32_t code) {
    msTestErrorFlag();
#ifdef MSOS_BARE
    (void)code;
    __builtin_trap();
#else
    exit((int)code);
#endif
}

/* ===== I/O ===== */
#ifdef MSOS_SOLANA
/* Solana: log via sol_log_ syscall (provided by Solana runtime) */
extern uint64_t sol_log_(const char* msg, uint64_t len);
static inline void msPrintln(msString s) {
    if (s.p != (void*)0 && s.len > 0) {
        sol_log_(s.p->data, (uint64_t)s.len);
    }
}
#else
static inline void msPrintln(msString s) {
    if (s.p != NULL && s.len > 0) {
        fwrite(s.p->data, 1, (size_t)s.len, stdout);
    }
    fputc('\n', stdout);
}
#endif

/* ===== DRC Lifecycle Macros (all no-ops) ===== */

#define msStringDecref(s)     ((void)0)
#define msStringIncref(s)     ((void)0)
static inline void msStringCopy(msString* dest, msString src) { *dest = src; }
#define msStringWasMoved(s)   do { (s).len = 0; (s).p = (msStrPayload*)0; } while(0)
#define msStringSink(d, ...)  do { (d) = (__VA_ARGS__); } while(0)

#define msArrayDestroy(arr)            ((void)0)
#define msArrayWasMoved(arr)           do { (arr).len = 0; (arr).p = (void*)0; } while(0)
#define msArrayCopy1(arr)              /* no-op */
#define msArrayCopy2(d, s)             do { (d) = (s); } while(0)
#define msArrayCopy_GET(_1, _2, NAME, ...) NAME
#define msArrayCopy(...) msArrayCopy_GET(__VA_ARGS__, msArrayCopy2, msArrayCopy1)(__VA_ARGS__)
#define msArraySetLen(d, s)            do { (d).len = (s).len; } while(0)
#define msArrayNumberWasMoved(arr)     msArrayWasMoved(arr)
#define msArrayNumberSink(d, ...)      do { (d) = (__VA_ARGS__); } while(0)
#define msArrayStringDestroy(arr)      ((void)0)
#define msArrayStringCopy(d, s)        do { (d) = (s); } while(0)
#define msArrayStringWasMoved(arr)     msArrayWasMoved(arr)
#define msArrayStringSink(d, ...)      do { (d) = (__VA_ARGS__); } while(0)
#define msArrayRefDestroy(arr)         ((void)0)
#define msArrayRefCopy(d, s)           do { (d) = (s); } while(0)
#define msArrayRefSink(d, ...)         do { (d) = (__VA_ARGS__); } while(0)
#define msArrayRefTrace(arr, cb)       ((void)0)
#define msArrayRefWasMoved(arr)        msArrayWasMoved(arr)
#define msArrayUint8Destroy(arr)       ((void)0)
#define msArrayUint8WasMoved(arr)      msArrayWasMoved(arr)
#define msArrayUint8Sink(d, ...)       do { (d) = (__VA_ARGS__); } while(0)
#define msArrayClosureDestroy(arr)     ((void)0)
#define msArrayClosureCopy(d, s)       do { (d) = (s); } while(0)
#define msArrayClosureSink(d, ...)     do { (d) = (__VA_ARGS__); } while(0)
#define msArrayClosureWasMoved(arr)    msArrayWasMoved(arr)

#define msIncref(p)           ((void)0)
#define msDecref(p)           ((void)0)
#define msPtrWasMoved(p)      do { (p) = (void*)0; } while(0)
#define msIncrefCyclic(p)     ((void)0)
#define msDecrefCyclic(p)     ((void)0)
#define msAtomicIncref(p)     ((void)0)
#define msAtomicDecref(p)     ((void)0)

#define msClosureDestroy(c)   do { (c).fn = (msClosureFn)0; (c).env = (void*)0; } while(0)
#define msClosureCopy(c)      ((void)0)
#define msClosureWasMoved(c)  do { (c).fn = (msClosureFn)0; (c).env = (void*)0; } while(0)
#define msClosureSink(d, ...) do { (d) = (__VA_ARGS__); } while(0)
#define msClosureTrace(c, e)  ((void)0)

/* Cyclic ref =copy - system.h:347 without the refcount traffic. */
#define msRefCopyCyclic(d, s) do { (d) = (s); } while(0)

/* Closure array - mirrors system.h:64-82. manual.h owns the SYSTEM_H guard, so
 * runtime/core/array.c sees these only if we declare them here. */
#ifndef MS_CLOSURE_ARRAY_DEFINED
#define MS_CLOSURE_ARRAY_DEFINED
typedef struct {
    int64_t cap;
    msClosure data[];
} msClosurePayload;

typedef struct {
    int64_t len;
    msClosurePayload* p;
} msClosureArray;

#define MS_EMPTY_CLOSURE_ARRAY ((msClosureArray){0, NULL})

void msClosureArrayDestroy(msClosureArray* arr);
void msClosureArrayPush(msClosureArray* arr, msClosure value);
void msClosureArrayCopy(msClosureArray* dest, const msClosureArray* src);
void msClosureArrayWasMoved(msClosureArray* arr);
#endif

#define msMapFree(m)          ((void)0)
#define msMapCopy(m)          ((void)0)
#define msMapWasMoved(m)      do { (m).len = 0; (m).p = (void*)0; } while(0)
#define msMapSink(d, ...)     do { (d) = (__VA_ARGS__); } while(0)
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
#ifdef MSOS_BARE
    msString* p = (msString*)msArenaAlloc(sizeof(msString));
#else
    msString* p = (msString*)malloc(sizeof(msString));
#endif
    if (p) *p = v;
    return p;
}
static inline msString msUnboxString(void* p) {
    msString v = *(msString*)p;
#ifndef MSOS_BARE
    free(p);
#endif
    return v;
}
static inline void* msBoxStruct(const void* val, size_t size) {
#ifdef MSOS_BARE
    void* p = msArenaAlloc(size);
    if (p) __builtin_memcpy(p, val, size);
#else
    void* p = malloc(size);
    if (p) memcpy(p, val, size);
#endif
    return p;
}

/* ===== Locked<T> stubs (--gc=manual has no threading: the lock is a no-op) =====
 * The cell itself is an ordinary allocation whose payload the backend reaches
 * through the generated struct's field, so only the lock ops need stubbing. */
static inline void  msLockedAcquire(void* cell)              { (void)cell; }
static inline void  msLockedRelease(void* cell)              { (void)cell; }

/* ===== ORC stubs ===== */
static inline void msOrcCollect(void) {}
static inline void msOrcTraceRef(void* child, void* env) { (void)child; (void)env; }
/* Teardown critical section - drc.h:411-412 already stubs these when ORC is off;
 * manual.h owns the guard, so the same pair has to exist here. */
static inline void msOrcBeginTeardown(void) {}
static inline void msOrcEndTeardown(void) {}

/* ===== Async stubs ===== */
#ifndef MS_THREAD_LOCAL
#define MS_THREAD_LOCAL
#endif

/* Layout mirrors future.h:88-157 exactly. Two properties are load-bearing and
 * neither is cosmetic:
 *   - msFutureBase is TAGGED and MS_FUTURE_STRUCT nests it as the first field.
 *     Codegen emits a forward `typedef struct X X;` and then MS_FUTURE_STRUCT(X,..)
 *     for every instantiated Promise<T> (future.h:127). An untagged macro makes
 *     the expansion a fresh anonymous type, which collides with that forward
 *     declaration - the whole "typedef redefinition" family.
 *   - only the same set of concrete instantiations as future.h. msFuture_msString
 *     is NOT one of them: codegen emits it per module, so declaring it here is a
 *     second definition of the same tag.
 * Atomics are dropped (manual mode is single-threaded) and msFutureCb stays
 * opaque - nothing in this mode fires callbacks. */
typedef struct msFutureCb msFutureCb;

typedef struct msFutureBase {
    bool finished;
    bool failed;
    bool cancelled;
    bool crossThreadPublished;
    void* error;
    void (*valueDestructor)(void*);
    msFutureCb* callbacks;
    msFutureCb* cbTail;
    bool errorObserved;
} msFutureBase;

#define MS_FUTURE_STRUCT(name, valtype) \
    typedef struct name { msFutureBase base; valtype value; } name

typedef msFutureBase msFuture_void;
MS_FUTURE_STRUCT(msFuture_double, double);
MS_FUTURE_STRUCT(msFuture_int32, int32_t);
MS_FUTURE_STRUCT(msFuture_int64, int64_t);
MS_FUTURE_STRUCT(msFuture_bool, bool);
MS_FUTURE_STRUCT(msFuture_ptr, void*);
typedef msFuture_ptr msFuture;

/* future.h:530 without the refcount check - manual mode never frees. */
#define msFutureDrcDestroy(f) ((void)(f))

static inline void* msWaitFor(void* fut)    { (void)fut; return (void*)0; }
static inline void msWaitForReady(void* fut) { (void)fut; }
static inline void msCallSoon(msClosure cb) { (void)cb; }
typedef void (*msCallSoonFn)(msClosure);
static msCallSoonFn msCallSoonProc = (msCallSoonFn)0;
static void* msErrPayload = (void*)0;

/* ===== Abort stub ===== */
static inline void msAbortThrow(void) { msErr = true; }

#endif /* SYSTEM_H */
