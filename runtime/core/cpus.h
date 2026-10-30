#ifndef MS_CPUS_H
#define MS_CPUS_H

#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#endif

/* The CPUs this process may run on (os.availableParallelism): the affinity mask on Linux,
   the online count elsewhere. 0 when the host does not say. */
static inline int msAvailableCpus(void) {
#ifdef _WIN32
	SYSTEM_INFO si;
	GetSystemInfo(&si);
	return (int)si.dwNumberOfProcessors;
#else
#if defined(__linux__) && defined(SYS_sched_getaffinity)
	unsigned char mask[1024 / 8] = {0};
	long bytes = syscall(SYS_sched_getaffinity, 0, sizeof mask, mask);
	if (bytes > 0) {
		int n = 0;
		for (long i = 0; i < bytes; i++) n += __builtin_popcount(mask[i]);
		if (n > 0) return n;
	}
#endif
#ifdef _SC_NPROCESSORS_ONLN
	return (int)sysconf(_SC_NPROCESSORS_ONLN);
#else
	return 0;
#endif
#endif
}

#endif
