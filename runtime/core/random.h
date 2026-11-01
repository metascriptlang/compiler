#ifndef MS_CORE_RANDOM_H
#define MS_CORE_RANDOM_H

#include <stdint.h>
#include <time.h>

/* Per thread: Math.random runs on pool workers and actors (ULTRALOCK V0); a shared state races. */
static MS_THREAD_LOCAL uint64_t msMathRandState = 0;

static inline double msMathRandom(void) {
	uint64_t x = msMathRandState;
	if (x == 0) {
		x = (((uint64_t)time(NULL) * 6364136223846793005ULL) ^ ((uint64_t)(uintptr_t)&msMathRandState * 0x9E3779B97F4A7C15ULL)) | 1;
	}
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	msMathRandState = x;
	return (double)(x >> 11) / 9007199254740992.0;
}

#endif
