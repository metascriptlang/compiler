// @stdout: 44 44 false 1 -128 24464 | 127 0 2 32640 124 -8 | -3 -1 0 -128 | 4052555153018976267 1 1024 0 | 255 0 127 -128 0 65535
// @xfail(raiser): Raiser keeps an 8/16-bit result unwrapped, computes ** in doubles and has no >>> (same on the baseline)
// note: an 8- or 16-bit result wraps at its own width whether or not it is stored (codegen-c-4: C printed 300 inline and 44 once stored, JS 300 always; uint16 65535 * 65535 overflowed C's promoted int). Division, a remainder and an integer power in range give the same value on every backend (codegen-c-9, codegen-c-10: `**` went through the double pow).

function addU8(s: uint8, t: uint8): uint8 { return s + t; }
function mulU16(a: uint16, b: uint16): uint16 { return a * b; }
function mulU16Wide(a: uint16, b: uint16): uint16 { return a * b; }
function addI8(a: int8, b: int8): int8 { return a + b; }
function negI8(a: int8): int8 { return -a; }
function notU8(a: uint8): uint8 { return ~a; }
function shlU8(a: uint8, n: uint8): uint8 { return a << n; }
function shlI16(a: int16, n: int16): int16 { return a << n; }
function ushrI8(a: int8, n: int8): int8 { return a >>> n; }
function divI32(a: int32, b: int32): int32 { return a / b; }
function modI32(a: int32, b: int32): int32 { return a % b; }
function divI8(a: int8, b: int8): int8 { return a / b; }
function powI64(a: int64, b: int64): int64 { return a ** b; }
function powI32(a: int32, b: int32): int32 { return a ** b; }

function stepU8(a: uint8): string {
	let x = a;
	const before = x++;
	return `${before} ${x}`;
}

function stepI8(a: int8): string {
	let x = a;
	const before = x++;
	return `${before} ${x}`;
}

function stepU16(a: uint16): string {
	let x = a;
	return `${--x} ${--x}`;
}

function inline(s: uint8, t: uint8): string {
	const u = s + t;
	return `${s + t} ${u} ${(s + t) > 255}`;
}

const row1 = `${inline(200, 100)} ${mulU16(65535, 65535)} ${addI8(127, 1)} ${mulU16Wide(300, 300)}`;
const row2 = `${negI8(-127)} ${notU8(255)} ${shlU8(1, 9)} ${shlI16(255, 7)} ${ushrI8(-8, 1)} ${ushrI8(-8, 8)}`;
const row3 = `${divI32(-7, 2)} ${modI32(-7, 2)} ${divI32(0, 5)} ${divI8(-128, -1)}`;
const row4 = `${powI64(3, 39)} ${powI32(-1, 7) * powI32(-1, 7)} ${powI32(2, 10)} ${powI32(0, 3)}`;
const row5 = `${stepU8(255)} ${stepI8(127)} ${stepU16(1)}`;
console.log(`${row1} | ${row2} | ${row3} | ${row4} | ${row5}`);
