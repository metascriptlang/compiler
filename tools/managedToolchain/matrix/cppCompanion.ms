@include("./cppCompanion.h");
@compile("./cppCompanion.cpp", "-std=c++20");

extern function matrixCppValue(): int32;

console.log("matrix-cpp", matrixCppValue());
