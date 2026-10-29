#include <stdint.h>
#include <stddef.h>

typedef struct CorpusPair { int32_t a; int32_t b; int32_t c; int32_t d; } CorpusPair;
typedef void (*CorpusByteSink)(void*, const uint8_t*, size_t);
typedef void (*CorpusPairSink)(void*, const CorpusPair*);

static inline void corpusRunByteSink(CorpusByteSink f) { static const uint8_t bytes[3] = {7, 8, 9}; f(0, bytes, 3); }
static inline void corpusRunPairSink(CorpusPairSink f) { static const CorpusPair pair = {1, 2, 3, 4}; f(0, &pair); }
