#include <stdint.h>

static inline void corpus1144NearWrap(void* p, int64_t sign) {
	msHeader(p)->rc += sign * (((int64_t)1 << 32) - 4 * MS_RC_INCREMENT);
}

static inline int64_t corpus1144AtomicCrossings(void* p) {
	for (int i = 0; i < 8; i++) msAtomicIncRef(p);
	int64_t last = 0;
	for (int i = 0; i < 8; i++) last += msAtomicDecRefIsLast(p);
	return last;
}
