import { encodeHex, decodeHex } from "../../core/encoding";
import { kindSha512 } from "./state";
import { hashOf } from "./hash";
import { P, add, sub, mul, sqr, mod, inv, pow2252m3, bigFromBytes, bigToBytes } from "./field25519";

const curveD = 0x52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3n;
const curveD2 = (2n * curveD) % P;
const sqrtMinusOne = 19681161376707505956807079304988542015446066515923890162744021073123829784752n;
const baseX = 0x216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51an;
const baseY = 0x6666666666666666666666666666666666666666666666666666666666666658n;
export const groupOrder = 0x1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3edn;

/** Extended twisted Edwards coordinates: x = X/Z, y = Y/Z, xy = T/Z. */
class Point {
	x: bigint;
	y: bigint;
	z: bigint;
	t: bigint;
}

function identity(): Point {
	return { x: 0n, y: 1n, z: 1n, t: 0n };
}

function basePoint(): Point {
	return { x: baseX, y: baseY, z: 1n, t: mul(baseX, baseY) };
}

/** add-2008-hwcd-3, complete for this curve, so the identity and doubling need no special case. */
function addPoints(p: Readonly<Point>, q: Readonly<Point>): Point {
	const a = mul(sub(p.y, p.x), sub(q.y, q.x));
	const b = mul(add(p.y, p.x), add(q.y, q.x));
	const c = mul(mul(p.t, curveD2), q.t);
	const d = add(mul(p.z, q.z), mul(p.z, q.z));
	const e = sub(b, a);
	const f = sub(d, c);
	const g = add(d, c);
	const h = add(b, a);
	return { x: mul(e, f), y: mul(g, h), z: mul(f, g), t: mul(e, h) };
}

/** dbl-2008-hwcd with a = -1. */
function doublePoint(p: Readonly<Point>): Point {
	const a = sqr(p.x);
	const b = sqr(p.y);
	const c = mul(2n, sqr(p.z));
	const e = sub(sub(sqr(add(p.x, p.y)), a), b);
	const g = sub(b, a);
	const f = sub(g, c);
	const h = sub(sub(0n, a), b);
	return { x: mul(e, f), y: mul(g, h), z: mul(f, g), t: mul(e, h) };
}

function negatePoint(p: Readonly<Point>): Point {
	return { x: mod(P - p.x), y: p.y, z: p.z, t: mod(P - p.t) };
}

// 64 windows of 4 bits; entry i * 16 + d holds d * 16^i * B, built once at module init.
function buildBaseTable(): Point[] {
	const table: Point[] = [];
	let windowBase = basePoint();
	for (let i = 0; i < 64; i++) {
		let multiple = identity();
		for (let d = 0; d < 16; d++) {
			table.push(multiple);
			multiple = addPoints(multiple, windowBase);
		}
		windowBase = doublePoint(doublePoint(doublePoint(doublePoint(windowBase))));
	}
	return table;
}

const baseTable: Readonly<Point[]> = buildBaseTable();

function nibble(scalar: Readonly<uint8[]>, index: int32): int32 {
	return ((scalar[index >> 1] as int32) >> ((index & 1) * 4)) & 15;
}

/** [scalar]B for a 32-byte little-endian scalar: every window adds one table entry, whatever its value, so no branch reads the scalar. */
function mulBase(scalar: Readonly<uint8[]>): Point {
	let sum = identity();
	for (let i = 0; i < 64; i++) sum = addPoints(sum, baseTable[i * 16 + nibble(scalar, i)]);
	return sum;
}

/** [scalar]P by 4-bit windows with branches on the scalar: only for public scalars (verification). */
function mulPublic(p: Point, scalar: Readonly<uint8[]>): Point {
	const table: Point[] = [identity(), p];
	for (let d = 2; d < 16; d++) table.push(addPoints(table[d - 1], p));
	let sum = identity();
	for (let i = 63; i >= 0; i--) {
		for (let k = 0; k < 4; k++) sum = doublePoint(sum);
		const digit = nibble(scalar, i);
		if (digit != 0) sum = addPoints(sum, table[digit]);
	}
	return sum;
}

function encodePoint(p: Point): uint8[] {
	const zInverse = inv(p.z);
	const x = mul(p.x, zInverse);
	const out = bigToBytes(mul(p.y, zInverse), 32);
	out[31] = ((out[31] as int32) | ((Number(x & 1n) as int32) << 7)) as uint8;
	return out;
}

/** Null when the bytes are not a curve point; a y at or above P is reduced, as the C backend's decoder does. */
function decodePoint(bytes: Readonly<uint8[]>): Point | null {
	const sign = (bytes[31] as int32) >> 7;
	const y = mod(bigFromBytes(bytes, 0, 32) & ((1n << 255n) - 1n));
	const y2 = sqr(y);
	const u = mod(sub(y2, 1n));
	const v = add(mul(curveD, y2), 1n);
	const v3 = mul(sqr(v), v);
	const v7 = mul(sqr(v3), v);
	let x = mul(mul(u, v3), pow2252m3(mul(u, v7)));
	const vx2 = mul(v, sqr(x));
	if (vx2 != u) {
		if (vx2 != mod(P - u)) return null;
		x = mul(x, sqrtMinusOne);
	}
	if (x == 0n && sign == 1) return null;
	if ((Number(x & 1n) as int32) != sign) x = mod(P - x);
	return { x, y, z: 1n, t: mul(x, y) };
}

// The eight small-order points with the sign bit cleared, plus the non-canonical aliases of y = 0 and y = 1:
// a public key or R from this set verifies a forged signature, so both are refused.
const smallOrder: Readonly<string[]> = [
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0100000000000000000000000000000000000000000000000000000000000000",
	"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
	"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
];

function isSmallOrder(encoded: Readonly<uint8[]>, from: int32): boolean {
	const y = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) y[i] = encoded[from + i];
	y[31] = y[31] & 127;
	const text = y.encodeHex();
	for (const known of smallOrder) {
		if (known == text) return true;
	}
	return false;
}

/** The signature shape every backend refuses before any curve work: wrong sizes, small-order key or R, S not below L. */
export function ed25519Acceptable(publicKey: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	if (publicKey.length != 32 || signature.length != 64) return false;
	if (isSmallOrder(publicKey, 0) || isSmallOrder(signature, 0)) return false;
	return bigFromBytes(signature, 32, 32) < groupOrder;
}

function concat3(a: Readonly<uint8[]>, b: Readonly<uint8[]>, c: Readonly<uint8[]>): uint8[] {
	const out = new Array<uint8>(a.length + b.length + c.length);
	for (let i = 0; i < a.length; i++) out[i] = a[i];
	for (let i = 0; i < b.length; i++) out[a.length + i] = b[i];
	for (let i = 0; i < c.length; i++) out[a.length + b.length + i] = c[i];
	return out;
}

function scalarOfHash(digest: Readonly<uint8[]>): bigint {
	return bigFromBytes(digest, 0, 64) % groupOrder;
}

function clampedScalar(digest: Readonly<uint8[]>): uint8[] {
	const a = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) a[i] = digest[i];
	a[0] = a[0] & 248;
	a[31] = (a[31] & 127) | 64;
	return a;
}

export function ed25519PublicFromSeed(seed: Readonly<uint8[]>): uint8[] {
	return encodePoint(mulBase(clampedScalar(hashOf(kindSha512, seed))));
}

/** RFC 8032 5.1.6; `publicKey` is the one derived from `seed`. */
export function ed25519Sign(seed: Readonly<uint8[]>, publicKey: Readonly<uint8[]>, message: Readonly<uint8[]>): uint8[] {
	const expanded = hashOf(kindSha512, seed);
	const a = clampedScalar(expanded);
	const prefix = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) prefix[i] = expanded[32 + i];
	const r = scalarOfHash(hashOf(kindSha512, concat3(prefix, message, [])));
	const rEncoded = encodePoint(mulBase(bigToBytes(r, 32)));
	const k = scalarOfHash(hashOf(kindSha512, concat3(rEncoded, publicKey, message)));
	const s = (r + k * bigFromBytes(a, 0, 32)) % groupOrder;
	const sBytes = bigToBytes(s, 32);
	const out = new Array<uint8>(64);
	for (let i = 0; i < 32; i++) {
		out[i] = rEncoded[i];
		out[32 + i] = sBytes[i];
	}
	return out;
}

/** RFC 8032 5.1.7 on the encoded points: [S]B - [k]A must encode to R, so a non-canonical R never matches. Callers run ed25519Acceptable first. */
export function ed25519Verify(publicKey: Readonly<uint8[]>, signature: Readonly<uint8[]>, message: Readonly<uint8[]>): boolean {
	const a = decodePoint(publicKey);
	if (a == null) return false;
	const rEncoded = new Array<uint8>(32);
	const sBytes = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) {
		rEncoded[i] = signature[i];
		sBytes[i] = signature[32 + i];
	}
	const k = scalarOfHash(hashOf(kindSha512, concat3(rEncoded, publicKey, message)));
	const check = addPoints(mulBase(sBytes), mulPublic(negatePoint(a), bigToBytes(k, 32)));
	const encoded = encodePoint(check);
	for (let i = 0; i < 32; i++) {
		if (encoded[i] != rEncoded[i]) return false;
	}
	return true;
}

test "RFC 8032 test 1: empty message" {
	const seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60".decodeHex();
	const pub = ed25519PublicFromSeed(seed);
	assert pub.encodeHex() == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
	const sig = ed25519Sign(seed, pub, []);
	assert sig.encodeHex() == "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
	assert ed25519Acceptable(pub, sig);
	assert ed25519Verify(pub, sig, []);
	assert !ed25519Verify(pub, sig, [1]);
}

test "RFC 8032 test 2: one byte" {
	const seed = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb".decodeHex();
	const pub = ed25519PublicFromSeed(seed);
	assert pub.encodeHex() == "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c";
	const sig = ed25519Sign(seed, pub, [0x72]);
	assert sig.encodeHex() == "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";
	assert ed25519Verify(pub, sig, [0x72]);
}
