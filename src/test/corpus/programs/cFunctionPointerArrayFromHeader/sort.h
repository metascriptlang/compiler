typedef int (*CorpusUnary)(int);

typedef struct CorpusTable { CorpusUnary fs[2]; int k; } CorpusTable;
typedef struct CorpusTriple { int k; CorpusUnary fs[3]; } CorpusTriple;
typedef struct CorpusOuter { CorpusTable inner; } CorpusOuter;

static inline CorpusTable corpusMakeTable(void) { CorpusTable t = { { 0, 0 }, 3 }; return t; }
static inline CorpusTriple corpusMakeTriple(void) { CorpusTriple t = { 0, { 0, 0, 0 } }; return t; }
static inline CorpusOuter corpusMakeOuter(void) { CorpusOuter o = { { { 0, 0 }, 0 } }; return o; }
