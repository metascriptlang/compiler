// @stdout: -5,-300,250,65535,4000000000
// @stdout: -9007199254740993,18446744073709551615,0.5
// @stdout: -5,65535,4000000000,18446744073709551615,true
// @stdout: -300,200
// @stdout: true,-5,65535,18446744073709551615
// @stdout: 1,18446744073709551615
// @stdout: -300,0,32767
// @stdout: -127,6,-5
import { echoI8, echoI16, echoU8, echoU16, echoU32, echoI64, echoU64, echoF32, viaI8, viaU16, viaU32, viaU64, viaBool, viaPair, echoWide, echoVecU64, echoVecI16, swapEndsI8, Wide } from "./wireMatrixWasm";

console.log(`${echoI8(-5)},${echoI16(-300)},${echoU8(250)},${echoU16(65535)},${echoU32(4000000000)}`);
console.log(`${echoI64(-9007199254740993)},${echoU64(18446744073709551615)},${echoF32(0.5)}`);
console.log(`${viaI8(-5, (v: int8): int8 => v)},${viaU16(65535, (v: uint16): uint16 => v)},${viaU32(4000000000, (v: uint32): uint32 => v)},${viaU64(18446744073709551615, (v: uint64): uint64 => v)},${viaBool(true, (v: boolean): boolean => v)}`);
viaPair(-300, 200, (a: int16, b: uint8): void => {
	console.log(`${a},${b}`);
});
const input: Wide = { inner: { flag: true, small: -5 }, half: 65535, big: 18446744073709551615 };
const w = echoWide(input);
console.log(`${w.inner.flag},${w.inner.small},${w.half},${w.big}`);
const big: Vec<uint64> = [1, 18446744073709551615];
console.log(echoVecU64(big).join(","));
const shorts: Vec<int16> = [-300, 0, 32767];
console.log(echoVecI16(shorts).join(","));
let bytes: Vec<int8> = [-5, 6, -127];
swapEndsI8(bytes);
console.log(bytes.join(","));
