#include <stdlib.h>

struct Corpus807Tag { int v; };
typedef struct Corpus807Named Corpus807Named;
struct Corpus807Named { int v; };

static inline struct Corpus807Tag* corpus807MakeTag(int v) {
	struct Corpus807Tag* t = malloc(sizeof(struct Corpus807Tag));
	t->v = v;
	return t;
}
static inline int corpus807TagValue(struct Corpus807Tag* t) { return t->v; }
static inline void corpus807TagSwap(struct Corpus807Tag** a, struct Corpus807Tag** b) {
	struct Corpus807Tag* x = *a;
	*a = *b;
	*b = x;
}
static inline void corpus807TagFree(struct Corpus807Tag* t) { free(t); }

static inline Corpus807Named* corpus807MakeNamed(int v) {
	Corpus807Named* n = malloc(sizeof(Corpus807Named));
	n->v = v;
	return n;
}
static inline int corpus807NamedValue(Corpus807Named* n) { return n->v; }
static inline void corpus807NamedFree(Corpus807Named* n) { free(n); }
