#include "fixed.h"
int corpusTable[8] = {5, 6, 7, 8, 9, 10, 11, 12};
CorpusRow corpusRowMake(void) { CorpusRow r = {{1, 2, 3, 4}, {{7}, {8}}, {'a', 'b', 0}}; return r; }
void corpusRowBump(CorpusRow* row) { row->v[0] += 100; }
int corpusRowSum(CorpusRow row) { return row.v[0] + row.v[1] + row.v[2] + row.v[3]; }
