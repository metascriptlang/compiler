struct Node { int v; };
union Num { int i; float f; };
#include "proto.h"
static struct Node nodePool[4];
static union Num numPool[4];
static int nodeUsed, numUsed;
struct Node* nodeNew(int v) { struct Node* n = &nodePool[nodeUsed++ % 4]; n->v = v; return n; }
int nodeVal(struct Node* n) { return n->v; }
union Num* numNew(int v) { union Num* n = &numPool[numUsed++ % 4]; n->i = v; return n; }
int numVal(union Num* n) { return n->i; }
