#ifndef OPAQUE_A_H
#define OPAQUE_A_H
typedef struct Res* ResRef;
typedef union Cell* CellRef;
ResRef makeRes(int v);
CellRef makeCell(int v);
#endif
