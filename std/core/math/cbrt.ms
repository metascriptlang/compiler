@builtin("Float64Bits")
extern function msFloat64Bits(d: float64): uint64;
@builtin("Float64FromBits")
extern function msBitsFloat64(bits: uint64): float64;

const SIGN_BIT: uint64 = 0x8000000000000000;
const HIGH_WORD_MAGNITUDE: uint64 = 0x7fffffff;
const HIGH_WORD_INFINITY: uint64 = 0x7ff00000;
const HIGH_WORD_SMALLEST_NORMAL: uint64 = 0x00100000;
const NORMAL_EXPONENT_BIAS: uint64 = 715094163;
const SUBNORMAL_EXPONENT_BIAS: uint64 = 696219795;
const TWO_POW_54: float64 = 18014398509481984.0;
const ROUND_TO_22_BITS: uint64 = 0x80000000;
const KEEP_22_BITS: uint64 = 0xffffffffc0000000;

const P0: float64 = 1.87595182427177009643;
const P1: float64 = -1.88497979543377169875;
const P2: float64 = 1.621429720105354466140;
const P3: float64 = -0.758397934778766047437;
const P4: float64 = 0.145996192886612446982;

function highWordMagnitude(bits: uint64): uint64 {
	return (bits >> 32) & HIGH_WORD_MAGNITUDE;
}

function estimateWithHighWord(sign: uint64, high: uint64): float64 {
	return msBitsFloat64(sign | (high << 32));
}

export function cubeRoot(x: float64): float64 {
	const bits = msFloat64Bits(x);
	const sign = bits & SIGN_BIT;
	const high = highWordMagnitude(bits);
	if (high >= HIGH_WORD_INFINITY) return x + x;
	if ((bits & ~SIGN_BIT) == 0) return x;
	let t = high < HIGH_WORD_SMALLEST_NORMAL
		? estimateWithHighWord(sign, highWordMagnitude(msFloat64Bits(TWO_POW_54 * x)) / 3 + SUBNORMAL_EXPONENT_BIAS)
		: estimateWithHighWord(sign, high / 3 + NORMAL_EXPONENT_BIAS);

	let r = (t * t) * (t / x);
	t = t * ((P0 + r * (P1 + r * P2)) + ((r * r) * r) * (P3 + r * P4));
	t = msBitsFloat64((msFloat64Bits(t) + ROUND_TO_22_BITS) & KEEP_22_BITS);

	const s = t * t;
	r = x / s;
	const w = t + t;
	r = (r - t) / (w + r);
	return t + t * r;
}

test "a perfect cube's root is exact" {
	assert cubeRoot(27.0) == 3.0;
	assert cubeRoot(-27.0) == -3.0;
	assert cubeRoot(1000.0) == 10.0;
	assert cubeRoot(1e300) == 1e100;
}

test "a subnormal root is scaled before the estimate" {
	assert cubeRoot(5e-324) == 1.7031839360032603e-108;
}

test "zero, infinity and NaN are their own root" {
	assert msFloat64Bits(cubeRoot(-0.0)) == SIGN_BIT;
	assert cubeRoot(1.0 / 0.0) == 1.0 / 0.0;
	assert cubeRoot(0.0 / 0.0) != cubeRoot(0.0 / 0.0);
}
