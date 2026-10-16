export extern function msStringParseFloat(v: string): float64 from "msStringParseFloat";

export const infinity: float64 = 1e308 * 10.0;
export const notANumber: float64 = infinity - infinity;

export function isDigitByte(b: int32): boolean {
	return b >= "0".code && b <= "9".code;
}

export function spaceLength(sb: Readonly<Span<uint8>>, i: int32): int32 {
	const n = sb.length;
	const b = sb[i] as int32;
	if (b == " ".code || (b >= "\t".code && b <= "\r".code)) return 1;
	if (b == 0xC2) return i + 1 < n && sb[i + 1] == 0xA0 ? 2 : 0;
	if (i + 2 >= n) return 0;
	const b1 = sb[i + 1] as int32;
	const b2 = sb[i + 2] as int32;
	if (b == 0xE1) return b1 == 0x9A && b2 == 0x80 ? 3 : 0;
	if (b == 0xE2) {
		const spaceRun = b2 >= 0x80 && b2 <= 0x8A;
		if (b1 == 0x80 && (spaceRun || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF)) return 3;
		return b1 == 0x81 && b2 == 0x9F ? 3 : 0;
	}
	if (b == 0xE3) return b1 == 0x80 && b2 == 0x80 ? 3 : 0;
	if (b == 0xEF) return b1 == 0xBB && b2 == 0xBF ? 3 : 0;
	return 0;
}

export function skipSpace(sb: Readonly<Span<uint8>>, start: int32): int32 {
	let i = start;
	while (i < sb.length) {
		const w = spaceLength(sb, i);
		if (w == 0) break;
		i += w;
	}
	return i;
}

export function trailingSpaceLength(sb: Readonly<Span<uint8>>, start: int32, end: int32): int32 {
	for (let w = 1; w <= 3; w++) {
		if (end - w >= start && spaceLength(sb, end - w) == w) return w;
	}
	return 0;
}

export function startsInfinity(sb: Readonly<Span<uint8>>, i: int32): boolean {
	const word = "Infinity".asBytes();
	if (i + word.length > sb.length) return false;
	for (let k = 0; k < word.length; k++) {
		if (sb[i + k] != word[k]) return false;
	}
	return true;
}

export function decimalEnd(sb: Readonly<Span<uint8>>, start: int32, end: int32): int32 {
	let i = start;
	while (i < end && isDigitByte(sb[i] as int32)) i++;
	let digits = i - start;
	if (i < end && sb[i] == ".".code) {
		const fracStart = i + 1;
		i = fracStart;
		while (i < end && isDigitByte(sb[i] as int32)) i++;
		digits += i - fracStart;
	}
	if (digits == 0) return -1;
	if (i < end && (sb[i] == "e".code || sb[i] == "E".code)) {
		let k = i + 1;
		if (k < end && (sb[k] == "+".code || sb[k] == "-".code)) k++;
		const expStart = k;
		while (k < end && isDigitByte(sb[k] as int32)) k++;
		if (k > expStart) i = k;
	}
	return i;
}

export function digitValue(b: int32): int32 {
	if (isDigitByte(b)) return b - "0".code;
	if (b >= "a".code && b <= "z".code) return b - "a".code + 10;
	if (b >= "A".code && b <= "Z".code) return b - "A".code + 10;
	return 99;
}

export function radixShift(b: int32): int32 {
	if (b == "x".code || b == "X".code) return 4;
	if (b == "o".code || b == "O".code) return 3;
	if (b == "b".code || b == "B".code) return 1;
	return 0;
}

export function powerOfTwoDigitsToNumber(
	sb: Readonly<Span<uint8>>,
	start: int32,
	end: int32,
	shift: int32,
): float64 {
	const radix = 1 << shift;
	let top: uint64 = 0;
	let bits = 0;
	let sticky = false;
	for (let i = start; i < end; i++) {
		const d = digitValue(sb[i] as int32);
		if (d >= radix) return notANumber;
		for (let j = shift - 1; j >= 0; j--) {
			const bit = ((d >> j) & 1) as uint64;
			if (bits == 0 && bit == 0) continue;
			if (bits < 64) {
				top = (top << 1) | bit;
			} else if (bit != 0) {
				sticky = true;
			}
			bits++;
		}
	}
	if (start == end) return notANumber;
	if (bits <= 53) return top as float64;
	const drop = (bits < 64 ? bits : 64) - 53;
	let kept = top >> (drop as uint64);
	const guard = (top >> ((drop - 1) as uint64)) & 1;
	if ((top & (((1 as uint64) << ((drop - 1) as uint64)) - 1)) != 0) sticky = true;
	if (guard == 1 && (sticky || (kept & 1) == 1)) kept += 1;
	let v = kept as float64;
	for (let e = bits - 53; e > 0 && v - v == 0.0; e--) v *= 2.0;
	return v;
}

export function stringToNumber(s: string): float64 {
	const sb = s.asBytes();
	const start = skipSpace(sb, 0);
	let end = sb.length;
	while (end > start) {
		const w = trailingSpaceLength(sb, start, end);
		if (w == 0) break;
		end -= w;
	}
	if (start == end) return 0.0;
	if (end - start > 2 && sb[start] == "0".code) {
		const shift = radixShift(sb[start + 1] as int32);
		if (shift > 0) return powerOfTwoDigitsToNumber(sb, start + 2, end, shift);
	}
	let i = start;
	const sign = sb[i] as int32;
	if (sign == "+".code || sign == "-".code) i++;
	if (startsInfinity(sb, i) && i + 8 == end) return sign == "-".code ? -infinity : infinity;
	if (decimalEnd(sb, i, end) != end) return notANumber;
	return msStringParseFloat(s.byteSlice(start, end));
}

export function parseFloatPrefix(s: string): float64 {
	const sb = s.asBytes();
	const start = skipSpace(sb, 0);
	let i = start;
	const sign = i < sb.length ? sb[i] as int32 : 0;
	if (sign == "+".code || sign == "-".code) i++;
	if (startsInfinity(sb, i)) return sign == "-".code ? -infinity : infinity;
	const end = decimalEnd(sb, i, sb.length);
	if (end < 0) return notANumber;
	return msStringParseFloat(s.byteSlice(start, end));
}

export function parseIntPrefix(s: string): int64 {
	const sb = s.asBytes();
	const start = skipSpace(sb, 0);
	let i = start;
	const sign = i < sb.length ? sb[i] as int32 : 0;
	if (sign == "+".code || sign == "-".code) i++;
	let radix: uint64 = 10;
	const hex = i + 2 < sb.length && sb[i] == "0".code && radixShift(sb[i + 1] as int32) == 4;
	if (hex && digitValue(sb[i + 2] as int32) < 16) {
		radix = 16;
		i += 2;
	}
	const limit: uint64 = sign == "-".code ? 9223372036854775808 : 9223372036854775807;
	let value: uint64 = 0;
	let overflow = false;
	const digitsStart = i;
	while (i < sb.length) {
		const d = digitValue(sb[i] as int32) as uint64;
		if (d >= radix) break;
		if (value > (limit - d) / radix) overflow = true;
		if (!overflow) value = value * radix + d;
		i++;
	}
	if (i == digitsStart) return 0;
	if (overflow) {
		const text = s.byteSlice(start, i);
		throw new Error(`value ${text} not in range -9223372036854775808 .. 9223372036854775807`);
	}
	if (sign != "-".code) return value as int64;
	return value == 0 ? 0 : -((value - 1) as int64) - 1;
}
