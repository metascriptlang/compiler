#pragma once
typedef struct Corpus808Impl* Corpus808Handle;
struct Corpus808Raw;
typedef struct Corpus808Named Corpus808Named;
union Corpus808Cell;

int corpus808New(Corpus808Handle* out);
int corpus808Value(Corpus808Handle h);
void corpus808Free(Corpus808Handle h);

int corpus808NewRaw(struct Corpus808Raw** out);
int corpus808RawValue(struct Corpus808Raw* r);
void corpus808RawFree(struct Corpus808Raw* r);

int corpus808NewNamed(Corpus808Named** out);
int corpus808NamedValue(Corpus808Named* n);
void corpus808NamedFree(Corpus808Named* n);

union Corpus808Cell* corpus808MakeCell(int v);
int corpus808CellValue(union Corpus808Cell* c);
void corpus808CellFree(union Corpus808Cell* c);
