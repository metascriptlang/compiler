#pragma once
#include <stdlib.h>
#include "ptr.h"

struct Corpus808Impl { int v; };
struct Corpus808Raw { int v; };
struct Corpus808Named { int v; };
union Corpus808Cell { int v; float f; };

int corpus808New(Corpus808Handle* out) { *out = malloc(sizeof(struct Corpus808Impl)); (*out)->v = 1; return 0; }
int corpus808Value(Corpus808Handle h) { return h->v; }
void corpus808Free(Corpus808Handle h) { free(h); }

int corpus808NewRaw(struct Corpus808Raw** out) { *out = malloc(sizeof(struct Corpus808Raw)); (*out)->v = 2; return 0; }
int corpus808RawValue(struct Corpus808Raw* r) { return r->v; }
void corpus808RawFree(struct Corpus808Raw* r) { free(r); }

int corpus808NewNamed(Corpus808Named** out) { *out = malloc(sizeof(Corpus808Named)); (*out)->v = 3; return 0; }
int corpus808NamedValue(Corpus808Named* n) { return n->v; }
void corpus808NamedFree(Corpus808Named* n) { free(n); }

union Corpus808Cell* corpus808MakeCell(int v) { union Corpus808Cell* c = malloc(sizeof(union Corpus808Cell)); c->v = v; return c; }
int corpus808CellValue(union Corpus808Cell* c) { return c->v; }
void corpus808CellFree(union Corpus808Cell* c) { free(c); }
