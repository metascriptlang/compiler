#include <stdlib.h>
#include "szInner.h"
#include "runtime/core/string.h"

static inline size_t szTwice(size_t n) { return n * 2; }
static inline void szStore(size_t *out, size_t v) { *out = v + 1; }
