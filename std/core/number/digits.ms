@include("runtime/core/mulWide.h");
@include("runtime/core/dragonbox.h");
@include("string.h");

extern function msMulHi64(a: uint64, b: uint64): uint64;
extern function msDragonboxPow10Hi(k: int32): uint64;
extern function msDragonboxPow10Lo(k: int32): uint64;
extern function msDragonboxMod5Mul(e5: int32): uint64;
extern function msDragonboxMod5Cmp(e5: int32): uint64;
extern function msFloat64Bits(d: float64): uint64;
extern function msStringNew(data: cstring, length: int64): string;
extern function cMemcpy(to: Ptr<uint8>, from: Ptr<uint8>, size: uint64): Ptr<uint8> from "memcpy";
extern function cMemmove(to: Ptr<uint8>, from: Ptr<uint8>, size: uint64): Ptr<uint8> from "memmove";

struct Decimal {
	significand: uint64;
	exponent: int32;
}

@inline
function floorLog2Pow10(e: int32): int32 {
	return (e * 1741647) >> 19;
}

@inline
function floorLog10Pow2(e: int32): int32 {
	return (e * 1262611) >> 22;
}

@inline
function floorLog10ThreeQuartersPow2(e: int32): int32 {
	return (e * 1262611 - 524031) >> 22;
}

@inline
function multipleOfPow2(value: uint64, e2: int32): boolean {
	return e2 < 64 && (value & (((1 as uint64) << (e2 as uint64)) - 1)) == 0;
}

@inline
function multipleOfPow5(value: uint64, e5: int32): boolean {
	return value * msDragonboxMod5Mul(e5) <= msDragonboxMod5Cmp(e5);
}

@inline
function mulShift(x: uint64, yHi: uint64, yLo: uint64): uint64 {
	const lowHi = msMulHi64(x, yLo);
	const midLo = x * yHi + lowHi;
	return msMulHi64(x, yHi) + (midLo < lowHi ? 1 : 0);
}

@inline
function mulParity(twoF: uint64, pow10Hi: uint64, pow10Lo: uint64, betaMinus1: int32): boolean {
	const mid = twoF * pow10Hi + msMulHi64(twoF, pow10Lo);
	return (mid & ((1 as uint64) << ((64 - betaMinus1) as uint64))) != 0;
}

@inline
function isIntegralEndpoint(twoF: uint64, e2: int32, minusK: int32): boolean {
	if (e2 < -2) return false;
	if (e2 <= 9) return true;
	if (e2 <= 86) return multipleOfPow5(twoF, minusK);
	return false;
}

@inline
function isIntegralMidpoint(twoF: uint64, e2: int32, minusK: int32): boolean {
	if (e2 < -4) return multipleOfPow2(twoF, minusK - e2 + 1);
	if (e2 <= 9) return true;
	if (e2 <= 86) return multipleOfPow5(twoF, minusK);
	return false;
}

function asymmetricInterval(e2: int32): Decimal {
	const minusK = floorLog10ThreeQuartersPow2(e2);
	const betaMinus1 = e2 + floorLog2Pow10(-minusK);
	const pow10Hi = msDragonboxPow10Hi(-minusK);
	const lowerEndpoint = (pow10Hi - (pow10Hi >> 54)) >> ((11 - betaMinus1) as uint64);
	const upperEndpoint = (pow10Hi + (pow10Hi >> 53)) >> ((11 - betaMinus1) as uint64);
	const lowerEndpointIsInteger = 2 <= e2 && e2 <= 3;
	const xi = lowerEndpoint + (lowerEndpointIsInteger ? 0 : 1);
	const q = upperEndpoint / 10;
	if (q * 10 >= xi) return { significand: q, exponent: minusK + 1 };
	let rounded = ((pow10Hi >> ((10 - betaMinus1) as uint64)) + 1) / 2;
	if (e2 == -77) {
		if (rounded % 2 != 0) rounded -= 1;
	} else {
		if (rounded < xi) rounded += 1;
	}
	return { significand: rounded, exponent: minusK };
}

@inline
function toDecimal64(ieeeSignificand: uint64, ieeeExponent: uint64): Decimal {
	let m2: uint64;
	let e2: int32;
	if (ieeeExponent != 0) {
		m2 = 4503599627370496 | ieeeSignificand;
		e2 = (ieeeExponent as int32) - 1075;
		if (0 <= -e2 && -e2 < 53 && multipleOfPow2(m2, -e2)) {
			return { significand: m2 >> ((-e2) as uint64), exponent: 0 };
		}
		if (ieeeSignificand == 0 && ieeeExponent > 1) return asymmetricInterval(e2);
	} else {
		m2 = ieeeSignificand;
		e2 = -1074;
	}
	const isEven = m2 % 2 == 0;
	const minusK = floorLog10Pow2(e2) - 2;
	const betaMinus1 = e2 + floorLog2Pow10(-minusK);
	const pow10Hi = msDragonboxPow10Hi(-minusK);
	const pow10Lo = msDragonboxPow10Lo(-minusK);
	const delta = (pow10Hi >> ((63 - betaMinus1) as uint64)) as uint32;
	const twoFl = 2 * m2 - 1;
	const twoFc = 2 * m2;
	const twoFr = 2 * m2 + 1;
	const zi = mulShift(twoFr << (betaMinus1 as uint64), pow10Hi, pow10Lo);
	let q = zi / 1000;
	let r = (zi as uint32) - 1000 * (q as uint32);
	if (r < delta) {
		if (r != 0 || isEven || !isIntegralEndpoint(twoFr, e2, minusK)) {
			return { significand: q, exponent: minusK + 3 };
		}
		q -= 1;
		r = 1000;
	} else if (r == delta) {
		if ((isEven && isIntegralEndpoint(twoFl, e2, minusK)) || mulParity(twoFl, pow10Hi, pow10Lo, betaMinus1)) {
			return { significand: q, exponent: minusK + 3 };
		}
	}
	q = q * 10;
	const dist = r - (delta / 2) + 50;
	const distQ = dist / 100;
	q += distQ as uint64;
	if (dist == distQ * 100) {
		const approxYParity = (dist & 1) != 0;
		if (mulParity(twoFc, pow10Hi, pow10Lo, betaMinus1) != approxYParity) {
			q -= 1;
		} else if (q % 2 != 0 && isIntegralMidpoint(twoFc, e2, minusK)) {
			q -= 1;
		}
	}
	return { significand: q, exponent: minusK + 2 };
}

@inline
function pairTable(): Ptr<uint8> {
	return ("00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899" as cstring) as Ptr<uint8>;
}

@inline
function zeroText(): Ptr<uint8> {
	return ("0.000000000000000000000000000000" as cstring) as Ptr<uint8>;
}

@inline
function putPair(buf: Ptr<uint8>, at: int32, pair: uint32): void {
	const source = pairTable() + ((pair * 2) as int32);
	cMemcpy(buf + at, source, 2);
}

@inline
function writeDigitsEndingAt(buf: Ptr<uint8>, end: int32, value: uint64): int32 {
	let at = end;
	let rest = value;
	while (rest >= 100000000) {
		const q = rest / 100000000;
		const low = (rest - q * 100000000) as uint32;
		const upper = low / 10000;
		const lower = low - upper * 10000;
		const a = upper / 100;
		const b = lower / 100;
		putPair(buf, at - 8, a);
		putPair(buf, at - 6, upper - a * 100);
		putPair(buf, at - 4, b);
		putPair(buf, at - 2, lower - b * 100);
		at -= 8;
		rest = q;
	}
	let small = rest as uint32;
	while (small >= 100) {
		const q = small / 100;
		putPair(buf, at - 2, small - q * 100);
		at -= 2;
		small = q;
	}
	if (small >= 10) {
		putPair(buf, at - 2, small);
		return at - 2;
	}
	buf[at - 1] = (48 + small) as uint8;
	return at - 1;
}

@inline
function decimalLength(value: uint64): int32 {
	if (value < 100000000) {
		if (value < 10000) {
			if (value < 100) return value < 10 ? 1 : 2;
			return value < 1000 ? 3 : 4;
		}
		if (value < 1000000) return value < 100000 ? 5 : 6;
		return value < 10000000 ? 7 : 8;
	}
	if (value < 1000000000000) {
		if (value < 10000000000) return value < 1000000000 ? 9 : 10;
		return value < 100000000000 ? 11 : 12;
	}
	if (value < 100000000000000) return value < 10000000000000 ? 13 : 14;
	if (value < 10000000000000000) return value < 1000000000000000 ? 15 : 16;
	return 17;
}

@inline
function digitText(digit: uint64): string {
	return match (digit) {
		0 => "0",
		1 => "1",
		2 => "2",
		3 => "3",
		4 => "4",
		5 => "5",
		6 => "6",
		7 => "7",
		8 => "8",
		_ => "9",
	};
}

@exportName("msUint64ToString")
export function uint64ToString(value: uint64): string {
	if (value < 10) return digitText(value);
	let scratch: uint8[24] = [];
	const buf = (scratch as Span<uint8>) as Ptr<uint8>;
	const start = writeDigitsEndingAt(buf, 24, value);
	return msStringNew((buf + start) as cstring, (24 - start) as int64);
}

@exportName("msIntToString")
export function intToString(value: int64): string {
	if ((value as uint64) < 10) return digitText(value as uint64);
	let scratch: uint8[24] = [];
	const buf = (scratch as Span<uint8>) as Ptr<uint8>;
	if (value >= 0) {
		const start = writeDigitsEndingAt(buf, 24, value as uint64);
		return msStringNew((buf + start) as cstring, (24 - start) as int64);
	}
	const start = writeDigitsEndingAt(buf, 24, (0 as uint64) - (value as uint64)) - 1;
	buf[start] = 45;
	return msStringNew((buf + start) as cstring, (24 - start) as int64);
}

@exportName("msBoolToString")
export function boolToString(value: int32): string {
	return value != 0 ? "true" : "false";
}

@exportName("msNumberToString")
export function numberToString(input: float64): string {
	if (input != input) return "NaN";
	if (input == 0.0) return "0";
	if (input - input != 0.0) return input < 0.0 ? "-Infinity" : "Infinity";
	if (input >= -1e15 && input <= 1e15) {
		const whole = input as int64;
		if (whole as float64 == input) return intToString(whole);
	}
	return decimalToString(input);
}

@noinline
function decimalToString(input: float64): string {
	let text: uint8[64] = [];
	const buf = (text as Span<uint8>) as Ptr<uint8>;
	let value = input;
	let p = 0;
	if (value < 0.0) {
		buf[0] = 45;
		p = 1;
		value = -value;
	}
	const valueBits = msFloat64Bits(value);
	const decimal = toDecimal64(valueBits & 0x000FFFFFFFFFFFFF, (valueBits >> 52) & 0x7FF);
	let significand = decimal.significand;
	let exponent = decimal.exponent;
	if (significand % 10 == 0) {
		if (significand % 100000000 == 0) {
			significand /= 100000000;
			exponent += 8;
			let rest = significand as uint32;
			if (rest % 10000 == 0) {
				rest /= 10000;
				exponent += 4;
			}
			if (rest % 100 == 0) {
				rest /= 100;
				exponent += 2;
			}
			if (rest % 10 == 0) {
				rest /= 10;
				exponent += 1;
			}
			if (rest % 10 == 0) {
				rest /= 10;
				exponent += 1;
			}
			significand = rest as uint64;
		} else {
			while (significand % 10 == 0) {
				significand /= 10;
				exponent += 1;
			}
		}
	}
	const k = decimalLength(significand);
	const n = exponent + k;
	if (k <= n && n <= 21) {
		writeDigitsEndingAt(buf, p + k, significand);
		cMemcpy(buf + p + k, zeroText() + 2, 24);
		p += n;
	} else if (n > 0 && n <= 21) {
		writeDigitsEndingAt(buf, p + k, significand);
		cMemmove(buf + p + n + 1, buf + p + n, 16);
		buf[p + n] = 46;
		p += k + 1;
	} else if (n > -6 && n <= 0) {
		cMemcpy(buf + p, zeroText(), 8);
		p += 2 - n;
		writeDigitsEndingAt(buf, p + k, significand);
		p += k;
	} else {
		writeDigitsEndingAt(buf, p + 1 + k, significand);
		buf[p] = buf[p + 1];
		if (k > 1) {
			buf[p + 1] = 46;
			p += k + 1;
		} else {
			p += 1;
		}
		buf[p] = 101;
		buf[p + 1] = n > 0 ? 43 : 45;
		p += 2;
		const magnitude = (n > 0 ? n - 1 : 1 - n) as uint32;
		if (magnitude >= 100) {
			const hundreds = magnitude / 100;
			buf[p] = (48 + hundreds) as uint8;
			putPair(buf, p + 1, magnitude - hundreds * 100);
			p += 3;
		} else if (magnitude >= 10) {
			putPair(buf, p, magnitude);
			p += 2;
		} else {
			buf[p] = (48 + magnitude) as uint8;
			p += 1;
		}
	}
	return msStringNew(buf as cstring, p as int64);
}
