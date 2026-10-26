@include("string.h");

import { intToString, uint64ToString, numberToString } from "./digits";

extern function msStringNew(data: cstring, length: int64): string;
extern function msFloat64Bits(d: float64): uint64;
extern function cFloor(x: float64): float64 from "floor";

const smallPointAt = 64;
const widePointAt = 1100;
const exactIntegerLimit: float64 = 9007199254740992.0;
const smallestNarrow: float64 = 0.00390625;

@inline
function digitByte(digit: int32): uint8 {
	return (digit < 10 ? 48 + digit : 87 + digit) as uint8;
}

@inline
function digitValue(byte: uint8): int32 {
	return byte > 57 ? (byte as int32) - 87 : (byte as int32) - 48;
}

@inline
function checkedRadix(radix: float64): int32 {
	if (!(radix >= 2.0 && radix < 37.0)) {
		throw new RangeError("toString() radix argument must be between 2 and 36");
	}
	return radix as int32;
}

@inline
function nextDouble(v: float64): float64 {
	const cell: uint64[1] = [msFloat64Bits(v) + 1];
	return (((cell as Span<uint64>) as Ptr<uint64>) as Ptr<float64>)[0];
}

@inline
function writeRadixEndingAt(out: Span<uint8>, end: int32, value: uint64, radix: int32): int32 {
	const r = radix as uint64;
	let at = end;
	let rest = value;
	while (true) {
		at -= 1;
		out[at] = digitByte((rest % r) as int32);
		rest /= r;
		if (rest == 0) break;
	}
	return at;
}

@exportName("msUint64ToStringRadix")
export function uint64ToStringRadix(value: uint64, radix: float64): string {
	const r = checkedRadix(radix);
	if (r == 10) return uint64ToString(value);
	let scratch: uint8[66] = [];
	const out: Span<uint8> = scratch;
	const start = writeRadixEndingAt(out, 65, value, r);
	return msStringNew(((scratch as Span<uint8>) as Ptr<uint8> + start) as cstring, (65 - start) as int64);
}

@exportName("msIntToStringRadix")
export function intToStringRadix(value: int64, radix: float64): string {
	const r = checkedRadix(radix);
	if (r == 10) return intToString(value);
	let scratch: uint8[66] = [];
	const out: Span<uint8> = scratch;
	const negative = value < 0;
	const magnitude = negative ? (0 as uint64) - (value as uint64) : value as uint64;
	let start = writeRadixEndingAt(out, 65, magnitude, r);
	if (negative) {
		start -= 1;
		out[start] = 45;
	}
	return msStringNew(((scratch as Span<uint8>) as Ptr<uint8> + start) as cstring, (65 - start) as int64);
}

@exportName("msNumberToStringRadix")
export function numberToStringRadix(input: float64, radix: float64): string {
	const r = checkedRadix(radix);
	if (r == 10 || input != input || input == 0.0 || input - input != 0.0) return numberToString(input);
	const magnitude = input < 0.0 ? -input : input;
	if (magnitude >= smallestNarrow && magnitude < exactIntegerLimit) {
		let scratch: uint8[128] = [];
		return finiteRadixText(scratch, smallPointAt, input, r);
	}
	let scratch: uint8[2200] = [];
	return finiteRadixText(scratch, widePointAt, input, r);
}

@noinline
function finiteRadixText(buf: Span<uint8>, pointAt: int32, input: float64, r: int32): string {
	const rf = r as float64;
	const negative = input < 0.0;
	const value = negative ? -input : input;
	let integer = cFloor(value);
	let fraction = value - integer;
	let delta = 0.5 * (nextDouble(value) - value);
	if (delta < 5e-324) delta = 5e-324;
	let integerCursor = pointAt;
	let fractionCursor = pointAt;
	if (fraction >= delta) {
		buf[fractionCursor] = 46;
		fractionCursor += 1;
		while (true) {
			fraction *= rf;
			delta *= rf;
			const digit = fraction as int32;
			buf[fractionCursor] = digitByte(digit);
			fractionCursor += 1;
			fraction -= digit as float64;
			if ((fraction > 0.5 || (fraction == 0.5 && (digit & 1) == 1)) && fraction + delta > 1.0) {
				while (true) {
					fractionCursor -= 1;
					if (fractionCursor == pointAt) {
						integer += 1.0;
						break;
					}
					const prev = digitValue(buf[fractionCursor]);
					if (prev + 1 < r) {
						buf[fractionCursor] = digitByte(prev + 1);
						fractionCursor += 1;
						break;
					}
				}
				break;
			}
			if (!(fraction >= delta)) break;
		}
	}
	while (integer / rf >= exactIntegerLimit) {
		integer /= rf;
		integerCursor -= 1;
		buf[integerCursor] = 48;
	}
	while (true) {
		const remainder = integer % rf;
		integerCursor -= 1;
		buf[integerCursor] = digitByte(remainder as int32);
		integer = (integer - remainder) / rf;
		if (!(integer > 0.0)) break;
	}
	if (negative) {
		integerCursor -= 1;
		buf[integerCursor] = 45;
	}
	return msStringNew(((buf as Span<uint8>) as Ptr<uint8> + integerCursor) as cstring, (fractionCursor - integerCursor) as int64);
}
