import { declassify, valueBarrier, valueBarrier64, wipeWords, wipeWords64 } from "./secret";
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
				if (declassify(limb | orLimbs(x, i + 1)) != 0) return null;
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
	return mulAddWith(acc, x, y, new Array<uint32>(2 * acc.length));
}

// `uintMulAdd` on a caller's `2 * acc.length`-limb workspace, cleared before it returns.
function mulAddWith(
	acc: uint32[],
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
	wide: uint32[],
): uint32 {
	const n = acc.length;
	for (let i = 0; i < n; i++) wide[i] = acc[i];
	for (let i = 0; i < n; i++) wide[i + n] = mulAddLimb(wide, i, x, y[i]);
	for (let i = 0; i < n; i++) acc[i] = wide[i];
	const overflow = isNonZero(orLimbs(wide, n));
	wipeWords(wide);
	return overflow;
}

test "multiply-add clears its workspace and keeps the low half" {
	const acc: uint32[] = [5, 0];
	const wide = new Array<uint32>(4);
	assert mulAddWith(acc, [0x7fffffff, 0], [3, 0], wide) == 0;
	assert acc[0] == 2 && acc[1] == 3;
	for (const limb of wide) assert limb == 0, "mulAddWith: workspace not erased";
}

/** The full product, `x.length + y.length` limbs wide. */
export function uintMul(
	x: Readonly<uint32[]>,
	y: Readonly<uint32[]>,
): uint32[] {
	const width = x.length + y.length;
	const acc = new Array<uint32>(width);
	const wx = uintWiden(x, width);
	const wy = uintWiden(y, width);
	const overflow = uintMulAdd(acc, wx, wy);
	wipeWords(wx);
	wipeWords(wy);
	if (declassify(overflow) != 0) throw new Error("uintMul: the product overflowed its own width");
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
	const widened = x.length >= n ? null : uintWiden(x, n);
	const wide = widened ?? x;
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
	if (widened != null) wipeWords(widened);
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
	wipeWords(m);
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
	if (!uintIsOdd(n)) throw new Error("uintGcdModinvOdd: the modulus is even");
	when (c) {
		return wideGcdModinvOdd(a, n);
	} else {
		return narrowGcdModinvOdd(a, n);
	}
}

function narrowGcdModinvOdd(
	a: Readonly<uint32[]>,
	n: Readonly<uint32[]>,
): GcdInverse {
	const limbs = n.length;
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
	const found = uintGcdModinvOdd(a, b);
	for (const scratch of [a, b, found.inverse]) wipeWords(scratch);
	const g = found.gcd;
	shiftLeft(g, Math.min(aShift, bShift) as int32);
	return g;
}

/** Zeroes secret scratch once it is no longer needed. */
export function uintWipe(x: uint32[]): void {
	for (let i = 0; i < x.length; i++) x[i] = 0;
}

when (c) {
	@include("runtime/core/mulWide.h");
	extern function msMulHi64(a: uint64, b: uint64): uint64;

	const zero64: uint64 = 0;
	const one64: uint64 = 1;

	interface WideSetup {
		w: uint64[];
		rr: uint64[];
		one: uint64[];
		m0inv: uint64;
	}

	function wideLimbsFor(bits: int32): int32 {
		return (bits + 63) >> 6;
	}

	// 31-bit limbs into `size` 64-bit limbs; the value must fit.
	function toWide(x: Readonly<uint32[]>, size: int32): uint64[] {
		const out = new Array<uint64>(size);
		let acc: uint64 = 0;
		let accBits: uint64 = 0;
		let o = 0;
		for (let i = 0; i < x.length; i++) {
			const limb = x[i] as uint64;
			acc |= limb << accBits;
			accBits += 31;
			if (accBits >= 64) {
				accBits -= 64;
				if (o < size) out[o] = acc;
				o += 1;
				acc = limb >> (31 - accBits);
			}
		}
		if (o < size) out[o] = acc;
		return out;
	}

	// 64-bit limbs into `size` 31-bit limbs; the value must fit.
	function fromWide(x: Readonly<uint64[]>, size: int32): uint32[] {
		const out = new Array<uint32>(size);
		let acc: uint64 = 0;
		let accBits: uint64 = 0;
		let i = 0;
		for (let o = 0; o < size; o++) {
			if (accBits < 31) {
				const next = i < x.length ? x[i] : zero64;
				i += 1;
				out[o] = ((acc | (next << accBits)) as uint32) & tMask;
				acc = next >> (31 - accBits);
				accBits += 33;
			} else {
				out[o] = (acc as uint32) & tMask;
				acc = acc >> 31;
				accBits -= 31;
			}
		}
		return out;
	}

	// out = (x - m when x >= m or `carry` is set, else x), for x below 2m with its bit 64n in `carry`.
	function wideReduceOnce(
		out: uint64[],
		x: Readonly<uint64[]>,
		carry: uint64,
		m: Readonly<uint64[]>,
	): void {
		const n = m.length;
		let borrow: uint64 = 0;
		for (let j = 0; j < n; j++) {
			const xj = x[j];
			const mj = m[j];
			const d = xj - mj - borrow;
			borrow = ((~xj & mj) | (~(xj ^ mj) & d)) >> 63;
			out[j] = d;
		}
		const keep = valueBarrier64(zero64 - (borrow & (carry ^ 1)));
		for (let j = 0; j < n; j++) out[j] = (out[j] & ~keep) | (x[j] & keep);
	}

	// out = a * b / R mod m for a, b below m (a below R and b below m is enough); `t` is n + 1 limbs of scratch.
	// `out` may be `a` or `b`.
	function wideMontMul(
		m: Readonly<uint64[]>,
		m0inv: uint64,
		out: uint64[],
		a: Readonly<uint64[]>,
		b: Readonly<uint64[]>,
		t: uint64[],
	): void {
		const n = m.length;
		for (let j = 0; j <= n; j++) t[j] = 0;
		const b0 = b[0];
		const m0 = m[0];
		for (let i = 0; i < n; i++) {
			const ai = a[i];
			let lo = ai * b0;
			let hi = msMulHi64(ai, b0);
			lo += t[0];
			hi += lo < t[0] ? one64 : zero64;
			let c1 = hi;
			const f = lo * m0inv;
			let lo2 = f * m0;
			let hi2 = msMulHi64(f, m0);
			lo2 += lo;
			hi2 += lo2 < lo ? one64 : zero64;
			let c2 = hi2;
			for (let j = 1; j < n; j++) {
				const bj = b[j];
				const tj = t[j];
				lo = ai * bj;
				hi = msMulHi64(ai, bj);
				lo += tj;
				hi += lo < tj ? one64 : zero64;
				lo += c1;
				hi += lo < c1 ? one64 : zero64;
				c1 = hi;
				const mj = m[j];
				lo2 = f * mj;
				hi2 = msMulHi64(f, mj);
				lo2 += lo;
				hi2 += lo2 < lo ? one64 : zero64;
				lo2 += c2;
				hi2 += lo2 < c2 ? one64 : zero64;
				c2 = hi2;
				t[j - 1] = lo2;
			}
			let top = t[n] + c1;
			let carry = top < c1 ? one64 : zero64;
			top += c2;
			carry += top < c2 ? one64 : zero64;
			t[n - 1] = top;
			t[n] = carry;
		}
		wideReduceOnce(out, t, t[n], m);
	}

	// x = 2x mod m for x below m.
	function wideDouble(x: uint64[], m: Readonly<uint64[]>, t: uint64[]): void {
		const n = m.length;
		let carry: uint64 = 0;
		for (let j = 0; j < n; j++) {
			const xj = x[j];
			t[j] = (xj << 1) | carry;
			carry = xj >> 63;
		}
		wideReduceOnce(x, t, carry, m);
	}

	function wideSetup(v: Readonly<uint32[]>, bits: int32, t: uint64[]): WideSetup {
		const n = wideLimbsFor(bits);
		const w = toWide(v, n);
		const m0 = w[0];
		let y = m0;
		for (let i = 0; i < 5; i++) y = y * (2 - m0 * y);
		const m0inv = zero64 - y;
		// R mod m: 2^(bits - 1) is below m, then doubled up to 2^(64n).
		const one = new Array<uint64>(n);
		one[(bits - 1) >> 6] = one64 << (((bits - 1) & 63) as uint64);
		for (let i = bits - 1; i < 64 * n; i++) wideDouble(one, w, t);
		// R^2 mod m is 2^(64n) in Montgomery form: square-and-double over the bits of 64n from Montgomery one.
		const rr = new Array<uint64>(n);
		for (let j = 0; j < n; j++) rr[j] = one[j];
		const e = 64 * n;
		let bit = 31 - clz32(e as uint32);
		while (bit >= 0) {
			wideMontMul(w, m0inv, rr, rr, rr, t);
			if (((e >> bit) & 1) != 0) wideDouble(rr, w, t);
			bit -= 1;
		}
		wideWipe(t);
		return { w, rr, one, m0inv };
	}

	test "wide setup clears its workspace and keeps the constants" {
		const m = modulusFromBytes("0100000000000000000000000000000033".decodeHex());
		if (m == null) throw new Error("multiword modulus fixture rejected");
		const t = new Array<uint64>(m.w.length + 1);
		const wide = wideSetup(m.v, m.bits(), t);
		for (const word of t) assert word == 0, "wideSetup: workspace not erased";
		for (let i = 0; i < m.w.length; i++) {
			assert wide.w[i] == m.w[i];
			assert wide.rr[i] == m.wrr[i];
			assert wide.one[i] == m.wone[i];
		}
		assert wide.m0inv == m.wm0inv;
	}

	function wideToMont(m: Modulus, x: Readonly<uint32[]>, t: uint64[]): uint64[] {
		const out = toWide(x, m.w.length);
		wideMontMul(m.w, m.wm0inv, out, out, m.wrr, t);
		return out;
	}

	function wideFromMont(m: Modulus, x: uint64[], t: uint64[]): uint32[] {
		const unit = new Array<uint64>(m.w.length);
		unit[0] = 1;
		wideMontMul(m.w, m.wm0inv, x, x, unit, t);
		const result = fromWide(x, m.v.length);
		wideWipe(x);
		wideWipe(t);
		return result;
	}

	test "wide conversion clears one-word input after copying its result" {
		const m = modulusFromBytes("03fb".decodeHex());
		if (m == null) throw new Error("one-word modulus fixture rejected");
		assert m.w.length == 1;
		const cache: uint64[] = [];
		for (const word of m.wone) cache.push(word);
		for (const value of [0 as uint32, 7 as uint32]) {
			const t = new Array<uint64>(m.w.length + 1);
			const wide = wideToMont(m, [value], t);
			const result = wideFromMont(m, wide, t);
			assert result[0] == value;
			for (let i = 1; i < result.length; i++) assert result[i] == 0;
			for (let i = 0; i < cache.length; i++) assert m.wone[i] == cache[i];
			for (const word of wide) assert word == 0, "wideFromMont: one-word input not erased";
			for (const word of t) assert word == 0, "wideFromMont: one-word workspace not erased";
		}
	}

	test "wide conversion clears multiword workspace after copying its result" {
		const m = modulusFromBytes("0100000000000000000000000000000033".decodeHex());
		if (m == null) throw new Error("multiword modulus fixture rejected");
		assert m.w.length == 3;
		const cache: uint64[] = [];
		for (const word of m.wone) cache.push(word);
		for (const value of [0 as uint32, 7 as uint32]) {
			const t = new Array<uint64>(m.w.length + 1);
			const wide = wideToMont(m, [value], t);
			const result = wideFromMont(m, wide, t);
			assert result[0] == value;
			for (let i = 1; i < result.length; i++) assert result[i] == 0;
			for (let i = 0; i < cache.length; i++) assert m.wone[i] == cache[i];
			for (const word of t) assert word == 0, "wideFromMont: multiword workspace not erased";
			for (const word of wide) assert word == 0, "wideFromMont: multiword input not erased";
		}
	}

	function wideMul(
		m: Modulus,
		x: Readonly<uint32[]>,
		y: Readonly<uint32[]>,
	): uint32[] {
		const n = m.w.length;
		const t = new Array<uint64>(n + 1);
		const xw = toWide(x, n);
		const yw = wideToMont(m, y, t);
		wideMontMul(m.w, m.wm0inv, xw, xw, yw, t);
		const out = fromWide(xw, m.v.length);
		wideWipe(xw);
		wideWipe(yw);
		wideWipe(t);
		return out;
	}

	// Any integer reduced mod m: Horner over n-limb chunks in Montgomery form, each chunk entering as chunk * R^2 / R.
	function wideReduce(m: Modulus, x: Readonly<uint32[]>): uint32[] {
		const n = m.w.length;
		const chunks = (wideLimbsFor(x.length * tBits) + n - 1) / n;
		const xw = toWide(x, chunks * n);
		const t = new Array<uint64>(n + 1);
		const acc = new Array<uint64>(n);
		const chunk = new Array<uint64>(n);
		let k = chunks;
		while (k > 0) {
			k -= 1;
			wideMontMul(m.w, m.wm0inv, acc, acc, m.wrr, t);
			for (let j = 0; j < n; j++) chunk[j] = xw[k * n + j];
			wideMontMul(m.w, m.wm0inv, chunk, chunk, m.wrr, t);
			let carry: uint64 = 0;
			for (let j = 0; j < n; j++) {
				const s = acc[j] + chunk[j];
				const c = s < acc[j] ? one64 : zero64;
				const s2 = s + carry;
				carry = c + (s2 < s ? one64 : zero64);
				t[j] = s2;
			}
			wideReduceOnce(acc, t, carry, m.w);
		}
		const out = wideFromMont(m, acc, t);
		wideWipe(xw);
		wideWipe(chunk);
		return out;
	}

	// x -= y over x's limbs; returns the borrow.
	function wideSub(x: uint64[], y: Readonly<uint64[]>): uint64 {
		let borrow: uint64 = 0;
		for (let j = 0; j < x.length; j++) {
			const xj = x[j];
			const yj = y[j];
			const d = xj - yj - borrow;
			borrow = ((~xj & yj) | (~(xj ^ yj) & d)) >> 63;
			x[j] = d;
		}
		return borrow;
	}

	// 1 when x < y.
	function wideLt(x: Readonly<uint64[]>, y: Readonly<uint64[]>): uint64 {
		let borrow: uint64 = 0;
		for (let j = 0; j < x.length; j++) {
			const xj = x[j];
			const yj = y[j];
			const d = xj - yj - borrow;
			borrow = ((~xj & yj) | (~(xj ^ yj) & d)) >> 63;
		}
		return borrow;
	}

	// x += y when `on` is 1; returns the carry.
	function wideCondAdd(x: uint64[], on: uint64, y: Readonly<uint64[]>): uint64 {
		const mask = zero64 - on;
		let carry: uint64 = 0;
		for (let j = 0; j < x.length; j++) {
			const xj = x[j];
			const s = xj + (y[j] & mask);
			const c = s < xj ? one64 : zero64;
			const s2 = s + carry;
			carry = c + (s2 < s ? one64 : zero64);
			x[j] = s2;
		}
		return carry;
	}

	function wideCmov(x: uint64[], on: uint64, y: Readonly<uint64[]>): void {
		const mask = zero64 - on;
		for (let j = 0; j < x.length; j++) x[j] ^= mask & (x[j] ^ y[j]);
	}

	function wideCondSwap(x: uint64[], y: uint64[], on: uint64): void {
		const mask = zero64 - on;
		for (let j = 0; j < x.length; j++) {
			const t = mask & (x[j] ^ y[j]);
			x[j] ^= t;
			y[j] ^= t;
		}
	}

	function wideShiftRightOne(x: uint64[], carry: uint64): void {
		let c = carry;
		let j = x.length;
		while (j != 0) {
			j -= 1;
			const xj = x[j];
			x[j] = (xj >> 1) | (c << 63);
			c = xj & 1;
		}
	}

	// The odd-modulus gcd and inverse of `uintGcdModinvOdd` on 64-bit limbs, step for step.
	function wideGcdModinvOdd(
		a: Readonly<uint32[]>,
		n: Readonly<uint32[]>,
	): GcdInverse {
		const limbs = n.length;
		const k = wideLimbsFor(limbs * tBits);
		const aWide = wideLimbsFor((Math.min(a.length, limbs) as int32) * tBits);
		const nw = toWide(n, k);
		const u = toWide(uintWiden(a, limbs), k);
		const v = toWide(n, k);
		const q = new Array<uint64>(k);
		const r = new Array<uint64>(k);
		r[0] = 1;
		const d = new Array<uint64>(k);
		const dq = new Array<uint64>(k);
		const steps = (aWide + k) * 64;
		for (let i = 0; i < steps; i++) {
			const uOdd = u[0] & 1;
			const vOdd = v[0] & 1;
			const uOddVOdd = uOdd & vOdd;
			const uEven = uOdd ^ 1;
			const notBothOdd = uOddVOdd ^ 1;

			for (let j = 0; j < k; j++) d[j] = v[j];
			wideSub(d, u);
			wideCmov(v, uOddVOdd, d);
			wideCmov(v, uEven, u);
			wideCmov(u, notBothOdd, d);
			wideShiftRightOne(v, 0);
			const swap = wideLt(v, u);
			wideCondSwap(u, v, swap);

			for (let j = 0; j < k; j++) dq[j] = q[j];
			wideCondAdd(dq, wideSub(dq, r), nw);
			wideCmov(q, uOddVOdd, dq);
			wideCmov(q, uEven, r);
			wideCmov(r, notBothOdd, dq);
			wideShiftRightOne(q, wideCondAdd(q, q[0] & 1, nw));
			wideCondSwap(r, q, swap);
		}
		const gcd = fromWide(v, limbs);
		const inverse = fromWide(q, limbs);
		for (const scratch of [u, v, q, r, d, dq]) wideWipe(scratch);
		return { gcd, inverse };
	}

	function wideWipe(x: uint64[]): void {
		for (let i = 0; i < x.length; i++) x[i] = 0;
	}

	// The window width mbedTLS's exponentiation takes for an exponent of this many bits.
	function windowBits(exponentBits: int32): int32 {
		if (exponentBits > 671) return 6;
		if (exponentBits > 239) return 5;
		if (exponentBits > 79) return 4;
		return 1;
	}

	function widePow(
		m: Modulus,
		x: Readonly<uint32[]>,
		e: Readonly<uint8[]>,
		isPublic: boolean,
	): uint32[] {
		const n = m.w.length;
		const t = new Array<uint64>(n + 1);
		const xm = wideToMont(m, x, t);
		const out = new Array<uint64>(n);
		const totalBits = e.length * 8;
		const wsize = windowBits(totalBits);
		if (isPublic && wsize == 1) {
			let started = false;
			for (let s = 0; s < e.length; s++) {
				const b = e[s] as uint32;
				let j = 7;
				while (true) {
					if (started) wideMontMul(m.w, m.wm0inv, out, out, out, t);
					if (((b >> (j as uint32)) & 1) != 0) {
						if (started) {
							wideMontMul(m.w, m.wm0inv, out, out, xm, t);
						} else {
							for (let i = 0; i < n; i++) out[i] = xm[i];
							started = true;
						}
					}
					if (j == 0) break;
					j -= 1;
				}
			}
			return wideFromMont(m, out, t);
		}
		const count = 1 << wsize;
		const table: uint64[][] = [m.wone, xm];
		for (let i = 2; i < count; i++) {
			const entry = new Array<uint64>(n);
			wideMontMul(m.w, m.wm0inv, entry, table[i - 1], xm, t);
			table.push(entry);
		}
		for (let i = 0; i < n; i++) out[i] = m.wone[i];
		const selected = new Array<uint64>(n);
		let window: int32 = 0;
		let windowFill = 0;
		for (let bitAt = totalBits - 1; bitAt >= 0; bitAt--) {
			wideMontMul(m.w, m.wm0inv, out, out, out, t);
			const bit = ((e[e.length - 1 - (bitAt >> 3)] as int32) >> (bitAt & 7)) & 1;
			window = (window << 1) | bit;
			windowFill += 1;
			if (windowFill == wsize || bitAt == 0) {
				if (isPublic) {
					wideMontMul(m.w, m.wm0inv, out, out, table[window], t);
				} else {
					for (let i = 0; i < n; i++) selected[i] = 0;
					for (let k = 0; k < count; k++) {
						const diff = (k ^ window) as uint32;
						const hit = valueBarrier64(zero64 - ((((diff | ((0 as uint32) - diff)) >> 31) ^ 1) as uint64));
						const entry = table[k];
						for (let i = 0; i < n; i++) selected[i] |= entry[i] & hit;
					}
					wideMontMul(m.w, m.wm0inv, out, out, selected, t);
				}
				window = 0;
				windowFill = 0;
			}
		}
		const result = wideFromMont(m, out, t);
		if (!isPublic) {
			for (let i = 1; i < count; i++) wideWipe(table[i]);
			wideWipe(selected);
		}
		return result;
	}
}

/**
 * An odd modulus above 2 with its Montgomery constants; build it with `modulusFromUint` or `modulusFromBytes`.
 * On C the Montgomery work runs on 64-bit limbs (`w`, with R = 2^(64 * w.length)) and `rr` stays empty; on
 * JavaScript it runs on the 31-bit limbs and the 64-bit fields stay empty.
 */
export struct Modulus {
	v: uint32[];
	rr: uint32[];
	m0inv: uint32;
	leading: int32;
	w: uint64[];
	wrr: uint64[];
	wone: uint64[];
	wm0inv: uint64;
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
	const leading = clz32(hi) - 1;
	when (c) {
		const bits = v.length * tBits - leading;
		const wide = wideSetup(v, bits, new Array<uint64>(wideLimbsFor(bits) + 1));
		return {
			v,
			rr: [],
			m0inv: computeM0Inv(v[0]),
			leading,
			w: wide.w,
			wrr: wide.rr,
			wone: wide.one,
			wm0inv: wide.m0inv,
		};
	} else {
		const n = v.length;
		const rr = new Array<uint32>(n);
		rr[n - 1] = 1;
		for (let i = n - 1; i < 2 * n; i++) shiftIn(v, rr, 0);
		return {
			v,
			rr,
			m0inv: computeM0Inv(v[0]),
			leading,
			w: [],
			wrr: [],
			wone: [],
			wm0inv: 0,
		};
	}
}

/** Clears every limb and Montgomery constant of a modulus that is no longer used. */
export function wipeModulus(m: Modulus): void {
	wipeWords(m.v);
	wipeWords(m.rr);
	wipeWords64(m.w);
	wipeWords64(m.wrr);
	wipeWords64(m.wone);
}

export function modulusFromBytes(bytes: Readonly<uint8[]>): Modulus | null {
	const v = uintFromBytes(bytes, limbsFor(bytes.length * 8));
	if (v == null) return null;
	return modulusFromOwnedUint(v);
}

/** `modulusFromUint` that clears `value` once the modulus holds its own copy, kept or rejected. */
export function modulusFromOwnedUint(value: uint32[]): Modulus | null {
	const m = modulusFromUint(value);
	wipeWords(value);
	return m;
}

test "modulus from an owned integer clears it, kept or rejected" {
	const kept: uint32[] = [0x33, 0, 0, 0, 8];
	const m = modulusFromOwnedUint(kept);
	if (m == null) throw new Error("odd modulus fixture rejected");
	for (const limb of kept) assert limb == 0, "modulusFromOwnedUint: kept input not erased";
	assert m.v[0] == 0x33 && m.v[4] == 8;
	const rejected: uint32[] = [0x32, 5];
	assert modulusFromOwnedUint(rejected) == null;
	for (const limb of rejected) assert limb == 0, "modulusFromOwnedUint: rejected input not erased";
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
	when (c) {
		return wideReduce(m, x);
	} else {
		return reduceInto(m.v, x, null);
	}
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
	when (c) {
		return wideMul(m, x, y);
	} else {
		return fromMontgomery(
			m,
			montgomeryMul(m, toMontgomery(m, x), toMontgomery(m, y)),
		);
	}
}

export function sq(this m: Modulus, x: Readonly<uint32[]>): uint32[] {
	when (c) {
		return wideMul(m, x, x);
	} else {
		const xm = toMontgomery(m, x);
		return fromMontgomery(m, montgomeryMul(m, xm, xm));
	}
}

function powInternal(
	m: Modulus,
	x: Readonly<uint32[]>,
	e: Readonly<uint8[]>,
	isPublic: boolean,
): uint32[] | null {
	let acc = 0;
	for (let i = 0; i < e.length; i++) acc |= e[i] as int32;
	if (declassify(acc as uint32) == 0) return null;
	when (c) {
		return widePow(m, x, e, isPublic);
	} else {
		return narrowPow(m, x, e, isPublic);
	}
}

function narrowPow(
	m: Modulus,
	x: Readonly<uint32[]>,
	e: Readonly<uint8[]>,
	isPublic: boolean,
): uint32[] {
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
