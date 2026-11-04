/**
 * P-256 and P-384 on `bigint`, the JavaScript backend's arithmetic for ./weierstrass: there `bigint`
 * is the platform's own, and runs about 40 times faster than the fixed-width limbs of ./pcurve,
 * whose 64-bit words become `BigInt` operations. Not constant-time. The curve constants are built
 * per call, so the native backend, which never calls this module, compiles none of it.
 */

import { derJoin } from "./asn1";
import { bigFromBytes, bigToBytes, bitLength, modInverse } from "./bigint";
import { hashOf } from "./hash";
import { hmacOf } from "./hmac";

interface BigCurve {
	size: int32;
	p: bigint;
	a: bigint;
	b: bigint;
	n: bigint;
	gx: bigint;
	gy: bigint;
}

/** SEC 2 v2 sections 2.4.2 (P-256) and 2.5.1 (P-384). */
function bigCurve(size: int32): BigCurve {
	if (size == 48) {
		return {
			size,
			p: 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffffn,
			a: 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000fffffffcn,
			b: 0xb3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aefn,
			n: 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973n,
			gx: 0xaa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7n,
			gy: 0x3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5fn,
		};
	}
	return {
		size,
		p: 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn,
		a: 0xffffffff00000001000000000000000000000000fffffffffffffffffffffffcn,
		b: 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604bn,
		n: 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n,
		gx: 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n,
		gy: 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n,
	};
}

interface Jacobian {
	x: bigint;
	y: bigint;
	z: bigint;
}

function fmod(value: bigint, p: bigint): bigint {
	const r = value % p;
	return r < 0n ? r + p : r;
}

function infinity(): Jacobian {
	return { x: 1n, y: 1n, z: 0n };
}

function jacobianOf(x: bigint, y: bigint): Jacobian {
	return { x, y, z: 1n };
}

function double(c: BigCurve, a: Jacobian): Jacobian {
	const p = c.p;
	if (a.z == 0n || a.y == 0n) return infinity();
	const xx = (a.x * a.x) % p;
	const yy = (a.y * a.y) % p;
	const yyyy = (yy * yy) % p;
	const zz = (a.z * a.z) % p;
	const s = (4n * a.x * yy) % p;
	const m = (3n * xx + c.a * ((zz * zz) % p)) % p;
	const x = fmod(m * m - 2n * s, p);
	const y = fmod(m * (s - x) - 8n * yyyy, p);
	const z = (2n * a.y * a.z) % p;
	return { x, y, z };
}

function add(c: BigCurve, a: Jacobian, b: Jacobian): Jacobian {
	const p = c.p;
	if (a.z == 0n) return b;
	if (b.z == 0n) return a;
	const z1z1 = (a.z * a.z) % p;
	const z2z2 = (b.z * b.z) % p;
	const u1 = (a.x * z2z2) % p;
	const u2 = (b.x * z1z1) % p;
	const s1 = (a.y * b.z * z2z2) % p;
	const s2 = (b.y * a.z * z1z1) % p;
	const h = fmod(u2 - u1, p);
	const r = fmod(s2 - s1, p);
	if (h == 0n) return r == 0n ? double(c, a) : infinity();
	const hh = (h * h) % p;
	const hhh = (h * hh) % p;
	const v = (u1 * hh) % p;
	const x = fmod(r * r - hhh - 2n * v, p);
	const y = fmod(r * (v - x) - s1 * hhh, p);
	const z = (((h * a.z) % p) * b.z) % p;
	return { x, y, z };
}

function windowOf(c: BigCurve, a: Jacobian): Jacobian[] {
	const table: Jacobian[] = [infinity(), a];
	for (let i = 2; i < 16; i++) table.push(i % 2 == 0 ? double(c, table[i / 2]) : add(c, table[i - 1], a));
	return table;
}

function multiplyWith(c: BigCurve, table: Jacobian[], scalar: bigint): Jacobian {
	let result = infinity();
	let at: int32 = ((bitLength(scalar) + 3) >> 2) << 2;
	while (at > 0) {
		at -= 4;
		for (let i = 0; i < 4; i++) result = double(c, result);
		const nibble = Number((scalar >> BigInt(at)) & 15n);
		if (nibble != 0) result = add(c, result, table[nibble]);
	}
	return result;
}

function generatorWindow(c: BigCurve): Jacobian[] {
	return windowOf(c, jacobianOf(c.gx, c.gy));
}

interface Affine {
	x: bigint;
	y: bigint;
}

function affineOf(c: BigCurve, a: Jacobian): Affine | null {
	if (a.z == 0n) return null;
	const zi = modInverse(a.z, c.p);
	const zi2 = (zi * zi) % c.p;
	return { x: (a.x * zi2) % c.p, y: (a.y * zi2 * zi) % c.p };
}

function decodePoint(c: BigCurve, point: Readonly<uint8[]>): Affine | null {
	if (point.length != 1 + 2 * c.size || point[0] != 4) return null;
	const x = bigFromBytes(point.slice(1, 1 + c.size));
	const y = bigFromBytes(point.slice(1 + c.size));
	if (x >= c.p || y >= c.p) return null;
	if ((y * y) % c.p != fmod(x * x * x + c.a * x + c.b, c.p)) return null;
	return { x, y };
}

function encodePoint(c: BigCurve, a: Affine): uint8[] {
	return derJoin([[4], bigToBytes(a.x, c.size), bigToBytes(a.y, c.size)]);
}

export function bigPointValid(size: int32, point: Readonly<uint8[]>): boolean {
	const c = bigCurve(size);
	return decodePoint(c, point) != null;
}

export function bigPublicPoint(size: int32, d: Readonly<uint8[]>): uint8[] | null {
	const c = bigCurve(size);
	const scalar = bigFromBytes(d);
	if (scalar < 1n || scalar >= c.n) return null;
	const point = affineOf(c, multiplyWith(c, generatorWindow(c), scalar));
	if (point == null) return null;
	return encodePoint(c, point);
}

export function bigEcdhShared(size: int32, d: Readonly<uint8[]>, point: Readonly<uint8[]>): uint8[] | null {
	const c = bigCurve(size);
	const scalar = bigFromBytes(d);
	const peer = decodePoint(c, point);
	if (peer == null || scalar < 1n || scalar >= c.n) return null;
	const shared = affineOf(c, multiplyWith(c, windowOf(c, jacobianOf(peer.x, peer.y)), scalar));
	if (shared == null) return null;
	return bigToBytes(shared.x, c.size);
}

function digestInt(c: BigCurve, digest: Readonly<uint8[]>): bigint {
	const value = bigFromBytes(digest);
	const extra = digest.length * 8 - bitLength(c.n);
	return extra > 0 ? value >> BigInt(extra) : value;
}

function nonceFor(c: BigCurve, kind: int32, d: Readonly<uint8[]>, digest: Readonly<uint8[]>): bigint {
	const size = hashOf(kind, []).length as int32;
	const reduced = bigToBytes(digestInt(c, digest) % c.n, c.size);
	const seed = derJoin([d, reduced]);
	let v = new Array<uint8>(size);
	v.fill(1);
	let k = new Array<uint8>(size);
	k = hmacOf(kind, k, derJoin([v, [0], seed]));
	v = hmacOf(kind, k, v);
	k = hmacOf(kind, k, derJoin([v, [1], seed]));
	v = hmacOf(kind, k, v);
	while (true) {
		let stream: uint8[] = [];
		while (stream.length < c.size) {
			v = hmacOf(kind, k, v);
			stream = derJoin([stream, v]);
		}
		const candidate = digestInt(c, stream);
		if (candidate >= 1n && candidate < c.n) return candidate;
		k = hmacOf(kind, k, derJoin([v, [0]]));
		v = hmacOf(kind, k, v);
	}
}

export function bigSignRaw(size: int32, kind: int32, d: Readonly<uint8[]>, digest: Readonly<uint8[]>): uint8[] | null {
	const c = bigCurve(size);
	const scalar = bigFromBytes(d);
	if (scalar < 1n || scalar >= c.n) return null;
	const e = digestInt(c, digest);
	const k = nonceFor(c, kind, d, digest);
	const point = affineOf(c, multiplyWith(c, generatorWindow(c), k));
	if (point == null) return null;
	const r = point.x % c.n;
	const s = (modInverse(k, c.n) * ((e + r * scalar) % c.n)) % c.n;
	if (r == 0n || s == 0n) return null;
	return derJoin([bigToBytes(r, c.size), bigToBytes(s, c.size)]);
}

export function bigVerifyRaw(size: int32, point: Readonly<uint8[]>, digest: Readonly<uint8[]>, raw: Readonly<uint8[]>): boolean {
	const c = bigCurve(size);
	const q = decodePoint(c, point);
	if (q == null || raw.length != 2 * c.size) return false;
	const r = bigFromBytes(raw.slice(0, c.size));
	const s = bigFromBytes(raw.slice(c.size));
	if (r < 1n || r >= c.n || s < 1n || s >= c.n) return false;
	const w = modInverse(s, c.n);
	const u1 = (digestInt(c, digest) * w) % c.n;
	const u2 = (r * w) % c.n;
	const sum = add(c, multiplyWith(c, generatorWindow(c), u1), multiplyWith(c, windowOf(c, jacobianOf(q.x, q.y)), u2));
	const found = affineOf(c, sum);
	return found != null && found.x % c.n == r;
}
