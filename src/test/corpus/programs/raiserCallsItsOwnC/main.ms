// A program calls its own C on every backend that links C: functions of an imported header with its
// companion `.c`, and `extern function` declarations of an included header and its `.c`. Axes: int, int64, uint8,
// float32, float64 and boolean arguments and results, a C string argument, no result.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 7 7.5 1.25 -9000000000 44 5 2
// @stdout: 42 13.5 2.5
// @exit: 0

import { nativeAdd, nativeScale, nativeHalf, nativeWide, nativeByte, nativeLen, nativeCount, nativeCounted } from "./native.h";
@include("./more.h");
@compile("./more.c");
extern function moreTwice(x: int32): int32;
extern function moreMix(x: float64, n: int64, flag: boolean): float64;

nativeCount();
nativeCount();
console.log(`${nativeAdd(3, 4)} ${nativeScale(2.5, 3)} ${nativeHalf(2.5)} ${nativeWide(-3000000000)} ${nativeByte(300)} ${nativeLen("hello")} ${nativeCounted()}`);
console.log(`${moreTwice(21)} ${moreMix(1.5, 12, true)} ${moreMix(4.5, 2, false)}`);
