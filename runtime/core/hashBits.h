#ifndef MS_HASH_BITS_H
#define MS_HASH_BITS_H

#include <stdint.h>
#include "runtime/core/mulWide.h"

/* Raw bits for std's hash (std/core/struct.ms): the address of a Map<unknown, _>
   key and the IEEE pattern of a float key. BITS ONLY — the avalanche step is
   std's hashWangYi1, the one mixing site; a second copy here is what once let
   one copy be fixed and the other stay wrong. */
static inline uint64_t msPtrBits(const void* p) { return (uint64_t)(uintptr_t)p; }
static inline uint64_t msFloat64Bits(double d) { uint64_t u; __builtin_memcpy(&u, &d, sizeof u); return u; }
static inline double msBitsFloat64(uint64_t u) { double d; __builtin_memcpy(&d, &u, sizeof d); return d; }
static inline uint64_t msHiXorLo(uint64_t a, uint64_t b) { return msMulHi64(a, b) ^ (a * b); }
static inline uint64_t msHiXorLoPortable(uint64_t a, uint64_t b) { return msMulHi64Portable(a, b) ^ (a * b); }

#endif
