/**
 * Arithmetic modulo an odd 256- or 384-bit modulus on 32-bit little-endian limbs, in the
 * Montgomery domain (R = 2^(32 * words)): word-by-word Montgomery multiplication with one final
 * conditional subtraction, and add, sub, opp, select and nonzero as fiat-crypto's 32-bit P-256 and
 * P-384 code computes them. Every operation runs the same sequence for every value, except `pow`,
 * which branches on its exponent, so the exponent must be public.
 */

/** 12 limbs hold a 384-bit value; a 256-bit modulus uses the low 8 and keeps the rest zero. */
export type Limbs = uint32[12];

export struct Modulus {
	words: int32;
	m: Limbs;
	/** -m^-1 mod 2^32. */
	mPrime: uint32;
	/** R^2 mod m: multiplying by it enters the Montgomery domain. */
	r2: Limbs;
	/** R mod m, the Montgomery form of 1. */
	one: Limbs;
	/** m - 2, the inversion exponent. */
	invExp: Limbs;
}

export function zeroLimbs(): Limbs {
	return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
}

/** `a` when `flag` is 0, `b` when it is 1, without a branch. */
export function select(md: Readonly<Modulus>, flag: uint32, a: Limbs, b: Limbs): Limbs {
	const mask = (0 as uint32) - flag;
	let out = zeroLimbs();
	for (let i = 0; i < md.words; i++) out[i] = (a[i] & ~mask) | (b[i] & mask);
	return out;
}

/** 0 for zero, 1 otherwise. */
export function nonzero(md: Readonly<Modulus>, a: Limbs): uint32 {
	let acc: uint32 = 0;
	for (let i = 0; i < md.words; i++) acc |= a[i];
	return (((acc as uint64) + 0xffffffff) >> 32) as uint32;
}

/** `t` minus m when that does not borrow past `top`, the bit above the low limbs; `t` is below 2m. */
function subtractOnce(md: Readonly<Modulus>, t: Limbs, top: uint32): Limbs {
	let d = zeroLimbs();
	let borrow: uint64 = 0;
	for (let i = 0; i < md.words; i++) {
		const x = (t[i] as uint64) - (md.m[i] as uint64) - borrow;
		d[i] = x as uint32;
		borrow = x >> 63;
	}
	const under = (((top as uint64) - borrow) >> 63) as uint32;
	return select(md, under, d, t);
}

export function mul(md: Readonly<Modulus>, a: Limbs, b: Limbs): Limbs {
	const n = md.words;
	let t: uint32[14] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	for (let i = 0; i < n; i++) {
		const bi = b[i] as uint64;
		let carry: uint64 = 0;
		for (let j = 0; j < n; j++) {
			const x = (t[j] as uint64) + (a[j] as uint64) * bi + carry;
			t[j] = x as uint32;
			carry = x >> 32;
		}
		const high = (t[n] as uint64) + carry;
		t[n] = high as uint32;
		t[n + 1] = (high >> 32) as uint32;
		const q = (t[0] * md.mPrime) as uint64;
		let x = (t[0] as uint64) + q * (md.m[0] as uint64);
		carry = x >> 32;
		for (let j = 1; j < n; j++) {
			x = (t[j] as uint64) + q * (md.m[j] as uint64) + carry;
			t[j - 1] = x as uint32;
			carry = x >> 32;
		}
		x = (t[n] as uint64) + carry;
		t[n - 1] = x as uint32;
		t[n] = t[n + 1] + ((x >> 32) as uint32);
	}
	let low = zeroLimbs();
	for (let i = 0; i < n; i++) low[i] = t[i];
	return subtractOnce(md, low, t[n]);
}

export function square(md: Readonly<Modulus>, a: Limbs): Limbs {
	return mul(md, a, a);
}

export function add(md: Readonly<Modulus>, a: Limbs, b: Limbs): Limbs {
	let s = zeroLimbs();
	let carry: uint64 = 0;
	for (let i = 0; i < md.words; i++) {
		const x = (a[i] as uint64) + (b[i] as uint64) + carry;
		s[i] = x as uint32;
		carry = x >> 32;
	}
	return subtractOnce(md, s, carry as uint32);
}

export function sub(md: Readonly<Modulus>, a: Limbs, b: Limbs): Limbs {
	let d = zeroLimbs();
	let borrow: uint64 = 0;
	for (let i = 0; i < md.words; i++) {
		const x = (a[i] as uint64) - (b[i] as uint64) - borrow;
		d[i] = x as uint32;
		borrow = x >> 63;
	}
	const mask = (0 as uint32) - (borrow as uint32);
	let out = zeroLimbs();
	let carry: uint64 = 0;
	for (let i = 0; i < md.words; i++) {
		const x = (d[i] as uint64) + ((md.m[i] & mask) as uint64) + carry;
		out[i] = x as uint32;
		carry = x >> 32;
	}
	return out;
}

export function opp(md: Readonly<Modulus>, a: Limbs): Limbs {
	return sub(md, zeroLimbs(), a);
}

export function equal(md: Readonly<Modulus>, a: Limbs, b: Limbs): boolean {
	return nonzero(md, sub(md, a, b)) == 0;
}

export function toMontgomery(md: Readonly<Modulus>, a: Limbs): Limbs {
	return mul(md, a, md.r2);
}

export function fromMontgomery(md: Readonly<Modulus>, a: Limbs): Limbs {
	let unit = zeroLimbs();
	unit[0] = 1;
	return mul(md, a, unit);
}

/** a^e for a public exponent `e` (plain limbs), four bits at a time from the top. */
export function pow(md: Readonly<Modulus>, a: Limbs, e: Limbs): Limbs {
	const table: Limbs[] = [md.one, a];
	for (let i = 2; i < 16; i++) table.push(mul(md, table[i - 1], a));
	let r: Limbs = md.one;
	for (let i = md.words - 1; i >= 0; i--) {
		for (let shift = 28; shift >= 0; shift -= 4) {
			r = square(md, square(md, square(md, square(md, r))));
			const nibble = ((e[i] >> (shift as uint32)) & 15) as int32;
			if (nibble != 0) r = mul(md, r, table[nibble]);
		}
	}
	return r;
}

/** a^-1, and 0 for 0. */
export function invert(md: Readonly<Modulus>, a: Limbs): Limbs {
	return pow(md, a, md.invExp);
}

function load(md: Readonly<Modulus>, bytes: Readonly<uint8[]>, from: int32): Limbs {
	let out = zeroLimbs();
	const size = 4 * md.words;
	for (let i = 0; i < size; i++) {
		const at = size - 1 - i;
		out[at >> 2] |= (bytes[from + i] as uint32) << (((at & 3) * 8) as uint32);
	}
	return out;
}

/** Big-endian bytes, `4 * words` of them, as plain limbs; null when the value is not below m. */
export function fromBytes(md: Readonly<Modulus>, bytes: Readonly<uint8[]>, from: int32): Limbs | null {
	const out = load(md, bytes, from);
	let borrow: uint64 = 0;
	for (let i = 0; i < md.words; i++) {
		const x = (out[i] as uint64) - (md.m[i] as uint64) - borrow;
		borrow = x >> 63;
	}
	return borrow == 1 ? out : null;
}

/** Big-endian bytes, `4 * words` of them, reduced by one subtraction, so exact when m > 2^(32 * words - 1). */
export function reduceBytes(md: Readonly<Modulus>, bytes: Readonly<uint8[]>, from: int32): Limbs {
	return subtractOnce(md, load(md, bytes, from), 0);
}

/** Plain limbs as `4 * words` big-endian bytes. */
export function toBytes(md: Readonly<Modulus>, a: Limbs): uint8[] {
	const size = 4 * md.words;
	const out = new Array<uint8>(size);
	for (let i = 0; i < size; i++) {
		const at = size - 1 - i;
		out[i] = (a[at >> 2] >> (((at & 3) * 8) as uint32)) as uint8;
	}
	return out;
}
