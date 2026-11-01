/* AArch64 stand-in for the two x86 names the pinned dudect.h cpucycles() uses; see ../PROVENANCE. */
#ifndef X25519_DUDECT_ARM_SHIM_H
#define X25519_DUDECT_ARM_SHIM_H
#if !defined(__aarch64__)
#error "armShim is only for AArch64; on x86 the real <x86intrin.h> must be found"
#endif
#include <stdint.h>

static inline void _mm_mfence(void) {
	__asm__ volatile("dsb sy" ::: "memory");
}

static inline uint64_t __rdtsc(void) {
	uint64_t ticks;
	__asm__ volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(ticks)::"memory");
	return ticks;
}
#endif
