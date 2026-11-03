@include("./ubsanCompanion.h");
@compile("./ubsanCompanion.c");

extern function matrixUbValue(extra: int32): int32;

console.log("matrix-ub", matrixUbValue(1));
