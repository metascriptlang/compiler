#include <stddef.h>

typedef void* (*CorpusAlloc)(void* ctx, size_t len);
typedef struct CorpusVt { CorpusAlloc alloc; } CorpusVt;

static char corpusSlot[4];

static inline int corpusTryAlloc(CorpusVt* v) { return v->alloc(NULL, 4) == NULL ? 1 : 0; }
static inline void* corpusSome(void) { return corpusSlot; }
static inline void* corpusNone(void) { return NULL; }
