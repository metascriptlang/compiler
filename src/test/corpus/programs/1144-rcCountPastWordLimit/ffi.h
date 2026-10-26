#include <stdint.h>

static inline void corpus1144NearWrap(void* p, int64_t sign) {
	msHeader(p)->rc += sign * (((int64_t)1 << 32) - 4 * MS_RC_INCREMENT);
}

static int64_t corpus1144AtomicV = 0;

static inline int64_t corpus1144AtomicCrossings(void) {
	static msTypeInfo shared = { .name = "Corpus1144Shared", .flags = MS_TYPE_FLAG_ATOMIC };
	int64_t* cell = (int64_t*)msAllocArc(sizeof(int64_t), &shared);
	*cell = 42;
	corpus1144NearWrap(cell, 1);
	for (int i = 0; i < 8; i++) msAtomicIncRef(cell);
	int64_t last = 0;
	for (int i = 0; i < 8; i++) last += msAtomicDecRefIsLast(cell);
	corpus1144NearWrap(cell, -1);
	corpus1144AtomicV = *cell;
	msAtomicDecref(cell);
	return last;
}

static inline int64_t corpus1144AtomicValue(void) { return corpus1144AtomicV; }
