#include <errno.h>
#include <stdint.h>

static int32_t corpusExternCounter = 1;
static inline int32_t corpusReadCounter(void) { return corpusExternCounter; }
static inline int32_t corpusReadErrno(void) { return errno; }
