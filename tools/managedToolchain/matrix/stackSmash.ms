@include("./stackSmash.h");
@compile("./stackSmash.c");

extern function matrixSmash(extra: int32): int32;

console.log("matrix-smash", matrixSmash(24));
console.log("matrix-smash survived");
