/*
 * MetaScript DateTime Runtime — C Implementation
 */

#include "runtime/core/datetime.h"
#include <stdint.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
#endif

double msTimeNow(void) {
#if defined(_WIN32)
	FILETIME ft;
	GetSystemTimeAsFileTime(&ft);
	uint64_t t = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
	/* FILETIME: 100-ns ticks since 1601-01-01. Unix epoch = 1970-01-01.
	 * Offset 116444736000000000 * 100ns = 11644473600 * 1s. */
	return (double)(t - 116444736000000000ULL) / 10000.0;
#elif defined(__APPLE__) || defined(__linux__)
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
#else
	return 0.0;
#endif
}

double msTimeMonotonic(void) {
#if defined(_WIN32)
	LARGE_INTEGER freq, cnt;
	QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&cnt);
	return (double)(cnt.QuadPart * 1000) / (double)freq.QuadPart;
#elif defined(__APPLE__) || defined(__linux__)
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
#else
	return 0.0;
#endif
}
