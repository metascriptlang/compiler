#include "priv.h"
#include "a.h"
static struct Res resPool[4];
static union Cell cellPool[4];
static int resUsed, cellUsed;
ResRef makeRes(int v) { ResRef r = &resPool[resUsed++ % 4]; r->v = v; return r; }
CellRef makeCell(int v) { CellRef c = &cellPool[cellUsed++ % 4]; c->i = v; return c; }
