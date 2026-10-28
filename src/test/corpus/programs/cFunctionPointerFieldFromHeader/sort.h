#include <stdlib.h>

typedef int (*CorpusCompare)(const void *, const void *);
typedef int (*CorpusUnary)(int);

typedef struct CorpusSorter { CorpusCompare compare; int width; } CorpusSorter;
typedef struct CorpusOp { CorpusUnary op; int k; } CorpusOp;

void qsort(void *base, size_t count, size_t width, CorpusCompare compare);
