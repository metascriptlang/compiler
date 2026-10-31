#include <stdint.h>
#ifndef __linux__
static inline int32_t corpusRaiseNoFile(int32_t n) { (void)n; return 0; }
#else
#include <sys/resource.h>

static inline int32_t corpusRaiseNoFile(int32_t n) {
	struct rlimit r;
	if (getrlimit(RLIMIT_NOFILE, &r) != 0) return -1;
	if (r.rlim_cur >= (rlim_t)n) return 0;
	r.rlim_cur = r.rlim_max < (rlim_t)n ? r.rlim_max : (rlim_t)n;
	if (setrlimit(RLIMIT_NOFILE, &r) != 0) return -1;
	return r.rlim_cur >= (rlim_t)n ? 0 : -1;
}
#endif
