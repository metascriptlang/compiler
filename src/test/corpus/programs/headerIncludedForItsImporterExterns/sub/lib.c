#include "lib.h"
const int32_t libLimit = 7;
int32_t imported(void) { return 40; }
int64_t sumBytes(const uint8_t *b, int64_t n) { int64_t s = 0; for (int64_t i = 0; i < n; i++) s += b[i]; return s; }
