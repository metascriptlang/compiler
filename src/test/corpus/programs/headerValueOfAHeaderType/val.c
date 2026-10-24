#include "val.h"
const Val ValZero = {0.0f, 0};
Range wholeRange = {1, 9};
float valOf(Val v) { return v.value; }
int spanOf(Range r) { return r.hi - r.lo; }
