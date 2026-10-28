#include <stdlib.h>

typedef int (*CorpusCompare)(const void *, const void *);

void qsort(void *base, size_t count, size_t width, CorpusCompare compare);
void *bsearch(const void *key, const void *base, size_t count, size_t width, CorpusCompare compare);
