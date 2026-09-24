#include <stdlib.h>

struct Corpus809Tag { int v; };
typedef struct Corpus809Named Corpus809Named;
struct Corpus809Named { int v; };

static inline struct Corpus809Tag* corpus809MakeTag(int v) {
	struct Corpus809Tag* t = malloc(sizeof(struct Corpus809Tag));
	t->v = v;
	return t;
}
static inline int corpus809TagValue(struct Corpus809Tag* t) { return t->v; }
static inline void corpus809TagSwap(struct Corpus809Tag** a, struct Corpus809Tag** b) {
	struct Corpus809Tag* x = *a;
	*a = *b;
	*b = x;
}
static inline void corpus809TagFree(struct Corpus809Tag* t) { free(t); }

static inline Corpus809Named* corpus809MakeNamed(int v) {
	Corpus809Named* n = malloc(sizeof(Corpus809Named));
	n->v = v;
	return n;
}
static inline int corpus809NamedValue(Corpus809Named* n) { return n->v; }
static inline void corpus809NamedFree(Corpus809Named* n) { free(n); }
