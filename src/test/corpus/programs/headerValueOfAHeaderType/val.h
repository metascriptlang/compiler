#ifndef VAL_H
#define VAL_H
typedef struct { float value; int unit; } Val;
typedef struct Range { int lo; int hi; } Range;
extern const Val ValZero;
extern Range wholeRange;
float valOf(Val v);
int spanOf(Range r);
#endif
