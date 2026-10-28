typedef int (*CorpusNullUnary)(int);

typedef struct CorpusNullBox { CorpusNullUnary f; } CorpusNullBox;
typedef struct CorpusNullTable { CorpusNullUnary fs[2]; } CorpusNullTable;

static inline CorpusNullBox corpusNullEmptyBox(void) { CorpusNullBox b = { 0 }; return b; }
