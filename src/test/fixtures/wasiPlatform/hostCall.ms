@include("./hostCall.h");

extern function hostValue(key: int32): int32;
extern function hostFinish(value: int32): void;

const capacity = hostValue(1);
const count = hostValue(2);
hostFinish(count < capacity ? capacity - count : 0);
