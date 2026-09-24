#include <stdlib.h>
#include "handle.h"

struct Corpus805Impl { int v; };
struct Corpus805Raw { int w; };

int corpus805New(const Corpus805Config* cfg, Corpus805Handle* out) {
	*out = malloc(sizeof(struct Corpus805Impl));
	(*out)->v = cfg == NULL ? 7 : cfg->base;
	return 0;
}
int corpus805Value(Corpus805Handle h) { return h->v; }
void corpus805Free(Corpus805Handle h) { free(h); }

int corpus805NewRaw(struct Corpus805Raw** out) {
	*out = malloc(sizeof(struct Corpus805Raw));
	(*out)->w = 11;
	return 1;
}
int corpus805RawValue(struct Corpus805Raw* r) { return r->w; }
void corpus805RawFree(struct Corpus805Raw* r) { free(r); }
