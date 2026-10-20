@include("./platformProbe.h");

extern function wasiEntropyChecks(): int32;
extern function wasiClockMilliseconds(): int64;

console.log(wasiEntropyChecks());
console.log(wasiClockMilliseconds());
