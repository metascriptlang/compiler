// @stdout: int8 88 4152369109
// @stdout: int16 108 3833168687
// @stdout: int32 154 1729076889
// @stdout: int64 154 2639579906
// @stdout: danger-sweep 504 2478192136
// @xfail(c): the default build stops on a signed overflow instead of wrapping
// @xfail(js): the default JS build stops on a signed overflow instead of wrapping
// @xfail(esm): the default JS build stops on a signed overflow instead of wrapping
// @xfail(san): the SAN lane builds in the default mode, which stops on a signed overflow instead of wrapping
// @skip-raiser: the raiser stops on a signed overflow and writes it to stderr
// note: --danger drops the overflow check and signed arithmetic wraps in two's complement on C and JS alike; every line of a group is folded into an FNV-1a hash, and the pinned hashes were computed outside MetaScript.

let hash: uint32 = 2166136261;
let lines: int32 = 0;
let allHash: uint32 = 2166136261;
let allLines: int32 = 0;

function note(line: string): void {
	for (const c of line) {
		hash = (hash ^ (c as uint32)) * 16777619;
		allHash = (allHash ^ (c as uint32)) * 16777619;
	}
	lines += 1;
	allLines += 1;
}

function section(name: string): void {
	console.log(`${name} ${lines} ${hash}`);
	hash = 2166136261;
	lines = 0;
}

const eI8: int8[] = [-128, -127, -1, 0, 1, 2, 126, 127];
function addI8(a: int8, b: int8): int8 { return a + b; }
function addAsgI8(a: int8, b: int8): int8 { let x = a; x += b; return x; }
function subI8(a: int8, b: int8): int8 { return a - b; }
function subAsgI8(a: int8, b: int8): int8 { let x = a; x -= b; return x; }
function mulI8(a: int8, b: int8): int8 { return a * b; }
function mulAsgI8(a: int8, b: int8): int8 { let x = a; x *= b; return x; }
function negI8(a: int8): int8 { return -a; }
function incI8(a: int8): int8 { let x = a; x++; return x; }
function decI8(a: int8): int8 { let x = a; x--; return x; }
function preIncI8(a: int8): int8 { let x = a; return ++x; }
function shlI8(a: int8, n: int8): int8 { return a << n; }
function powI8(a: int8, n: int8): int8 { return a ** n; }
for (const a of eI8) {
	note(`un ${a} ${negI8(a)} ${incI8(a)} ${decI8(a)} ${preIncI8(a)}`);
	note(`shl ${a} ${shlI8(a, 1)} ${shlI8(a, 7)} ${shlI8(a, 7)}`);
	note(`pow ${a} ${powI8(a, 0)} ${powI8(a, 1)} ${powI8(a, 2)} ${powI8(a, 3)} ${powI8(a, 7)}`);
	for (const b of eI8) {
		note(`bin ${a} ${b} ${addI8(a, b)} ${subI8(a, b)} ${mulI8(a, b)} ${addAsgI8(a, b)} ${subAsgI8(a, b)} ${mulAsgI8(a, b)}`);
	}
}
section("int8");
const eI16: int16[] = [-32768, -32767, -1, 0, 1, 2, 181, 32766, 32767];
function addI16(a: int16, b: int16): int16 { return a + b; }
function addAsgI16(a: int16, b: int16): int16 { let x = a; x += b; return x; }
function subI16(a: int16, b: int16): int16 { return a - b; }
function subAsgI16(a: int16, b: int16): int16 { let x = a; x -= b; return x; }
function mulI16(a: int16, b: int16): int16 { return a * b; }
function mulAsgI16(a: int16, b: int16): int16 { let x = a; x *= b; return x; }
function negI16(a: int16): int16 { return -a; }
function incI16(a: int16): int16 { let x = a; x++; return x; }
function decI16(a: int16): int16 { let x = a; x--; return x; }
function preIncI16(a: int16): int16 { let x = a; return ++x; }
function shlI16(a: int16, n: int16): int16 { return a << n; }
function powI16(a: int16, n: int16): int16 { return a ** n; }
for (const a of eI16) {
	note(`un ${a} ${negI16(a)} ${incI16(a)} ${decI16(a)} ${preIncI16(a)}`);
	note(`shl ${a} ${shlI16(a, 1)} ${shlI16(a, 7)} ${shlI16(a, 15)}`);
	note(`pow ${a} ${powI16(a, 0)} ${powI16(a, 1)} ${powI16(a, 2)} ${powI16(a, 3)} ${powI16(a, 7)}`);
	for (const b of eI16) {
		note(`bin ${a} ${b} ${addI16(a, b)} ${subI16(a, b)} ${mulI16(a, b)} ${addAsgI16(a, b)} ${subAsgI16(a, b)} ${mulAsgI16(a, b)}`);
	}
}
section("int16");
const eI32: int32[] = [-2147483647 - 1, -2147483647, -65536, -1, 0, 1, 2, 46341, 65536, 2147483646, 2147483647];
function addI32(a: int32, b: int32): int32 { return a + b; }
function addAsgI32(a: int32, b: int32): int32 { let x = a; x += b; return x; }
function subI32(a: int32, b: int32): int32 { return a - b; }
function subAsgI32(a: int32, b: int32): int32 { let x = a; x -= b; return x; }
function mulI32(a: int32, b: int32): int32 { return a * b; }
function mulAsgI32(a: int32, b: int32): int32 { let x = a; x *= b; return x; }
function negI32(a: int32): int32 { return -a; }
function incI32(a: int32): int32 { let x = a; x++; return x; }
function decI32(a: int32): int32 { let x = a; x--; return x; }
function preIncI32(a: int32): int32 { let x = a; return ++x; }
function shlI32(a: int32, n: int32): int32 { return a << n; }
function powI32(a: int32, n: int32): int32 { return a ** n; }
for (const a of eI32) {
	note(`un ${a} ${negI32(a)} ${incI32(a)} ${decI32(a)} ${preIncI32(a)}`);
	note(`shl ${a} ${shlI32(a, 1)} ${shlI32(a, 7)} ${shlI32(a, 31)}`);
	note(`pow ${a} ${powI32(a, 0)} ${powI32(a, 1)} ${powI32(a, 2)} ${powI32(a, 3)} ${powI32(a, 7)}`);
	for (const b of eI32) {
		note(`bin ${a} ${b} ${addI32(a, b)} ${subI32(a, b)} ${mulI32(a, b)} ${addAsgI32(a, b)} ${subAsgI32(a, b)} ${mulAsgI32(a, b)}`);
	}
}
section("int32");
const eI64: int64[] = [-9223372036854775807 - 1, -9223372036854775807, -4294967296, -1, 0, 1, 2, 3037000500, 4294967296, 9223372036854775806, 9223372036854775807];
function addI64(a: int64, b: int64): int64 { return a + b; }
function addAsgI64(a: int64, b: int64): int64 { let x = a; x += b; return x; }
function subI64(a: int64, b: int64): int64 { return a - b; }
function subAsgI64(a: int64, b: int64): int64 { let x = a; x -= b; return x; }
function mulI64(a: int64, b: int64): int64 { return a * b; }
function mulAsgI64(a: int64, b: int64): int64 { let x = a; x *= b; return x; }
function negI64(a: int64): int64 { return -a; }
function incI64(a: int64): int64 { let x = a; x++; return x; }
function decI64(a: int64): int64 { let x = a; x--; return x; }
function preIncI64(a: int64): int64 { let x = a; return ++x; }
function shlI64(a: int64, n: int64): int64 { return a << n; }
function powI64(a: int64, n: int64): int64 { return a ** n; }
for (const a of eI64) {
	note(`un ${a} ${negI64(a)} ${incI64(a)} ${decI64(a)} ${preIncI64(a)}`);
	note(`shl ${a} ${shlI64(a, 1)} ${shlI64(a, 7)} ${shlI64(a, 63)}`);
	note(`pow ${a} ${powI64(a, 0)} ${powI64(a, 1)} ${powI64(a, 2)} ${powI64(a, 3)} ${powI64(a, 7)}`);
	for (const b of eI64) {
		note(`bin ${a} ${b} ${addI64(a, b)} ${subI64(a, b)} ${mulI64(a, b)} ${addAsgI64(a, b)} ${subAsgI64(a, b)} ${mulAsgI64(a, b)}`);
	}
}
section("int64");
console.log(`danger-sweep ${allLines} ${allHash}`);
