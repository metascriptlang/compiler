function magnitudeOf(value: int32): uint32 {
	return value < 0 ? (0 - (value as int64)) as uint32 : value as uint32;
}

function wideMagnitudeOf(value: int64): uint64 {
	return value < 0 ? ~(value as uint64) + 1 : value as uint64;
}

function signed(magnitude: uint32, negative: boolean): int32 {
	return negative ? (0 - (magnitude as int64)) as int32 : magnitude as int32;
}

function wideSigned(magnitude: uint64, negative: boolean): int64 {
	return negative ? (~magnitude + 1) as int64 : magnitude as int64;
}

export function quotient(dividend: int32, divisor: int32): int32 {
	if (dividend >= 0 && divisor > 0) {
		return ((dividend as uint32) / (divisor as uint32)) as int32;
	}
	return signed(magnitudeOf(dividend) / magnitudeOf(divisor), (dividend < 0) != (divisor < 0));
}

export function remainder(dividend: int32, divisor: int32): int32 {
	if (dividend >= 0 && divisor > 0) {
		return ((dividend as uint32) % (divisor as uint32)) as int32;
	}
	return signed(magnitudeOf(dividend) % magnitudeOf(divisor), dividend < 0);
}

export function wideQuotient(dividend: int64, divisor: int64): int64 {
	if (dividend >= 0 && divisor > 0) {
		return ((dividend as uint64) / (divisor as uint64)) as int64;
	}
	const negative = (dividend < 0) != (divisor < 0);
	return wideSigned(wideMagnitudeOf(dividend) / wideMagnitudeOf(divisor), negative);
}

export function wideRemainder(dividend: int64, divisor: int64): int64 {
	if (dividend >= 0 && divisor > 0) {
		return ((dividend as uint64) % (divisor as uint64)) as int64;
	}
	return wideSigned(wideMagnitudeOf(dividend) % wideMagnitudeOf(divisor), dividend < 0);
}

when (solana) {
	export function `/`(this dividend: int32, divisor: int32): int32 {
		return quotient(dividend, divisor);
	}

	export function `%`(this dividend: int32, divisor: int32): int32 {
		return remainder(dividend, divisor);
	}

	export function `/`(this dividend: int64, divisor: int64): int64 {
		return wideQuotient(dividend, divisor);
	}

	export function `%`(this dividend: int64, divisor: int64): int64 {
		return wideRemainder(dividend, divisor);
	}

	export function `/=`(this ref dividend: int32, divisor: int32): void {
		dividend = quotient(dividend, divisor);
	}

	export function `%=`(this ref dividend: int32, divisor: int32): void {
		dividend = remainder(dividend, divisor);
	}

	export function `/=`(this ref dividend: int64, divisor: int64): void {
		dividend = wideQuotient(dividend, divisor);
	}

	export function `%=`(this ref dividend: int64, divisor: int64): void {
		dividend = wideRemainder(dividend, divisor);
	}
}

test "the unsigned-based quotient and remainder equal signed division" {
	const values: int32[] = [
		0, 1, 2, 3, 7, 99, 100, 101, 9999, 10000, 65535, 2147483647,
		-1, -2, -3, -7, -99, -100, -101, -10000, -2147483647, -2147483648,
	];
	for (const dividend of values) {
		for (const divisor of values) {
			if (divisor == 0 || (dividend == -2147483648 && divisor == -1)) { continue; }
			assert quotient(dividend, divisor) == dividend / divisor;
			assert remainder(dividend, divisor) == dividend % divisor;
			const wideDividend = (dividend as int64) * 1000003;
			const wideDivisor = divisor as int64;
			assert wideQuotient(wideDividend, wideDivisor) == wideDividend / wideDivisor;
			assert wideRemainder(wideDividend, wideDivisor) == wideDividend % wideDivisor;
		}
	}
}

test "the int64 extremes divide as signed division does" {
	when (c) {
		const lowest: int64 = -9223372036854775807 - 1;
		assert wideQuotient(lowest, 2) == lowest / 2;
		assert wideRemainder(lowest, 3) == lowest % 3;
		const highest: int64 = 9223372036854775807;
		const seven: int64 = -7;
		assert wideQuotient(highest, seven) == highest / seven;
	}
}
