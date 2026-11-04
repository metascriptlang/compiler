#pragma GCC diagnostic error "-Wincompatible-pointer-types"

typedef struct CorpusPaImpl *CorpusPaH;
typedef const char *CorpusPaName;

CorpusPaH corpusPaMake(int v);
int corpusPaSum(const CorpusPaH *hs, int n);
int corpusPaLen(const CorpusPaName *ns, int n);
