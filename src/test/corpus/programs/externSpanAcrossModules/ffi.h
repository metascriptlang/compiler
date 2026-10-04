#include <stdint.h>

static inline int64_t corpusSpanSum(const int64_t* data, int64_t length) {
	int64_t t = 0;
	for (int64_t i = 0; i < length; i++) t += data[i];
	return t;
}
static inline void corpusSpanFill(int64_t* data, int64_t length, int64_t v) {
	for (int64_t i = 0; i < length; i++) data[i] = v + i;
}
