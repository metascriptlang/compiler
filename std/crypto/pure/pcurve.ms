/**
 * The groups of P-256 and P-384 over ./montgomery: projective points with the complete
 * addition and doubling formulas for a = -3 (Renes, Costello and Batina 2015, algorithms 4 and 6),
 * a constant-time fixed-window multiplication for secret scalars and a variable-time double-base
 * multiplication for public ones, as Zig's std.crypto.pcurves does. Scalars are big-endian bytes.
 * On the native backend a secret multiple of the base point adds one entry of a per-window table
 * of affine multiples per signed 4-bit digit and doubles nothing, as BoringSSL's P-256 does.
 */

import {
	Limbs, Modulus, zeroLimbs, select, nonzero, mul, square, add, sub, opp, equal,
	invert, pow, fromBytes, toBytes, toMontgomery, fromMontgomery,
} from "./montgomery";
import { valueBarrier } from "./secret";
import { p256Windows, p384Windows } from "./pcurveBaseTable";

export struct CurveMath {
	field: Modulus;
	order: Modulus;
	/** The curve's b, Montgomery form. */
	b: Limbs;
	/** The base point, Montgomery form. */
	gx: Limbs;
	gy: Limbs;
	/** (p + 1) / 4: both primes are 3 mod 4. */
	sqrtExp: Limbs;
	/** (p - 1) / 2, the Legendre exponent. */
	squareExp: Limbs;
}

export struct Point {
	x: Limbs;
	y: Limbs;
	z: Limbs;
}

export const p256Math: Readonly<CurveMath> = {
	field: {
		words: 8,
		m: [
			0xffffffff, 0xffffffff, 0xffffffff, 0x00000000, 0x00000000, 0x00000000,
			0x00000001, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		mPrime: 0x00000001,
		r2: [
			0x00000003, 0x00000000, 0xffffffff, 0xfffffffb, 0xfffffffe, 0xffffffff,
			0xfffffffd, 0x00000004, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		one: [
			0x00000001, 0x00000000, 0x00000000, 0xffffffff, 0xffffffff, 0xffffffff,
			0xfffffffe, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		invExp: [
			0xfffffffd, 0xffffffff, 0xffffffff, 0x00000000, 0x00000000, 0x00000000,
			0x00000001, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
	},
	order: {
		words: 8,
		m: [
			0xfc632551, 0xf3b9cac2, 0xa7179e84, 0xbce6faad, 0xffffffff, 0xffffffff,
			0x00000000, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		mPrime: 0xee00bc4f,
		r2: [
			0xbe79eea2, 0x83244c95, 0x49bd6fa6, 0x4699799c, 0x2b6bec59, 0x2845b239,
			0xf3d95620, 0x66e12d94, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		one: [
			0x039cdaaf, 0x0c46353d, 0x58e8617b, 0x43190552, 0x00000000, 0x00000000,
			0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		invExp: [
			0xfc63254f, 0xf3b9cac2, 0xa7179e84, 0xbce6faad, 0xffffffff, 0xffffffff,
			0x00000000, 0xffffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
	},
	b: [
		0x29c4bddf, 0xd89cdf62, 0x78843090, 0xacf005cd, 0xf7212ed6, 0xe5a220ab,
		0x04874834, 0xdc30061d, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
	],
	gx: [
		0x18a9143c, 0x79e730d4, 0x5fedb601, 0x75ba95fc, 0x77622510, 0x79fb732b,
		0xa53755c6, 0x18905f76, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
	],
	gy: [
		0xce95560a, 0xddf25357, 0xba19e45c, 0x8b4ab8e4, 0xdd21f325, 0xd2e88688,
		0x25885d85, 0x8571ff18, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
	],
	sqrtExp: [
		0x00000000, 0x00000000, 0x40000000, 0x00000000, 0x00000000, 0x40000000,
		0xc0000000, 0x3fffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
	],
	squareExp: [
		0xffffffff, 0xffffffff, 0x7fffffff, 0x00000000, 0x00000000, 0x80000000,
		0x80000000, 0x7fffffff, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
	],
};

export const p384Math: Readonly<CurveMath> = {
	field: {
		words: 12,
		m: [
			0xffffffff, 0x00000000, 0x00000000, 0xffffffff, 0xfffffffe, 0xffffffff,
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
		],
		mPrime: 0x00000001,
		r2: [
			0x00000001, 0xfffffffe, 0x00000000, 0x00000002, 0x00000000, 0xfffffffe,
			0x00000000, 0x00000002, 0x00000001, 0x00000000, 0x00000000, 0x00000000,
		],
		one: [
			0x00000001, 0xffffffff, 0xffffffff, 0x00000000, 0x00000001, 0x00000000,
			0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		invExp: [
			0xfffffffd, 0x00000000, 0x00000000, 0xffffffff, 0xfffffffe, 0xffffffff,
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
		],
	},
	order: {
		words: 12,
		m: [
			0xccc52973, 0xecec196a, 0x48b0a77a, 0x581a0db2, 0xf4372ddf, 0xc7634d81,
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
		],
		mPrime: 0xe88fdc45,
		r2: [
			0x19b409a9, 0x2d319b24, 0xdf1aa419, 0xff3d81e5, 0xfcb82947, 0xbc3e483a,
			0x4aab1cc5, 0xd40d4917, 0x28266895, 0x3fb05b7a, 0x2b39bf21, 0x0c84ee01,
		],
		one: [
			0x333ad68d, 0x1313e695, 0xb74f5885, 0xa7e5f24d, 0x0bc8d220, 0x389cb27e,
			0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
		],
		invExp: [
			0xccc52971, 0xecec196a, 0x48b0a77a, 0x581a0db2, 0xf4372ddf, 0xc7634d81,
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
		],
	},
	b: [
		0x9d412dcc, 0x08118871, 0x7a4c32ec, 0xf729add8, 0x1920022e, 0x77f2209b,
		0x94938ae2, 0xe3374bee, 0x1f022094, 0xb62b21f4, 0x604fbff9, 0xcd08114b,
	],
	gx: [
		0x49c0b528, 0x3dd07566, 0xa0d6ce38, 0x20e378e2, 0x541b4d6e, 0x879c3afc,
		0x59a30eff, 0x64548684, 0x614ede2b, 0x812ff723, 0x299e1513, 0x4d3aadc2,
	],
	gy: [
		0x4b03a4fe, 0x23043dad, 0x7bb4a9ac, 0xa1bfa8bf, 0x2e83b050, 0x8bade756,
		0x68f4ffd9, 0xc6c35219, 0x3969a840, 0xdd800226, 0x5a15c5e9, 0x2b78abc2,
	],
	sqrtExp: [
		0x40000000, 0x00000000, 0xc0000000, 0xbfffffff, 0xffffffff, 0xffffffff,
		0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0x3fffffff,
	],
	squareExp: [
		0x7fffffff, 0x00000000, 0x80000000, 0x7fffffff, 0xffffffff, 0xffffffff,
		0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0x7fffffff,
	],
};

export function identity(cm: Readonly<CurveMath>): Point {
	return { x: zeroLimbs(), y: cm.field.one, z: zeroLimbs() };
}

export function basePoint(cm: Readonly<CurveMath>): Point {
	return { x: cm.gx, y: cm.gy, z: cm.field.one };
}

/** The identity: z is zero, or the affine encodings (0, 0) and (0, 1). */
export function isIdentity(cm: Readonly<CurveMath>, p: Point): boolean {
	const f = cm.field;
	const zeroX = nonzero(f, p.x) == 0;
	const zeroOrOneY = nonzero(f, p.y) == 0 || equal(f, p.y, f.one);
	return nonzero(f, p.z) == 0 || (zeroX && zeroOrOneY);
}

export function neg(cm: Readonly<CurveMath>, p: Point): Point {
	return { x: p.x, y: opp(cm.field, p.y), z: p.z };
}

function selectPoint(cm: Readonly<CurveMath>, flag: uint32, a: Point, b: Point): Point {
	const f = cm.field;
	return { x: select(f, flag, a.x, b.x), y: select(f, flag, a.y, b.y), z: select(f, flag, a.z, b.z) };
}

export function dbl(cm: Readonly<CurveMath>, p: Point): Point {
	const f = cm.field;
	let t0 = square(f, p.x);
	const t1 = square(f, p.y);
	let t2 = square(f, p.z);
	let t3 = mul(f, p.x, p.y);
	t3 = add(f, t3, t3);
	let z3 = mul(f, p.x, p.z);
	z3 = add(f, z3, z3);
	let y3 = mul(f, cm.b, t2);
	y3 = sub(f, y3, z3);
	let x3 = add(f, y3, y3);
	y3 = add(f, x3, y3);
	x3 = sub(f, t1, y3);
	y3 = add(f, t1, y3);
	y3 = mul(f, x3, y3);
	x3 = mul(f, x3, t3);
	t3 = add(f, t2, t2);
	t2 = add(f, t2, t3);
	z3 = mul(f, cm.b, z3);
	z3 = sub(f, z3, t2);
	z3 = sub(f, z3, t0);
	t3 = add(f, z3, z3);
	z3 = add(f, z3, t3);
	t3 = add(f, t0, t0);
	t0 = add(f, t3, t0);
	t0 = sub(f, t0, t2);
	t0 = mul(f, t0, z3);
	y3 = add(f, y3, t0);
	t0 = mul(f, p.y, p.z);
	t0 = add(f, t0, t0);
	z3 = mul(f, t0, z3);
	x3 = sub(f, x3, z3);
	z3 = mul(f, t0, t1);
	z3 = add(f, z3, z3);
	z3 = add(f, z3, z3);
	return { x: x3, y: y3, z: z3 };
}

export function addPoints(cm: Readonly<CurveMath>, p: Point, q: Point): Point {
	const f = cm.field;
	let t0 = mul(f, p.x, q.x);
	let t1 = mul(f, p.y, q.y);
	let t2 = mul(f, p.z, q.z);
	let t3 = add(f, p.x, p.y);
	let t4 = add(f, q.x, q.y);
	t3 = mul(f, t3, t4);
	t4 = add(f, t0, t1);
	t3 = sub(f, t3, t4);
	t4 = add(f, p.y, p.z);
	let x3 = add(f, q.y, q.z);
	t4 = mul(f, t4, x3);
	x3 = add(f, t1, t2);
	t4 = sub(f, t4, x3);
	x3 = add(f, p.x, p.z);
	let y3 = add(f, q.x, q.z);
	x3 = mul(f, x3, y3);
	y3 = add(f, t0, t2);
	y3 = sub(f, x3, y3);
	let z3 = mul(f, cm.b, t2);
	x3 = sub(f, y3, z3);
	z3 = add(f, x3, x3);
	x3 = add(f, x3, z3);
	z3 = sub(f, t1, x3);
	x3 = add(f, t1, x3);
	y3 = mul(f, cm.b, y3);
	t1 = add(f, t2, t2);
	t2 = add(f, t1, t2);
	y3 = sub(f, y3, t2);
	y3 = sub(f, y3, t0);
	t1 = add(f, y3, y3);
	y3 = add(f, t1, y3);
	t1 = add(f, t0, t0);
	t0 = add(f, t1, t0);
	t0 = sub(f, t0, t2);
	t1 = mul(f, t4, y3);
	t2 = mul(f, t0, y3);
	y3 = mul(f, x3, z3);
	y3 = add(f, y3, t2);
	x3 = mul(f, t3, x3);
	x3 = sub(f, x3, t1);
	z3 = mul(f, t4, z3);
	t1 = mul(f, t3, t0);
	z3 = add(f, z3, t1);
	return { x: x3, y: y3, z: z3 };
}

/** An affine point, Montgomery form; x = 0 stands for the identity, as in Zig's addMixed. */
struct Affine {
	x: Limbs;
	y: Limbs;
}

/** p + q for an affine q: algorithm 5 of Renes, Costello and Batina; p itself when q.x is zero. */
function addMixed(cm: Readonly<CurveMath>, p: Point, q: Affine): Point {
	const f = cm.field;
	let t0 = mul(f, p.x, q.x);
	let t1 = mul(f, p.y, q.y);
	let t3 = add(f, q.x, q.y);
	let t4 = add(f, p.x, p.y);
	t3 = mul(f, t3, t4);
	t4 = add(f, t0, t1);
	t3 = sub(f, t3, t4);
	t4 = mul(f, q.y, p.z);
	t4 = add(f, t4, p.y);
	let y3 = mul(f, q.x, p.z);
	y3 = add(f, y3, p.x);
	let z3 = mul(f, cm.b, p.z);
	let x3 = sub(f, y3, z3);
	z3 = add(f, x3, x3);
	x3 = add(f, x3, z3);
	z3 = sub(f, t1, x3);
	x3 = add(f, t1, x3);
	y3 = mul(f, cm.b, y3);
	t1 = add(f, p.z, p.z);
	let t2 = add(f, t1, p.z);
	y3 = sub(f, y3, t2);
	y3 = sub(f, y3, t0);
	t1 = add(f, y3, y3);
	y3 = add(f, t1, y3);
	t1 = add(f, t0, t0);
	t0 = add(f, t1, t0);
	t0 = sub(f, t0, t2);
	t1 = mul(f, t4, y3);
	t2 = mul(f, t0, y3);
	y3 = mul(f, x3, z3);
	y3 = add(f, y3, t2);
	x3 = mul(f, t3, x3);
	x3 = sub(f, x3, t1);
	z3 = mul(f, t4, z3);
	t1 = mul(f, t3, t0);
	z3 = add(f, z3, t1);
	return selectPoint(cm, nonzero(f, q.x) ^ 1, { x: x3, y: y3, z: z3 }, p);
}

function dbl4(cm: Readonly<CurveMath>, p: Point): Point {
	return dbl(cm, dbl(cm, dbl(cm, dbl(cm, p))));
}

/** Multiples 0·p to count·p; the entries past `count` stay the identity. */
function precompute(cm: Readonly<CurveMath>, p: Point, count: int32): Point[16] {
	const o = identity(cm);
	let pc: Point[16] = [o, o, o, o, o, o, o, o, o, o, o, o, o, o, o, o];
	pc[1] = p;
	for (let i = 2; i <= count; i++) {
		pc[i] = i % 2 == 0 ? dbl(cm, pc[i / 2]) : addPoints(cm, pc[i - 1], p);
	}
	return pc;
}

/** The native backend's base-point tables, built once; JavaScript computes on ./bigCurve and skips the start-up cost. */
function baseTable(cm: Readonly<CurveMath>): Point[16] {
	when (js) {
		return precompute(cm, basePoint(cm), 1);
	} else {
		return precompute(cm, basePoint(cm), 15);
	}
}

const p256Base: Point[16] = baseTable(p256Math);
const p384Base: Point[16] = baseTable(p384Math);

/** pc[slot] read by touching every entry, so the memory access does not depend on the slot. */
function pcSelect(cm: Readonly<CurveMath>, pc: Readonly<Point[16]>, slot: uint32): Point {
	let t = identity(cm);
	for (let i = 1; i < 16; i++) {
		const hit = (((slot ^ (i as uint32)) - 1) >> 31) as uint32;
		t = selectPoint(cm, hit, t, pc[i]);
	}
	return t;
}

/** The fixed 4-bit window over a secret scalar: one constant-time table read and one addition per window, zero windows included. */
function mulTable(cm: Readonly<CurveMath>, pc: Readonly<Point[16]>, k: Readonly<uint8[]>): Point | null {
	let q = identity(cm);
	for (let pos = 8 * k.length - 4; pos >= 0; pos -= 4) {
		const byte = k[k.length - 1 - (pos >> 3)] as uint32;
		q = addPoints(cm, q, pcSelect(cm, pc, (byte >> ((pos & 7) as uint32)) & 15));
		if (pos > 0) q = dbl4(cm, q);
	}
	return isIdentity(cm, q) ? null : q;
}

/** k·p for a secret scalar `k`, in constant time; null when the result is the identity. */
export function mulSecret(cm: Readonly<CurveMath>, p: Point, k: Readonly<uint8[]>): Point | null {
	if (isIdentity(cm, p)) return null;
	return mulTable(cm, precompute(cm, p, 15), k);
}

/** The base-point multiples 0·G to 15·G: a copy of the native table, or computed where JavaScript skipped it. */
function baseMultiples(cm: Readonly<CurveMath>): Point[16] {
	when (js) {
		return precompute(cm, basePoint(cm), 15);
	} else {
		if (cm.field.words == 12) return p384Base;
		return p256Base;
	}
}

/** Entry `slot` (0 to 8) of window `window`, read by touching all eight entries; slot 0 reads as x = 0, the identity. */
@inline
function windowSelect(table: Readonly<uint32[]>, window: int32, slot: uint32, n: int32): Affine {
	let x = zeroLimbs();
	let y = zeroLimbs();
	for (let j = 0; j < 8; j++) {
		const hit = (((slot ^ ((j + 1) as uint32)) - 1) >> 31) as uint32;
		const mask = (0 as uint32) - valueBarrier(hit);
		const at = (16 * window + 2 * j) * n;
		for (let w = 0; w < n; w++) {
			x[w] |= table[at + w] & mask;
			y[w] |= table[at + n + w] & mask;
		}
	}
	return { x, y };
}

/**
 * k·G as the sum over windows of d_i·16^i·G, with the signed digits d_i in [-8, 8) recoded on the way
 * up: one constant-time table read, one conditional negation and one mixed addition per window.
 */
function mulWindows(cm: Readonly<CurveMath>, table: Readonly<uint32[]>, k: Readonly<uint8[]>): Point | null {
	const f = cm.field;
	if (table.length != 16 * (2 * k.length + 1) * f.words) throw new Error("mulWindows: the scalar does not match the table");
	let q = identity(cm);
	let carry: int32 = 0;
	for (let i = 0; i <= 2 * k.length; i++) {
		const byte = i < 2 * k.length ? k[k.length - 1 - (i >> 1)] as int32 : 0;
		let digit = ((byte >> (4 * (i & 1))) & 15) + carry;
		carry = (digit + 8) >> 4;
		digit -= carry * 16;
		const negative = ((digit >> 31) & 1) as uint32;
		const magnitude = ((digit ^ -(negative as int32)) + (negative as int32)) as uint32;
		const entry = f.words == 8 ? windowSelect(table, i, magnitude, 8) : windowSelect(table, i, magnitude, 12);
		const y = select(f, negative, entry.y, opp(f, entry.y));
		q = addMixed(cm, q, { x: entry.x, y });
	}
	return isIdentity(cm, q) ? null : q;
}

/** k·G for a secret scalar `k`, in constant time. */
export function mulBase(cm: Readonly<CurveMath>, k: Readonly<uint8[]>): Point | null {
	when (js) {
		return mulTable(cm, baseMultiples(cm), k);
	} else {
		return mulWindows(cm, cm.field.words == 12 ? p384Windows : p256Windows, k);
	}
}

/** Signed 4-bit digits of a big-endian scalar, least significant first, each in [-8, 8]. */
function slide(k: Readonly<uint8[]>): int32[] {
	const e = new Array<int32>(2 * k.length + 1);
	for (let i = 0; i < k.length; i++) {
		const x = k[k.length - 1 - i] as int32;
		e[2 * i] = x & 15;
		e[2 * i + 1] = x >> 4;
	}
	let carry = 0;
	for (let i = 0; i < 2 * k.length; i++) {
		e[i] += carry;
		carry = (e[i] + 8) >> 4;
		e[i] -= carry * 16;
	}
	e[2 * k.length] = carry;
	return e;
}

function addDigit(cm: Readonly<CurveMath>, q: Point, pc: Readonly<Point[16]>, digit: int32): Point {
	if (digit > 0) return addPoints(cm, q, pc[digit]);
	if (digit < 0) return addPoints(cm, q, neg(cm, pc[-digit]));
	return q;
}

/** a·G + b·q for public scalars, in variable time; null when `q` or the result is the identity. */
export function mulDoubleBasePublic(
	cm: Readonly<CurveMath>,
	a: Readonly<uint8[]>,
	q: Point,
	b: Readonly<uint8[]>,
): Point | null {
	if (isIdentity(cm, q)) return null;
	const pc1 = baseMultiples(cm);
	const pc2 = precompute(cm, q, 8);
	const e1 = slide(a);
	const e2 = slide(b);
	let r = identity(cm);
	for (let pos = e1.length - 1; pos >= 0; pos--) {
		r = addDigit(cm, r, pc1, e1[pos]);
		r = addDigit(cm, r, pc2, e2[pos]);
		if (pos > 0) r = dbl4(cm, r);
	}
	return isIdentity(cm, r) ? null : r;
}

/** The affine coordinates as plain big-endian bytes, x then y; null for the identity. */
export function affineBytes(cm: Readonly<CurveMath>, p: Point): uint8[][] | null {
	if (isIdentity(cm, p)) return null;
	const f = cm.field;
	const zinv = invert(f, p.z);
	return [
		toBytes(f, fromMontgomery(f, mul(f, p.x, zinv))),
		toBytes(f, fromMontgomery(f, mul(f, p.y, zinv))),
	];
}

/** x^3 - 3x + b. */
function curveRight(cm: Readonly<CurveMath>, x: Limbs): Limbs {
	const f = cm.field;
	const x3 = mul(f, square(f, x), x);
	return add(f, sub(f, sub(f, sub(f, x3, x), x), x), cm.b);
}

export function decodePoint(cm: Readonly<CurveMath>, s: Readonly<uint8[]>): Point | null {
	const f = cm.field;
	const size = 4 * f.words;
	if (s.length == 1 + size && (s[0] == 2 || s[0] == 3)) {
		const xs = fromBytes(f, s, 1);
		if (xs == null) return null;
		const x = toMontgomery(f, xs);
		const root = sqrt(cm, curveRight(cm, x));
		if (root == null) return null;
		const flip = (fromMontgomery(f, root)[0] & 1) ^ ((s[0] & 1) as uint32);
		const y = select(f, flip, root, opp(f, root));
		return { x, y, z: f.one };
	}
	if (s.length != 1 + 2 * size || s[0] != 4) return null;
	const xs = fromBytes(f, s, 1);
	const ys = fromBytes(f, s, 1 + size);
	if (xs == null || ys == null) return null;
	const x = toMontgomery(f, xs);
	const y = toMontgomery(f, ys);
	if (!equal(f, square(f, y), curveRight(cm, x))) return null;
	return { x, y, z: f.one };
}

export function encodePoint(cm: Readonly<CurveMath>, p: Point): uint8[] | null {
	const xy = affineBytes(cm, p);
	if (xy == null) return null;
	return [4, ...xy[0], ...xy[1]];
}

/** A square root of `a` (Montgomery form), or null when `a` is not a square. */
export function sqrt(cm: Readonly<CurveMath>, a: Limbs): Limbs | null {
	const f = cm.field;
	const root = pow(f, a, cm.sqrtExp);
	return equal(f, square(f, root), a) ? root : null;
}

export function isSquare(cm: Readonly<CurveMath>, a: Limbs): boolean {
	return equal(cm.field, pow(cm.field, a, cm.squareExp), cm.field.one);
}
