@include("./objcCompanion.h");
@compile("./objcCompanion.m", "-fobjc-arc");
@passL("-framework Foundation");

extern function matrixObjcLength(): int32;

console.log("matrix-objc", matrixObjcLength());
