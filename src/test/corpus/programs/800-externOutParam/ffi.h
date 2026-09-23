#include <stdint.h>

typedef struct { uint32_t cb; int16_t mode; uint64_t size; } Corpus800Info;

static inline void corpus800SetU32(uint32_t* p) { *p = 42; }
static inline void corpus800AddI64(int64_t* p) { *p += 1000000000000LL; }
static inline void corpus800Fill(Corpus800Info* p) { p->cb = 7; p->mode = -3; p->size = 1ULL << 40; }
