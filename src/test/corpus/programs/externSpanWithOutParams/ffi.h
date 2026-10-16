#include <stdint.h>

static inline void corpusSpanThenOut(const uint8_t* d, int64_t n, uint64_t* w) { *w = (uint64_t)n + d[0]; }
static inline void corpusOutSpanOut(uint64_t* a, const uint8_t* d, int64_t n, uint64_t* b) { *a = (uint64_t)n; *b = d[1]; }
static inline void corpusSpanOutScalar(const uint8_t* d, int64_t n, uint64_t* w, int64_t k) { *w = (uint64_t)(n * k) + d[0]; }
static inline void corpusTwoSpans(const uint8_t* d1, int64_t n1, uint64_t* m, const uint8_t* d2, int64_t n2, uint64_t* t) { *m = (uint64_t)n1 + d2[0]; *t = (uint64_t)(n1 + n2) + d1[3]; }
