@compile("./bareHeapChecks.c");
@compile("./bareHeapOtherUnit.c");
@include("./bareHeapChecks.h");

extern function msBareHeapUseAfterFree(): int32;

console.log(msBareHeapUseAfterFree());
