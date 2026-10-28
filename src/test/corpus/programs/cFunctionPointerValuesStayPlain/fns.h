typedef int (*CorpusPlainUnary)(int);

typedef struct CorpusPlainOne { CorpusPlainUnary f; int k; } CorpusPlainOne;
typedef struct CorpusPlainPair { CorpusPlainUnary fs[2]; int k; } CorpusPlainPair;
