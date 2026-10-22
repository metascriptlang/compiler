typedef struct CorpusCell { int x; } CorpusCell;
typedef struct CorpusRow { int v[4]; CorpusCell cells[2]; unsigned char tag[3]; } CorpusRow;
CorpusRow corpusRowMake(void);
void corpusRowBump(CorpusRow* row);
int corpusRowSum(CorpusRow row);
extern int corpusTable[8];
