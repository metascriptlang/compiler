#include <stdint.h>

static inline void corpusKeepNearWord(void* p) {
	msHeader(p)->rc += (((int64_t)1 << 32) - 1) * MS_RC_INCREMENT;
}
