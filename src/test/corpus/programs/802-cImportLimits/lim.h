#include <limits.h>
#include "limInner.h"

typedef enum { CORPUS802_LOW = 0, CORPUS802_MAX = INT_MAX } Corpus802Sentinel;

static inline int corpus802IntMax(void) { return INT_MAX; }
static inline long long corpus802Sentinel(void) { return (long long)CORPUS802_MAX; }
