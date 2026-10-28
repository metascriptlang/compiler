typedef void (*CorpusFn)(int);

static inline void corpusCallIt(CorpusFn f) { f(7); }
static inline int corpusSetOpt(int option, const void* value) { ((CorpusFn)value)(option); return 0; }
