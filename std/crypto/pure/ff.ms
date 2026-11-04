import { valueBarrier, wipeWords } from "./secret";
/**
 * Modular arithmetic on fixed-length unsigned integers, ported from Zig's `std.crypto.ff` (MIT, see
 * LICENSE.zig.MIT). A limb is a `uint32` carrying 31 value bits, little-endian in a `uint32[]`; a field
 * element is a `uint32[]` as long as its modulus and always in plain (not Montgomery) form. Operations are
 * constant-time for a given modulus except those named `Public`. Zig's module has no inversion and no
 * multi-limb division: `uintGcdModinvOdd` follows mbedTLS's constant-time binary GCD, and `uintDivRem`
 * keeps the quotient bit of Zig's shift-and-subtract reduction.
 */

const tBits: int32 = 31;
const tShift: uint32 = 31;
const tMask: uint32 = 0x7fffffff;

export interface DivRem {
	quotient: uint32[];
	remainder: uint32[];
}

export interface GcdInverse {
	gcd: uint32[];
	inverse: uint32[];
}

export function limbsFor(bits: int32): int32 {
	return (bits + tBits - 1) / tBits;
}

function select(on: uint32, x: uint32, y: uint32): uint32 {
	const mask = valueBarrier((0 as uint32) - on);
	return y ^ (mask & (y ^ x));
}

function isNonZero(x: uint32): uint32 {
	return (x | ((0 as uint32) - x)) >> 31;
}

function limbsCmpLt(x: Readonly<uint32[]>, y: Readonly<uint32[]>): uint32 {
	let c: uint32 = 0;
	for (let i = 0; i < x.length; i++) c = (x[i] - y[i] - c) >> tShift;
	return c;
}

// The high word of a 32x32-bit product from 16-bit halves, so no 64-bit type reaches the JavaScript backend.
function mulHi(x: uint32, y: uint32): uint32 {
	const x0 = x & 0xffff;
	const x1 = x >> 16;
	const y0 = y & 0xffff;
	const y1 = y >> 16;
	const w0 = x0 * y0;
	const t = x1 * y0 + (w0 >> 16);
	let w1 = t & 0xffff;
	const w2 = t >> 16;
	w1 += x0 * y1;
	return x1 * y1 + w2 + (w1 >> 16);
}

// The carry out of `a + b`, which wrapped to `sum`, without a comparison the compiler could branch on.
function carryOut(a: uint32, b: uint32, sum: uint32): uint32 {
	return ((a & b) | ((a | b) & ~sum)) >> 31;
}

function clz32(x: uint32): int32 {
	let n = 32;
	let rest = x;
	while (rest != 0) {
		rest = rest >> 1;
		n -= 1;
	}
	return n;
}

function orLimbs(x: Readonly<uint32[]>, from: int32): uint32 {
	let t: uint32 = 0;
	for (let i = from; i < x.length; i++) t |= x[i];
	return t;
}

function decodeBytes(limbs: uint32[], bytes: Readonly<uint8[]>): uint32 {
	let acc: uint32 = 0;
	let shift: int32 = 0;
	let out = 0;
	for (let k = 0; k < bytes.length; k++) {
		const bi = bytes[bytes.length - 1 - k] as uint32;
		if (out >= limbs.length) {
			acc |= bi;
			continue;
		}
		limbs[out] |= bi << (shift as uint32);
		shift += 8;
		if (shift >= tBits) {
			shift -= tBits;
			limbs[out] = limbs[out] & tMask;
			const spill = bi >> ((8 - shift) as uint32);
			out += 1;
			if (out < limbs.length) {
				limbs[out] = spill;
			} else {
				acc |= spill;
			}
		}
	}
	return acc;
}

/** Big-endian bytes into `limbs` limbs, or null when the value does not fit. */
export function uintFromBytes(
	bytes: Readonly<uint8[]>,
	limbs: int32,
): uint32[] | null {
	const out = new Array<uint32>(limbs);
	if (decodeBytes(out, bytes) != 0) return null;
	return out;
}

/** Big-endian bytes of exactly `size`, or null when the value does not fit. */
export function uintToBytes(
	x: Readonly<uint32[]>,
	size: int32,
): uint8[] | null {
	const bytes = new Array<uint8>(size);
	if (size == 0) return orLimbs(x, 0) == 0 ? bytes : null;
	let shift: int32 = 0;
	let outI = size - 1;
	for (let i = 0; i < x.length; i++) {
		let remaining = tBits;
		let limb = x[i];
		while (remaining >= 8) {
			bytes[outI] = ((bytes[outI] as uint32) |
				((limb << (shift as uint32)) & 0xff)) as uint8;
			const consumed = 8 - shift;
			limb = limb >> (consumed as uint32);
			remaining -= consumed;
			shift = 0;
			if (outI == 0) {
				if ((limb | orLimbs(x, i + 1)) != 0) return null;
				return bytes;
			}
			outI -= 1;
		}
		bytes[outI] = ((bytes[outI] as uint32) | (limb & 0xff)) as uint8;
		shift = remaining;
	}
	return bytes;
}

/** The shortest big-endian bytes of the value, one zero byte for zero. */
export function uintToMinimalBytes(x: Readonly<uint32[]>): uint8[] {
	const size = (uintBitLenPublic(x) + 7) >> 3;
	const bytes = uintToBytes(x, size > 0 ? size : 1);
	if (bytes == null) throw new Error(
		"uintToMinimalBytes: the bit length does not fit its own size",
	);
	return bytes;
}

/** A copy zero-extended (or trimmed of zero limbs) to `limbs` limbs. */
export function uintWiden(x: Readonly<uint32[]>, limbs: int32): uint32[] {
	if (orLimbs(x, limbs) != 0) throw new Error(
		"uintWiden: the value does not fit the width",
	);
	const out = new Array<uint32>(limbs);
	for (let i = 0; i < limbs && i < x.length; i++) out[i] = x[i];
	return out;
}

function normalize(x: Readonly<uint32[]>): uint32[] {
	let len = x.length;
	while (len > 1 && x[len - 1] == 0) len -= 1;
	return uintWiden(x, len);
}

export function uintIsZero(x: Readonly<uint32[]>): boolean {
	return isNonZero(orLimbs(x, 0)) == 0;
}

export function uintIsOdd(x: Readonly<uint32[]>): boolean {
	return (x[0] & 1) != 0;
}

export function uintIsOne(x: Readonly<uint32[]>): boolean {
	return isNonZero((x[0] ^ 1) | orLimbs(x, 1)) == 0;
}

/** -1, 0 or 1; both operands have the same length. */
export function uintCompare(
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): int32 {
	return (limbsCmpLt(y, x) as int32) - (limbsCmpLt(x, y) as int32);
}

function cmov(x: uint32[], on: uint32, y: Readonly<uint32[]>): void {
	for (let i = 0; i < x.length; i++) x[i] = select(on, y[i], x[i]);
}

function condSwap(x: uint32[], y: uint32[], on: uint32): void {
	for (let i = 0; i < x.length; i++) {
		const a = x[i];
		x[i] = select(on, y[i], a);
		y[i] = select(on, a, y[i]);
	}
}

function conditionalAdd(
	x: uint32[],
	on: uint32,
	y: Readonly<uint32[]>,
): uint32 {
	let carry: uint32 = 0;
	for (let i = 0; i < x.length; i++) {
		const res = x[i] + (i < y.length ? y[i] : 0) + carry;
		x[i] = select(on, res & tMask, x[i]);
		carry = res >> tShift;
	}
	return carry;
}

function conditionalSub(
	x: uint32[],
	on: uint32,
	y: Readonly<uint32[]>,
): uint32 {
	let borrow: uint32 = 0;
	for (let i = 0; i < x.length; i++) {
		const res = x[i] - (i < y.length ? y[i] : 0) - borrow;
		x[i] = select(on, res & tMask, x[i]);
		borrow = res >> tShift;
	}
	return borrow;
}

/** `x += y` at `x`'s width (`y` no wider); returns 1 on overflow. */
export function uintAdd(x: uint32[], y: Readonly<uint32[]>): uint32 {
	return conditionalAdd(x, 1, y);
}

/** `x -= y` at `x`'s width (`y` no wider); returns 1 on underflow. */
export function uintSub(x: uint32[], y: Readonly<uint32[]>): uint32 {
	return conditionalSub(x, 1, y);
}

function mulAddLimb(
	z: uint32[],
	at: int32,
	x: Readonly<uint32[]>,
	y: uint32,
): uint32 {
	when (c) {
		const y64 = y as uint64;
		let carry: uint64 = 0;
		for (let j = 0; j < x.length; j++) {
			const wide = (z[at + j] as uint64) + (x[j] as uint64) * y64 + carry;
			z[at + j] = (wide as uint32) & tMask;
			carry = wide >> 31;
		}
		return carry as uint32;
	} else {
		let carry: uint32 = 0;
		for (let j = 0; j < x.length; j++) {
			const lo = x[j] * y;
			const zj = z[at + j];
			let zLo = zj + lo;
			let zHi = mulHi(x[j], y) + carryOut(zj, lo, zLo);
			const sum = zLo + carry;
			zHi += carryOut(zLo, carry, sum);
			zLo = sum;
			z[at + j] = zLo & tMask;
			carry = (zHi << 1) | (zLo >> tShift);
		}
		return carry;
	}
}

/** `acc += x * y` with all three the same length; returns 1 if any part of the product was discarded. */
export function uintMulAdd(
	acc: uint32[],
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32 {
	const n = acc.length;
	const wide = new Array<uint32>(2 * n);
	for (let i = 0; i < n; i++) wide[i] = acc[i];
	for (let i = 0; i < n; i++) wide[i + n] = mulAddLimb(wide, i, x, y[i]);
	for (let i = 0; i < n; i++) acc[i] = wide[i];
	return isNonZero(orLimbs(wide, n));
}

/** The full product, `x.length + y.length` limbs wide. */
export function uintMul(
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32[] {
	const width = x.length + y.length;
	const acc = new Array<uint32>(width);
	if (
		uintMulAdd(acc, uintWiden(x, width), uintWiden(y, width)) != 0
	) throw new Error("uintMul: the product overflowed its own width");
	return acc;
}

export function uintBitLenPublic(x: Readonly<uint32[]>): int32 {
	let i = x.length;
	while (i != 0) {
		i -= 1;
		const limb = x[i];
		if (limb != 0) return i * tBits + 32 - clz32(limb);
	}
	return 0;
}

export function uintTrailingZeroBitsPublic(x: Readonly<uint32[]>): int32 {
	for (let i = 0; i < x.length; i++) {
		const limb = x[i];
		if (limb != 0) {
			let bits = 0;
			while (((limb >> (bits as uint32)) & 1) == 0) bits += 1;
			return i * tBits + bits;
		}
	}
	return x.length * tBits;
}

export function uintShiftRightPublic(x: uint32[], shift: int32): void {
	const limbShift = shift / tBits;
	const bitShift = (shift % tBits) as uint32;
	if (limbShift >= x.length) {
		for (let i = 0; i < x.length; i++) x[i] = 0;
		return;
	}
	const active = x.length - limbShift;
	for (let i = 0; i < active; i++) {
		const lo = x[i + limbShift] >> bitShift;
		const hi =
			i + limbShift + 1 < x.length && bitShift != 0
				? x[i + limbShift + 1] << (tShift - bitShift)
				: 0;
		x[i] = (lo | hi) & tMask;
	}
	for (let i = active; i < x.length; i++) x[i] = 0;
}

function shiftLeft(x: uint32[], shift: int32): void {
	const limbShift = shift / tBits;
	const bitShift = (shift % tBits) as uint32;
	let i = x.length;
	while (i != 0) {
		i -= 1;
		const hi = i >= limbShift ? x[i - limbShift] << bitShift : 0;
		const lo =
			i >= limbShift + 1 && bitShift != 0
				? x[i - limbShift - 1] >> (tShift - bitShift)
				: 0;
		x[i] = (hi | lo) & tMask;
	}
}

function shiftRightByOneWithCarry(x: uint32[], carry: uint32): uint32 {
	let c = carry;
	let i = x.length;
	while (i != 0) {
		i -= 1;
		const limb = x[i];
		x[i] = (limb >> 1) | (c << (tShift - 1));
		c = limb & 1;
	}
	return c;
}

/** Divides in place by a divisor below 2^21 and returns the remainder. */
export function uintDivRemPublic(x: uint32[], divisor: int32): int32 {
	if (divisor <= 0 || divisor >= 0x200000) throw new Error(
		`uintDivRemPublic: divisor ${divisor} is outside 1 .. 2^21 - 1`,
	);
	let rem = 0;
	let i = x.length;
	while (i != 0) {
		i -= 1;
		const num = (rem as number) * 2147483648 + (x[i] as number);
		const q = Math.floor(num / divisor);
		x[i] = q as uint32;
		rem = (num - q * divisor) as int32;
	}
	return rem;
}

// Computes x << tBits + y (mod m) in place and returns the 31 quotient bits that the reduction subtracted.
function shiftIn(m: Readonly<uint32[]>, x: uint32[], y: uint32): uint32 {
	const n = m.length;
	const d = new Array<uint32>(n);
	let needSub: uint32 = 0;
	let quotient: uint32 = 0;
	let i = tBits - 1;
	while (true) {
		let carry = (y >> (i as uint32)) & 1;
		let borrow: uint32 = 0;
		for (let j = 0; j < n; j++) {
			const l = select(needSub, d[j], x[j]);
			let res = (l << 1) + carry;
			x[j] = res & tMask;
			carry = res >> tShift;
			res = x[j] - m[j] - borrow;
			d[j] = res & tMask;
			borrow = res >> tShift;
		}
		needSub = 1 ^ (carry ^ borrow);
		quotient = (quotient << 1) | needSub;
		if (i == 0) break;
		i -= 1;
	}
	cmov(x, needSub, d);
	return quotient;
}

function reduceInto(
	m: Readonly<uint32[]>,
	x: Readonly<uint32[]>,
	quotient: uint32[] | null,
): uint32[] {
	const n = m.length;
	const wide = x.length >= n ? x : uintWiden(x, n);
	const out = new Array<uint32>(n);
	let i = wide.length - 1;
	if (n >= 2) {
		let j = Math.min(i, n - 2) as int32;
		while (true) {
			out[j] = wide[i];
			i -= 1;
			if (j == 0) break;
			j -= 1;
		}
	}
	while (true) {
		const q = shiftIn(m, out, wide[i]);
		if (quotient != null) quotient[i] = q;
		if (i == 0) break;
		i -= 1;
	}
	return out;
}

/** Quotient and remainder by any non-zero divisor (odd or even), with the remainder as wide as the divisor's active limbs. */
export function uintDivRem(
	x: Readonly<uint32[]>,
	divisor: Readonly<uint32[]>,
): DivRem {
	if (uintIsZero(divisor)) throw new Error("uintDivRem: division by zero");
	const m = normalize(divisor);
	const quotient = new Array<uint32>(Math.max(x.length, m.length) as int32);
	const remainder = reduceInto(m, x, quotient);
	return { quotient, remainder };
}

function copyLimbs(x: uint32[], y: Readonly<uint32[]>): void {
	for (let i = 0; i < x.length; i++) x[i] = y[i];
}

function div2ModOdd(x: uint32[], n: Readonly<uint32[]>): void {
	const c = conditionalAdd(x, x[0] & 1, n);
	shiftRightByOneWithCarry(x, 0);
	x[x.length - 1] |= c << (tShift - 1);
}

/**
 * The GCD of `a` and an odd `n`, and the inverse of `a` mod `n` (meaningful when the GCD is 1), with
 * `a <= n`, in constant time.
 */
export function uintGcdModinvOdd(
	a: Readonly<uint32[]>,
	n: Readonly<uint32[]>,
): GcdInverse {
	const limbs = n.length;
	if (!uintIsOdd(n)) throw new Error("uintGcdModinvOdd: the modulus is even");
	const aLimbs = Math.min(a.length, limbs) as int32;
	const u = uintWiden(a, limbs);
	const v = uintWiden(n, limbs);
	const q = new Array<uint32>(limbs);
	const r = new Array<uint32>(limbs);
	r[0] = 1;
	const steps = (aLimbs + limbs) * tBits;
	const d = new Array<uint32>(limbs);
	const dq = new Array<uint32>(limbs);
	for (let i = 0; i < steps; i++) {
		const uOdd = u[0] & 1;
		const vOdd = v[0] & 1;
		const uOddVOdd = uOdd & vOdd;
		const uEven = uOdd ^ 1;
		const notBothOdd = uOddVOdd ^ 1;

		// u, v = (u when both are odd, else v - u), (v when u is odd and v even, v - u when both are odd, else u) / 2
		copyLimbs(d, v);
		uintSub(d, u);
		cmov(v, uOddVOdd, d);
		cmov(v, uEven, u);
		cmov(u, notBothOdd, d);
		shiftRightByOneWithCarry(v, 0);
		const swap = limbsCmpLt(v, u);
		condSwap(u, v, swap);

		copyLimbs(dq, q);
		conditionalAdd(dq, uintSub(dq, r), n);
		cmov(q, uOddVOdd, dq);
		cmov(q, uEven, r);
		cmov(r, notBothOdd, dq);
		div2ModOdd(q, n);
		condSwap(r, q, swap);
	}
	uintWipe(d);
	uintWipe(dq);
	return { gcd: v, inverse: q };
}

/**
 * The greatest common divisor, with gcd(x, 0) = x; null when both are zero. As `mbedtls_mpi_gcd`: the common
 * power of two is set aside (its count is not constant-time), then the constant-time odd GCD runs.
 */
export function uintGcd(
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32[] | null {
	if (uintIsZero(x) && uintIsZero(y)) return null;
	const len = Math.max(x.length, y.length) as int32;
	if (uintIsZero(x)) return uintWiden(y, len);
	if (uintIsZero(y)) return uintWiden(x, len);
	const a = uintWiden(x, len);
	const b = uintWiden(y, len);
	const aShift = uintTrailingZeroBitsPublic(a);
	const bShift = uintTrailingZeroBitsPublic(b);
	uintShiftRightPublic(a, aShift);
	uintShiftRightPublic(b, bShift);
	condSwap(a, b, limbsCmpLt(b, a));
	const g = uintGcdModinvOdd(a, b).gcd;
	shiftLeft(g, Math.min(aShift, bShift) as int32);
	return g;
}

/** An odd modulus above 2 with its Montgomery constants; build it with `modulusFromUint` or `modulusFromBytes`. */
export struct Modulus {
	v: uint32[];
	rr: uint32[];
	m0inv: uint32;
	leading: int32;
}

function computeM0Inv(lo: uint32): uint32 {
	let y = lo;
	for (let i = 0; i < 4; i++) y = y * (2 - lo * y);
	return ((1 as uint32) << tShift) - (y & tMask);
}

export function modulusFromUint(value: Readonly<uint32[]>): Modulus | null {
	if (!uintIsOdd(value)) return null;
	const v = normalize(value);
	const hi = v[v.length - 1];
	if (v.length < 2 && v[0] < 3) return null;
	const n = v.length;
	const rr = new Array<uint32>(n);
	rr[n - 1] = 1;
	for (let i = n - 1; i < 2 * n; i++) shiftIn(v, rr, 0);
	return { v, rr, m0inv: computeM0Inv(v[0]), leading: clz32(hi) - 1 };
}

export function modulusFromBytes(bytes: Readonly<uint8[]>): Modulus | null {
	const v = uintFromBytes(bytes, limbsFor(bytes.length * 8));
	if (v == null) return null;
	return modulusFromUint(v);
}

export function bits(this m: Modulus): int32 {
	return m.v.length * tBits - m.leading;
}

export function zero(this m: Modulus): uint32[] {
	return new Array<uint32>(m.v.length);
}

export function one(this m: Modulus): uint32[] {
	const fe = m.zero();
	fe[0] = 1;
	return fe;
}

/** A field element from big-endian bytes, or null when the value is not below the modulus. */
export function feFromBytes(
	this m: Modulus,
	bytes: Readonly<uint8[]>,
): uint32[] | null {
	const fe = uintFromBytes(bytes, m.v.length);
	if (fe == null || limbsCmpLt(fe, m.v) == 0) return null;
	return fe;
}

export function isMinusOne(this m: Modulus, x: Readonly<uint32[]>): boolean {
	const minusOne = m.sub(m.zero(), m.one());
	return isNonZero(orLimbs(xorLimbs(x, minusOne), 0)) == 0;
}

function xorLimbs(x: Readonly<uint32[]>, y: Readonly<uint32[]>): uint32[] {
	const out = new Array<uint32>(x.length);
	for (let i = 0; i < x.length; i++) out[i] = x[i] ^ y[i];
	return out;
}

/** Reduces an integer of any length to a field element. */
export function reduce(this m: Modulus, x: Readonly<uint32[]>): uint32[] {
	return reduceInto(m.v, x, null);
}

export function add(
	this m: Modulus,
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32[] {
	const out = uintWiden(x, x.length);
	const overflow = uintAdd(out, y);
	const underflow = limbsCmpLt(out, m.v);
	conditionalSub(out, 1 ^ (overflow ^ underflow), m.v);
	return out;
}

export function sub(
	this m: Modulus,
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32[] {
	const out = uintWiden(x, x.length);
	const underflow = uintSub(out, y);
	conditionalAdd(out, underflow, m.v);
	return out;
}

function montgomeryLoop(
	m: Modulus,
	d: uint32[],
	a: Readonly<uint32[]>,
	b: Readonly<uint32[]>,
): uint32 {
	when (c) {
		const n = m.v.length;
		const mv = m.v;
		let overflow: uint64 = 0;
		for (let i = 0; i < n; i++) {
			const ai = a[i] as uint64;
			let wide = (d[0] as uint64) + ai * (b[0] as uint64);
			const f = ((wide as uint32) * m.m0inv) & tMask;
			const f64 = f as uint64;
			wide += f64 * (mv[0] as uint64);
			let carry = wide >> 31;
			for (let j = 1; j < n; j++) {
				wide = (d[j] as uint64) + ai * (b[j] as uint64) + f64 * (mv[j] as uint64) + carry;
				d[j - 1] = (wide as uint32) & tMask;
				carry = wide >> 31;
			}
			wide = overflow + carry;
			d[n - 1] = (wide as uint32) & tMask;
			overflow = wide >> 31;
		}
		return overflow as uint32;
	} else {
		const n = m.v.length;
		const mv = m.v;
		let overflow: uint32 = 0;
		for (let i = 0; i < n; i++) {
			const ai = a[i];
			let lo = ai * b[0];
			let zLo = d[0] + lo;
			const f = (zLo * m.m0inv) & tMask;
			let zHi = mulHi(ai, b[0]) + carryOut(d[0], lo, zLo);
			lo = f * mv[0];
			let sum = zLo + lo;
			zHi += carryOut(zLo, lo, sum) + mulHi(f, mv[0]);
			zLo = sum;
			let carry = (zHi << 1) | (zLo >> tShift);
			for (let j = 1; j < n; j++) {
				lo = ai * b[j];
				zLo = d[j] + lo;
				zHi = mulHi(ai, b[j]) + carryOut(d[j], lo, zLo);
				lo = f * mv[j];
				sum = zLo + lo;
				zHi += carryOut(zLo, lo, sum) + mulHi(f, mv[j]);
				zLo = sum + carry;
				zHi += carryOut(sum, carry, zLo);
				d[j - 1] = zLo & tMask;
				carry = (zHi << 1) | (zLo >> tShift);
			}
			const z = overflow + carry;
			d[n - 1] = z & tMask;
			overflow = z >> tShift;
		}
		return overflow;
	}
}

function montgomeryMul(
	m: Modulus,
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32[] {
	const d = m.zero();
	const overflow = montgomeryLoop(m, d, x, y);
	const underflow = limbsCmpLt(d, m.v);
	conditionalSub(d, 1 ^ (overflow ^ underflow), m.v);
	return d;
}

function toMontgomery(m: Modulus, x: Readonly<uint32[]>): uint32[] {
	return montgomeryMul(m, x, m.rr);
}

function fromMontgomery(m: Modulus, x: Readonly<uint32[]>): uint32[] {
	return montgomeryMul(m, x, m.one());
}

export function mul(
	this m: Modulus,
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32[] {
	return fromMontgomery(
		m,
		montgomeryMul(m, toMontgomery(m, x), toMontgomery(m, y)),
	);
}

export function sq(this m: Modulus, x: Readonly<uint32[]>): uint32[] {
	const xm = toMontgomery(m, x);
	return fromMontgomery(m, montgomeryMul(m, xm, xm));
}

function powInternal(
	m: Modulus,
	x: Readonly<uint32[]>,
	e: Readonly<uint8[]>,
	isPublic: boolean,
): uint32[] | null {
	let acc = 0;
	for (let i = 0; i < e.length; i++) acc |= e[i] as int32;
	if (acc == 0) return null;
	let out = toMontgomery(m, m.one());
	if (isPublic && (e.length < 3 || (e.length == 3 && e[0] <= 0x0f))) {
		const xm = toMontgomery(m, x);
		for (let s = 0; s < e.length; s++) {
			const b = e[s] as uint32;
			let j = 7;
			while (true) {
				out = montgomeryMul(m, out, out);
				if (((b >> (j as uint32)) & 1) != 0) out = montgomeryMul(m, out, xm);
				if (j == 0) break;
				j -= 1;
			}
		}
	} else {
		const pc: uint32[][] = [toMontgomery(m, x)];
		for (let i = 1; i < 15; i++) pc.push(montgomeryMul(m, pc[i - 1], pc[0]));
		let t0 = m.zero();
		for (let s = 0; s < e.length; s++) {
			const b = e[s] as uint32;
			for (const j of [4, 0]) {
				for (let r = 0; r < 4; r++) out = montgomeryMul(m, out, out);
				const k = (b >> (j as uint32)) & 0x0f;
				if (isPublic) {
					if (k == 0) continue;
					t0 = pc[(k as int32) - 1];
				} else {
					for (let i = 0; i < 15; i++) cmov(
						t0,
						1 ^ isNonZero(k ^ ((i + 1) as uint32)),
						pc[i],
					);
				}
				const t1 = montgomeryMul(m, out, t0);
				if (isPublic) {
					out = t1;
				} else {
					cmov(out, isNonZero(k), t1);
				}
			}
		}
		if (!isPublic) {
			for (const entry of pc) wipeWords(entry);
			wipeWords(t0);
		}
	}
	return fromMontgomery(m, out);
}

/** `x^e` mod m with a secret big-endian exponent, in constant time; null for a zero exponent. */
export function pow(
	this m: Modulus,
	x: Readonly<uint32[]>,
	e: Readonly<uint8[]>,
): uint32[] | null {
	return powInternal(m, x, e, false);
}

/** `x^e` mod m with a public big-endian exponent; still constant-time in `x`. */
export function powPublic(
	this m: Modulus,
	x: Readonly<uint32[]>,
	e: Readonly<uint8[]>,
): uint32[] | null {
	return powInternal(m, x, e, true);
}
