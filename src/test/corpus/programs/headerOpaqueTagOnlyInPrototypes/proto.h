#ifndef OPAQUE_PROTO_H
#define OPAQUE_PROTO_H
int nodeVal(struct Node* n);
struct Node* nodeNew(int v);
int numVal(union Num* n);
union Num* numNew(int v);
#endif
