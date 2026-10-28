typedef int (*CorpusLitUnary)(int);

typedef struct CorpusLitInts { int xs[2]; } CorpusLitInts;
typedef struct CorpusLitFns { CorpusLitUnary fs[2]; int k; } CorpusLitFns;
typedef struct CorpusLitOuter { CorpusLitInts inner; int k; } CorpusLitOuter;
