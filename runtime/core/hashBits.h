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

static inline uint64_t msLoadLE64Raw(const uint8_t* p) {
	uint64_t v;
	__builtin_memcpy(&v, p, sizeof v);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
	v = __builtin_bswap64(v);
#endif
	return v;
}

static inline uint64_t msLoadLE32Raw(const uint8_t* p) {
	uint32_t v;
	__builtin_memcpy(&v, p, sizeof v);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
	v = __builtin_bswap32(v);
#endif
	return v;
}

#define msLoadLE_(data, len, o, width, raw) ({ \
	int64_t __o = (o); \
	if (__o < 0 || __o > (int64_t)(len) - (width)) msRaiseIndexError(__o, (len)); \
	raw((const uint8_t*)(data) + __o); \
})
#define msLoadLE64(data, len, o) msLoadLE_(data, len, o, 8, msLoadLE64Raw)
#define msLoadLE32(data, len, o) msLoadLE_(data, len, o, 4, msLoadLE32Raw)

#endif
