#ifndef BLOCK_REDUCE_GUARD_FUZZ_H
#define BLOCK_REDUCE_GUARD_FUZZ_H
#include <stdint.h>
int64_t msTestBlockReduceMismatches(int64_t cases);
int64_t msTestBlockReduceStops(void);
int64_t msTestBlockReduceFastBlocks(void);
#endif
