#include <string.h>
#include "elems.h"

struct CorpusPaImpl { int v; };
static struct CorpusPaImpl corpusPaStore[4];

CorpusPaH corpusPaMake(int v) { corpusPaStore[v & 3].v = v; return &corpusPaStore[v & 3]; }
int corpusPaSum(const CorpusPaH *hs, int n) { int s = 0; for (int i = 0; i < n; i++) if (hs[i]) s += hs[i]->v; return s; }
int corpusPaLen(const CorpusPaName *ns, int n) { int s = 0; for (int i = 0; i < n; i++) if (ns[i]) s += (int)strlen(ns[i]); return s; }
