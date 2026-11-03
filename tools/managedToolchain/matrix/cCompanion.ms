@include("./cCompanion.h");
@compile("./cCompanion.c");

extern function matrixCValue(): int32;

console.log("matrix-c", matrixCValue());
