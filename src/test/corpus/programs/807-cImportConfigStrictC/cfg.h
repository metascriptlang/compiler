typedef struct { int base; int step; } Corpus807Config;
typedef struct Corpus807Tagged { int k; } Corpus807Tagged;

static inline int corpus807Sum(const Corpus807Config* c) { return c == 0 ? -1 : c->base + c->step; }
static inline int corpus807Tag(const Corpus807Tagged* t) { return t == 0 ? -1 : t->k; }
static inline void corpus807Bump(Corpus807Config* c) { c->base += 100; }
