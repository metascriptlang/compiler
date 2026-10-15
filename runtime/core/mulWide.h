#ifndef MS_MUL_WIDE_H
#define MS_MUL_WIDE_H

#include <stdint.h>

static inline uint64_t msMulHi64Portable(uint64_t a, uint64_t b) {
	uint64_t aLo = a & 0xFFFFFFFF, aHi = a >> 32;
	uint64_t bLo = b & 0xFFFFFFFF, bHi = b >> 32;
	uint64_t p00 = aLo * bLo, p01 = aLo * bHi, p10 = aHi * bLo, p11 = aHi * bHi;
	uint64_t mid1 = p10 + (p00 >> 32);
	uint64_t mid2 = p01 + (mid1 & 0xFFFFFFFF);
	return p11 + (mid1 >> 32) + (mid2 >> 32);
}

static inline uint64_t msMulHi64(uint64_t a, uint64_t b) {
#ifdef __SIZEOF_INT128__
	return (uint64_t)(((unsigned __int128)a * b) >> 64);
#else
	return msMulHi64Portable(a, b);
#endif
}

#endif
