@include("./sharedLibrary.h");
@compile("./sharedLibrary.c");

extern function matrixLibraryValue(): int32;

console.log("matrix-lib", matrixLibraryValue());
