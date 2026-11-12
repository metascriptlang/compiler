// @stdout: uint8 161 2908705263
// @stdout: uint16 208 3328478502
// @stdout: uint32 261 2405805868
// @stdout: uint64 261 3589883277
// @stdout: int8 72 887289905
// @stdout: int16 90 3677228161
// @stdout: int32 132 3010193206
// @stdout: int64 132 371650758
// @stdout: uint8 as unsigned 7 2533433298
// @stdout: uint16 as unsigned 8 357259063
// @stdout: uint32 as unsigned 9 252445923
// @stdout: uint64 as unsigned 9 435047077
// @stdout: int8 as unsigned 8 342677520
// @stdout: int16 as unsigned 9 829457504
// @stdout: int32 as unsigned 11 464828124
// @stdout: int64 as unsigned 11 3763266286
// @stdout: integer-sweep 1389 1565672222
// note: every line of a group is folded into an FNV-1a hash; the pinned hashes were computed modulo 2^n outside MetaScript, so cells that agree on a wrong result still fail.

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

const eU8: uint8[] = [0, 1, 2, 127, 128, 254, 255];
const eU16: uint16[] = [0, 1, 2, 255, 256, 32768, 65534, 65535];
const eU32: uint32[] = [0, 1, 2, 65535, 65536, 2147483647, 2147483648, 4294967294, 4294967295];
const eU64: uint64[] = [0, 1, 2, 4294967295, 4294967296, 9223372036854775807, 9223372036854775808, 18446744073709551614, 18446744073709551615];
const eI8: int8[] = [-128, -127, -1, 0, 1, 2, 126, 127];
const eI16: int16[] = [-32768, -32767, -1, 0, 1, 2, 181, 32766, 32767];
const eI32: int32[] = [-2147483647 - 1, -2147483647, -65536, -1, 0, 1, 2, 46341, 65536, 2147483646, 2147483647];
const eI64: int64[] = [-9223372036854775807 - 1, -9223372036854775807, -4294967296, -1, 0, 1, 2, 3037000500, 4294967296, 9223372036854775806, 9223372036854775807];
function addU8(a: uint8, b: uint8): uint8 { return a + b; }
function addAsgU8(a: uint8, b: uint8): uint8 { let x = a; x += b; return x; }
function subU8(a: uint8, b: uint8): uint8 { return a - b; }
function subAsgU8(a: uint8, b: uint8): uint8 { let x = a; x -= b; return x; }
function mulU8(a: uint8, b: uint8): uint8 { return a * b; }
function mulAsgU8(a: uint8, b: uint8): uint8 { let x = a; x *= b; return x; }
function andU8(a: uint8, b: uint8): uint8 { return a & b; }
function andAsgU8(a: uint8, b: uint8): uint8 { let x = a; x &= b; return x; }
function orU8(a: uint8, b: uint8): uint8 { return a | b; }
function orAsgU8(a: uint8, b: uint8): uint8 { let x = a; x |= b; return x; }
function xorU8(a: uint8, b: uint8): uint8 { return a ^ b; }
function xorAsgU8(a: uint8, b: uint8): uint8 { let x = a; x ^= b; return x; }
function divU8(a: uint8, b: uint8): uint8 { return a / b; }
function modU8(a: uint8, b: uint8): uint8 { return a % b; }
function notU8(a: uint8): uint8 { return ~a; }
function incU8(a: uint8): uint8 { let x = a; x++; return x; }
function decU8(a: uint8): uint8 { let x = a; x--; return x; }
function shlU8(a: uint8, n: uint8): uint8 { return a << n; }
function shrU8(a: uint8, n: uint8): uint8 { return a >> n; }
function powU8(a: uint8, n: uint8): uint8 { return a ** n; }
for (const a of eU8) {
	note(`un ${a} ${notU8(a)} ${incU8(a)} ${decU8(a)}`);
	note(`sh ${a} ${shlU8(a, 0)} ${shlU8(a, 1)} ${shlU8(a, 7)} ${shlU8(a, 7)} ${shrU8(a, 0)} ${shrU8(a, 1)} ${shrU8(a, 7)} ${shrU8(a, 7)}`);
	note(`pow ${a} ${powU8(a, 0)} ${powU8(a, 1)} ${powU8(a, 2)} ${powU8(a, 3)} ${powU8(a, 7)}`);
	for (const b of eU8) {
		note(`bin ${a} ${b} ${addU8(a, b)} ${subU8(a, b)} ${mulU8(a, b)} ${andU8(a, b)} ${orU8(a, b)} ${xorU8(a, b)}`);
		note(`asg ${a} ${b} ${addAsgU8(a, b)} ${subAsgU8(a, b)} ${mulAsgU8(a, b)} ${andAsgU8(a, b)} ${orAsgU8(a, b)} ${xorAsgU8(a, b)}`);
		if (b != 0) note(`div ${a} ${b} ${divU8(a, b)} ${modU8(a, b)}`);
	}
}
section("uint8");
function addU16(a: uint16, b: uint16): uint16 { return a + b; }
function addAsgU16(a: uint16, b: uint16): uint16 { let x = a; x += b; return x; }
function subU16(a: uint16, b: uint16): uint16 { return a - b; }
function subAsgU16(a: uint16, b: uint16): uint16 { let x = a; x -= b; return x; }
function mulU16(a: uint16, b: uint16): uint16 { return a * b; }
function mulAsgU16(a: uint16, b: uint16): uint16 { let x = a; x *= b; return x; }
function andU16(a: uint16, b: uint16): uint16 { return a & b; }
function andAsgU16(a: uint16, b: uint16): uint16 { let x = a; x &= b; return x; }
function orU16(a: uint16, b: uint16): uint16 { return a | b; }
function orAsgU16(a: uint16, b: uint16): uint16 { let x = a; x |= b; return x; }
function xorU16(a: uint16, b: uint16): uint16 { return a ^ b; }
function xorAsgU16(a: uint16, b: uint16): uint16 { let x = a; x ^= b; return x; }
function divU16(a: uint16, b: uint16): uint16 { return a / b; }
function modU16(a: uint16, b: uint16): uint16 { return a % b; }
function notU16(a: uint16): uint16 { return ~a; }
function incU16(a: uint16): uint16 { let x = a; x++; return x; }
function decU16(a: uint16): uint16 { let x = a; x--; return x; }
function shlU16(a: uint16, n: uint16): uint16 { return a << n; }
function shrU16(a: uint16, n: uint16): uint16 { return a >> n; }
function powU16(a: uint16, n: uint16): uint16 { return a ** n; }
for (const a of eU16) {
	note(`un ${a} ${notU16(a)} ${incU16(a)} ${decU16(a)}`);
	note(`sh ${a} ${shlU16(a, 0)} ${shlU16(a, 1)} ${shlU16(a, 7)} ${shlU16(a, 15)} ${shrU16(a, 0)} ${shrU16(a, 1)} ${shrU16(a, 7)} ${shrU16(a, 15)}`);
	note(`pow ${a} ${powU16(a, 0)} ${powU16(a, 1)} ${powU16(a, 2)} ${powU16(a, 3)} ${powU16(a, 7)}`);
	for (const b of eU16) {
		note(`bin ${a} ${b} ${addU16(a, b)} ${subU16(a, b)} ${mulU16(a, b)} ${andU16(a, b)} ${orU16(a, b)} ${xorU16(a, b)}`);
		note(`asg ${a} ${b} ${addAsgU16(a, b)} ${subAsgU16(a, b)} ${mulAsgU16(a, b)} ${andAsgU16(a, b)} ${orAsgU16(a, b)} ${xorAsgU16(a, b)}`);
		if (b != 0) note(`div ${a} ${b} ${divU16(a, b)} ${modU16(a, b)}`);
	}
}
section("uint16");
function addU32(a: uint32, b: uint32): uint32 { return a + b; }
function addAsgU32(a: uint32, b: uint32): uint32 { let x = a; x += b; return x; }
function subU32(a: uint32, b: uint32): uint32 { return a - b; }
function subAsgU32(a: uint32, b: uint32): uint32 { let x = a; x -= b; return x; }
function mulU32(a: uint32, b: uint32): uint32 { return a * b; }
function mulAsgU32(a: uint32, b: uint32): uint32 { let x = a; x *= b; return x; }
function andU32(a: uint32, b: uint32): uint32 { return a & b; }
function andAsgU32(a: uint32, b: uint32): uint32 { let x = a; x &= b; return x; }
function orU32(a: uint32, b: uint32): uint32 { return a | b; }
function orAsgU32(a: uint32, b: uint32): uint32 { let x = a; x |= b; return x; }
function xorU32(a: uint32, b: uint32): uint32 { return a ^ b; }
function xorAsgU32(a: uint32, b: uint32): uint32 { let x = a; x ^= b; return x; }
function divU32(a: uint32, b: uint32): uint32 { return a / b; }
function modU32(a: uint32, b: uint32): uint32 { return a % b; }
function notU32(a: uint32): uint32 { return ~a; }
function incU32(a: uint32): uint32 { let x = a; x++; return x; }
function decU32(a: uint32): uint32 { let x = a; x--; return x; }
function shlU32(a: uint32, n: uint32): uint32 { return a << n; }
function shrU32(a: uint32, n: uint32): uint32 { return a >> n; }
function powU32(a: uint32, n: uint32): uint32 { return a ** n; }
for (const a of eU32) {
	note(`un ${a} ${notU32(a)} ${incU32(a)} ${decU32(a)}`);
	note(`sh ${a} ${shlU32(a, 0)} ${shlU32(a, 1)} ${shlU32(a, 7)} ${shlU32(a, 31)} ${shrU32(a, 0)} ${shrU32(a, 1)} ${shrU32(a, 7)} ${shrU32(a, 31)}`);
	note(`pow ${a} ${powU32(a, 0)} ${powU32(a, 1)} ${powU32(a, 2)} ${powU32(a, 3)} ${powU32(a, 7)}`);
	for (const b of eU32) {
		note(`bin ${a} ${b} ${addU32(a, b)} ${subU32(a, b)} ${mulU32(a, b)} ${andU32(a, b)} ${orU32(a, b)} ${xorU32(a, b)}`);
		note(`asg ${a} ${b} ${addAsgU32(a, b)} ${subAsgU32(a, b)} ${mulAsgU32(a, b)} ${andAsgU32(a, b)} ${orAsgU32(a, b)} ${xorAsgU32(a, b)}`);
		if (b != 0) note(`div ${a} ${b} ${divU32(a, b)} ${modU32(a, b)}`);
	}
}
section("uint32");
function addU64(a: uint64, b: uint64): uint64 { return a + b; }
function addAsgU64(a: uint64, b: uint64): uint64 { let x = a; x += b; return x; }
function subU64(a: uint64, b: uint64): uint64 { return a - b; }
function subAsgU64(a: uint64, b: uint64): uint64 { let x = a; x -= b; return x; }
function mulU64(a: uint64, b: uint64): uint64 { return a * b; }
function mulAsgU64(a: uint64, b: uint64): uint64 { let x = a; x *= b; return x; }
function andU64(a: uint64, b: uint64): uint64 { return a & b; }
function andAsgU64(a: uint64, b: uint64): uint64 { let x = a; x &= b; return x; }
function orU64(a: uint64, b: uint64): uint64 { return a | b; }
function orAsgU64(a: uint64, b: uint64): uint64 { let x = a; x |= b; return x; }
function xorU64(a: uint64, b: uint64): uint64 { return a ^ b; }
function xorAsgU64(a: uint64, b: uint64): uint64 { let x = a; x ^= b; return x; }
function divU64(a: uint64, b: uint64): uint64 { return a / b; }
function modU64(a: uint64, b: uint64): uint64 { return a % b; }
function notU64(a: uint64): uint64 { return ~a; }
function incU64(a: uint64): uint64 { let x = a; x++; return x; }
function decU64(a: uint64): uint64 { let x = a; x--; return x; }
function shlU64(a: uint64, n: uint64): uint64 { return a << n; }
function shrU64(a: uint64, n: uint64): uint64 { return a >> n; }
function powU64(a: uint64, n: uint64): uint64 { return a ** n; }
for (const a of eU64) {
	note(`un ${a} ${notU64(a)} ${incU64(a)} ${decU64(a)}`);
	note(`sh ${a} ${shlU64(a, 0)} ${shlU64(a, 1)} ${shlU64(a, 7)} ${shlU64(a, 63)} ${shrU64(a, 0)} ${shrU64(a, 1)} ${shrU64(a, 7)} ${shrU64(a, 63)}`);
	note(`pow ${a} ${powU64(a, 0)} ${powU64(a, 1)} ${powU64(a, 2)} ${powU64(a, 3)} ${powU64(a, 7)}`);
	for (const b of eU64) {
		note(`bin ${a} ${b} ${addU64(a, b)} ${subU64(a, b)} ${mulU64(a, b)} ${andU64(a, b)} ${orU64(a, b)} ${xorU64(a, b)}`);
		note(`asg ${a} ${b} ${addAsgU64(a, b)} ${subAsgU64(a, b)} ${mulAsgU64(a, b)} ${andAsgU64(a, b)} ${orAsgU64(a, b)} ${xorAsgU64(a, b)}`);
		if (b != 0) note(`div ${a} ${b} ${divU64(a, b)} ${modU64(a, b)}`);
	}
}
section("uint64");
function andI8(a: int8, b: int8): int8 { return a & b; }
function orI8(a: int8, b: int8): int8 { return a | b; }
function xorI8(a: int8, b: int8): int8 { return a ^ b; }
function notI8(a: int8): int8 { return ~a; }
function shrI8(a: int8, n: int8): int8 { return a >> n; }
for (const a of eI8) {
	note(`un ${a} ${notI8(a)} ${shrI8(a, 0)} ${shrI8(a, 1)} ${shrI8(a, 7)} ${shrI8(a, 7)}`);
	for (const b of eI8) note(`bit ${a} ${b} ${andI8(a, b)} ${orI8(a, b)} ${xorI8(a, b)}`);
}
section("int8");
function andI16(a: int16, b: int16): int16 { return a & b; }
function orI16(a: int16, b: int16): int16 { return a | b; }
function xorI16(a: int16, b: int16): int16 { return a ^ b; }
function notI16(a: int16): int16 { return ~a; }
function shrI16(a: int16, n: int16): int16 { return a >> n; }
for (const a of eI16) {
	note(`un ${a} ${notI16(a)} ${shrI16(a, 0)} ${shrI16(a, 1)} ${shrI16(a, 7)} ${shrI16(a, 15)}`);
	for (const b of eI16) note(`bit ${a} ${b} ${andI16(a, b)} ${orI16(a, b)} ${xorI16(a, b)}`);
}
section("int16");
function andI32(a: int32, b: int32): int32 { return a & b; }
function orI32(a: int32, b: int32): int32 { return a | b; }
function xorI32(a: int32, b: int32): int32 { return a ^ b; }
function notI32(a: int32): int32 { return ~a; }
function shrI32(a: int32, n: int32): int32 { return a >> n; }
for (const a of eI32) {
	note(`un ${a} ${notI32(a)} ${shrI32(a, 0)} ${shrI32(a, 1)} ${shrI32(a, 7)} ${shrI32(a, 31)}`);
	for (const b of eI32) note(`bit ${a} ${b} ${andI32(a, b)} ${orI32(a, b)} ${xorI32(a, b)}`);
}
section("int32");
function andI64(a: int64, b: int64): int64 { return a & b; }
function orI64(a: int64, b: int64): int64 { return a | b; }
function xorI64(a: int64, b: int64): int64 { return a ^ b; }
function notI64(a: int64): int64 { return ~a; }
function shrI64(a: int64, n: int64): int64 { return a >> n; }
for (const a of eI64) {
	note(`un ${a} ${notI64(a)} ${shrI64(a, 0)} ${shrI64(a, 1)} ${shrI64(a, 7)} ${shrI64(a, 63)}`);
	for (const b of eI64) note(`bit ${a} ${b} ${andI64(a, b)} ${orI64(a, b)} ${xorI64(a, b)}`);
}
section("int64");
function U8toU8(a: uint8): uint8 { return a as uint8; }
function U8toU16(a: uint8): uint16 { return a as uint16; }
function U8toU32(a: uint8): uint32 { return a as uint32; }
function U8toU64(a: uint8): uint64 { return a as uint64; }
for (const a of eU8) note(`as ${a} ${U8toU8(a)} ${U8toU16(a)} ${U8toU32(a)} ${U8toU64(a)}`);
section("uint8 as unsigned");
function U16toU8(a: uint16): uint8 { return a as uint8; }
function U16toU16(a: uint16): uint16 { return a as uint16; }
function U16toU32(a: uint16): uint32 { return a as uint32; }
function U16toU64(a: uint16): uint64 { return a as uint64; }
for (const a of eU16) note(`as ${a} ${U16toU8(a)} ${U16toU16(a)} ${U16toU32(a)} ${U16toU64(a)}`);
section("uint16 as unsigned");
function U32toU8(a: uint32): uint8 { return a as uint8; }
function U32toU16(a: uint32): uint16 { return a as uint16; }
function U32toU32(a: uint32): uint32 { return a as uint32; }
function U32toU64(a: uint32): uint64 { return a as uint64; }
for (const a of eU32) note(`as ${a} ${U32toU8(a)} ${U32toU16(a)} ${U32toU32(a)} ${U32toU64(a)}`);
section("uint32 as unsigned");
function U64toU8(a: uint64): uint8 { return a as uint8; }
function U64toU16(a: uint64): uint16 { return a as uint16; }
function U64toU32(a: uint64): uint32 { return a as uint32; }
function U64toU64(a: uint64): uint64 { return a as uint64; }
for (const a of eU64) note(`as ${a} ${U64toU8(a)} ${U64toU16(a)} ${U64toU32(a)} ${U64toU64(a)}`);
section("uint64 as unsigned");
function I8toU8(a: int8): uint8 { return a as uint8; }
function I8toU16(a: int8): uint16 { return a as uint16; }
function I8toU32(a: int8): uint32 { return a as uint32; }
function I8toU64(a: int8): uint64 { return a as uint64; }
for (const a of eI8) note(`as ${a} ${I8toU8(a)} ${I8toU16(a)} ${I8toU32(a)} ${I8toU64(a)}`);
section("int8 as unsigned");
function I16toU8(a: int16): uint8 { return a as uint8; }
function I16toU16(a: int16): uint16 { return a as uint16; }
function I16toU32(a: int16): uint32 { return a as uint32; }
function I16toU64(a: int16): uint64 { return a as uint64; }
for (const a of eI16) note(`as ${a} ${I16toU8(a)} ${I16toU16(a)} ${I16toU32(a)} ${I16toU64(a)}`);
section("int16 as unsigned");
function I32toU8(a: int32): uint8 { return a as uint8; }
function I32toU16(a: int32): uint16 { return a as uint16; }
function I32toU32(a: int32): uint32 { return a as uint32; }
function I32toU64(a: int32): uint64 { return a as uint64; }
for (const a of eI32) note(`as ${a} ${I32toU8(a)} ${I32toU16(a)} ${I32toU32(a)} ${I32toU64(a)}`);
section("int32 as unsigned");
function I64toU8(a: int64): uint8 { return a as uint8; }
function I64toU16(a: int64): uint16 { return a as uint16; }
function I64toU32(a: int64): uint32 { return a as uint32; }
function I64toU64(a: int64): uint64 { return a as uint64; }
for (const a of eI64) note(`as ${a} ${I64toU8(a)} ${I64toU16(a)} ${I64toU32(a)} ${I64toU64(a)}`);
section("int64 as unsigned");
console.log(`integer-sweep ${allLines} ${allHash}`);
