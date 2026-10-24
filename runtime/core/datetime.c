/*
 * MetaScript DateTime Runtime — C Implementation
 */

#include "runtime/core/datetime.h"
#include <stdint.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#elif defined(__linux__)
#include <linux/perf_event.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
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

double msCpuInstructions(void) {
#if defined(__APPLE__)
	struct rusage_info_v4 ri;
	if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1.0;
	return (double)ri.ri_instructions;
#elif defined(__linux__)
	static int fd = -2;
	if (fd == -2) {
		struct perf_event_attr attr;
		memset(&attr, 0, sizeof attr);
		attr.type = PERF_TYPE_HARDWARE;
		attr.size = sizeof attr;
		attr.config = PERF_COUNT_HW_INSTRUCTIONS;
		attr.exclude_kernel = 1;
		attr.exclude_hv = 1;
		fd = (int)syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
	}
	if (fd < 0) return -1.0;
	uint64_t count;
	if (read(fd, &count, sizeof count) != (ssize_t)sizeof count) return -1.0;
	return (double)count;
#else
	return -1.0;
#endif
}
