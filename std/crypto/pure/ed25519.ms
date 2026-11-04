/**
 * Ed25519 (RFC 8032), ported from Zig's std.crypto (ed25519.zig, edwards25519.zig, scalar.zig; MIT, see
 * LICENSE.zig.MIT) over the BigInt field of ./field25519. Verification is the cofactorless strict form, the
 * equation the C backend's Monocypher checks, with Zig's refusals of a non-canonical S, A or R and of identity
 * points, plus the C backend's small-order denylist.
 *
 * BigInt arithmetic is not constant time: secret scalars index the window table.
 */
import { encodeHex, decodeHex } from "../../core/encoding";
import { kindSha512 } from "./state";
import { hashOf } from "./hash";
import { P, mul, sqr, mod, inv, pow2252m3, bigFromBytes, bigToBytes } from "./field25519";

const edwardsD = 0x52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3n;
const edwardsD2 = (2n * edwardsD) % P;
const sqrtMinusOne = 19681161376707505956807079304988542015446066515923890162744021073123829784752n;
const baseX = 0x216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51an;
const baseY = 0x6666666666666666666666666666666666666666666666666666666666666658n;
export const groupOrder = 0x1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3edn;

export const ed25519SeedLength = 32;
export const ed25519SecretKeyLength = 64;
export const ed25519PublicKeyLength = 32;
export const ed25519SignatureLength = 64;

function fadd(a: bigint, b: bigint): bigint {
	return (a + b) % P;
}

function fsub(a: bigint, b: bigint): bigint {
	return (a + P - b) % P;
}

function isNegative(a: bigint): boolean {
	return (mod(a) & 1n) == 1n;
}

/** Extended twisted Edwards coordinates: x = X/Z, y = Y/Z, xy = T/Z; every coordinate is kept below P. */
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

function fromBytes(s: Readonly<uint8[]>, from: int32): Point | null {
	const z = 1n;
	const y = mod(bigFromBytes(s, from, 32) & ((1n << 255n) - 1n));
	let u = sqr(y);
	let v = mul(u, edwardsD);
	u = fsub(u, z);
	v = fadd(v, z);
	let x = mul(pow2252m3(mul(u, v)), u);
	const vxx = mul(sqr(x), v);
	const hasMRoot = fsub(vxx, u) == 0n;
	const hasPRoot = fadd(vxx, u) == 0n;
	if (!hasMRoot && !hasPRoot) return null;
	if (!hasMRoot) x = mul(x, sqrtMinusOne);
	const sign = (s[from + 31] as int32) >> 7;
	if (x == 0n && sign != 0) return null;
	if ((isNegative(x) ? 1 : 0) != sign) x = fsub(0n, x);
	return { x, y, z, t: mul(x, y) };
}

function toBytes(p: Readonly<Point>): uint8[] {
	const zi = inv(p.z);
	const s = bigToBytes(mul(p.y, zi), 32);
	if (isNegative(mul(p.x, zi))) s[31] = s[31] ^ 0x80;
	return s;
}

/** A y at or above P, ignoring the sign bit. */
function isCanonicalEncoding(s: Readonly<uint8[]>, from: int32): boolean {
	return (bigFromBytes(s, from, 32) & ((1n << 255n) - 1n)) < P;
}

function isIdentityX(p: Readonly<Point>): boolean {
	return p.x == 0n;
}

function neg(p: Readonly<Point>): Point {
	return { x: fsub(0n, p.x), y: p.y, z: p.z, t: fsub(0n, p.t) };
}

function dbl(p: Readonly<Point>): Point {
	const t0 = sqr(fadd(p.x, p.y));
	let x = sqr(p.x);
	let z = sqr(p.y);
	const y = fadd(z, x);
	z = fsub(z, x);
	x = fsub(t0, y);
	const t = fsub(fadd(sqr(p.z), sqr(p.z)), z);
	return { x: mul(x, t), y: mul(y, z), z: mul(z, t), t: mul(x, y) };
}

function addPoints(p: Readonly<Point>, q: Readonly<Point>): Point {
	const a = mul(fsub(p.y, p.x), fsub(q.y, q.x));
	const b = mul(fadd(p.x, p.y), fadd(q.x, q.y));
	const c = mul(mul(p.t, q.t), edwardsD2);
	let d = mul(p.z, q.z);
	d = fadd(d, d);
	const x = fsub(b, a);
	const y = fadd(b, a);
	const z = fadd(d, c);
	const t = fsub(d, c);
	return { x: mul(x, t), y: mul(y, z), z: mul(z, t), t: mul(x, y) };
}

function subPoints(p: Readonly<Point>, q: Readonly<Point>): Point {
	return addPoints(p, neg(q));
}

function precompute(p: Point, count: int32): Point[] {
	const pc: Point[] = [identity(), p];
	for (let i = 2; i <= count; i++) pc.push(i % 2 == 0 ? dbl(pc[i / 2]) : addPoints(pc[i - 1], p));
	return pc;
}

const basePointPc: Readonly<Point[]> = precompute(basePoint(), 15);

/** Little-endian 32-byte scalar reduced mod L. */
function reduce32(s: Readonly<uint8[]>): uint8[] {
	return bigToBytes(bigFromBytes(s, 0, 32) % groupOrder, 32);
}

function reduce64(s: Readonly<uint8[]>): uint8[] {
	return bigToBytes(bigFromBytes(s, 0, 64) % groupOrder, 32);
}

/** a * b + c mod L. */
function scalarMulAdd(a: Readonly<uint8[]>, b: Readonly<uint8[]>, c: Readonly<uint8[]>): uint8[] {
	return bigToBytes((bigFromBytes(a, 0, 32) * bigFromBytes(b, 0, 32) + bigFromBytes(c, 0, 32)) % groupOrder, 32);
}

function isCanonicalScalar(s: Readonly<uint8[]>, from: int32): boolean {
	return bigFromBytes(s, from, 32) < groupOrder;
}

function clamp(s: uint8[]): void {
	s[0] = s[0] & 248;
	s[31] = (s[31] & 127) | 64;
}

function slide(s: Readonly<uint8[]>): int32[] {
	const reduced = ((s[31] as int32) & 0x80) == 0 ? s : reduce32(s);
	const e: int32[] = [];
	for (let i = 0; i < 32; i++) {
		e.push((reduced[i] as int32) & 15);
		e.push(((reduced[i] as int32) >> 4) & 15);
	}
	let carry = 0;
	for (let i = 0; i < 63; i++) {
		e[i] += carry;
		carry = (e[i] + 8) >> 4;
		e[i] -= carry * 16;
	}
	e[63] += carry;
	return e;
}

/** [s]P with the 15-multiple table; null when the result is the identity. */
function pcMul16(pc: Readonly<Point[]>, s: Readonly<uint8[]>): Point | null {
	let q = identity();
	let pos = 252;
	while (true) {
		const slot = ((s[pos >> 3] as int32) >> (pos & 7)) & 15;
		q = addPoints(q, pc[slot]);
		if (pos == 0) break;
		q = dbl(dbl(dbl(dbl(q))));
		pos -= 4;
	}
	if (isIdentityX(q)) return null;
	return q;
}

function mulBase(s: Readonly<uint8[]>): Point | null {
	return pcMul16(basePointPc, s);
}

/** [s1]B + [s2]p2 in variable time; null when p2 generates a small-order group. */
function mulDoubleBasePublic(s1: Readonly<uint8[]>, p2: Point, s2: Readonly<uint8[]>): Point | null {
	const pc2 = precompute(p2, 8);
	if (isIdentityX(pc2[4])) return null;
	const e1 = slide(s1);
	const e2 = slide(s2);
	let q = identity();
	let pos = 63;
	while (true) {
		const slot1 = e1[pos];
		if (slot1 > 0) q = addPoints(q, basePointPc[slot1]);
		else if (slot1 < 0) q = subPoints(q, basePointPc[-slot1]);
		const slot2 = e2[pos];
		if (slot2 > 0) q = addPoints(q, pc2[slot2]);
		else if (slot2 < 0) q = subPoints(q, pc2[-slot2]);
		if (pos == 0) break;
		q = dbl(dbl(dbl(dbl(q))));
		pos -= 1;
	}
	return q;
}

function sha512Of(parts: Readonly<uint8[]>[]): uint8[] {
	let total = 0;
	for (const part of parts) total += part.length;
	const joined = new Array<uint8>(total);
	let at = 0;
	for (const part of parts) {
		for (let i = 0; i < part.length; i++) joined[at + i] = part[i];
		at += part.length;
	}
	return hashOf(kindSha512, joined);
}

function bytesAt(source: Readonly<uint8[]>, from: int32, length: int32): uint8[] {
	const out = new Array<uint8>(length);
	for (let i = 0; i < length; i++) out[i] = source[from + i];
	return out;
}

/** The public key of a 32-byte seed; empty for any other length. */
export function ed25519PublicFromSeed(seed: Readonly<uint8[]>): uint8[] {
	if (seed.length != ed25519SeedLength) return [];
	const az = hashOf(kindSha512, seed);
	const s = bytesAt(az, 0, 32);
	clamp(s);
	const pk = mulBase(s);
	if (pk == null) return [];
	return toBytes(pk);
}

/** The 64-byte secret key (seed then public key) the C backend keeps; empty for a seed not 32 bytes long. */
export function ed25519SecretKeyFromSeed(seed: Readonly<uint8[]>): uint8[] {
	const pk = ed25519PublicFromSeed(seed);
	if (pk.length == 0) return [];
	const out = new Array<uint8>(64);
	for (let i = 0; i < 32; i++) {
		out[i] = seed[i];
		out[32 + i] = pk[i];
	}
	return out;
}

/** RFC 8032 5.1.6; `publicKey` is the one derived from `seed`. Empty on a bad length. */
export function ed25519Sign(seed: Readonly<uint8[]>, publicKey: Readonly<uint8[]>, message: Readonly<uint8[]>): uint8[] {
	if (seed.length != ed25519SeedLength || publicKey.length != ed25519PublicKeyLength) return [];
	const az = hashOf(kindSha512, seed);
	const scalar = bytesAt(az, 0, 32);
	clamp(scalar);
	const nonce = reduce64(sha512Of([bytesAt(az, 32, 32), message]));
	const r = mulBase(nonce);
	if (r == null) return [];
	const rBytes = toBytes(r);
	const hram = reduce64(sha512Of([rBytes, publicKey, message]));
	const s = scalarMulAdd(hram, scalar, nonce);
	const out = new Array<uint8>(64);
	for (let i = 0; i < 32; i++) {
		out[i] = rBytes[i];
		out[32 + i] = s[i];
	}
	return out;
}

/** Signs with the 64-byte secret key of ed25519SecretKeyFromSeed; empty on a bad length. */
export function ed25519SignWithSecretKey(secretKey: Readonly<uint8[]>, message: Readonly<uint8[]>): uint8[] {
	if (secretKey.length != ed25519SecretKeyLength) return [];
	return ed25519Sign(bytesAt(secretKey, 0, 32), bytesAt(secretKey, 32, 32), message);
}

// The eight small-order points with the sign bit cleared, plus the non-canonical aliases of y = 0 and y = 1,
// as the C backend refuses them.
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
	const y = bytesAt(encoded, from, 32);
	y[31] = y[31] & 127;
	const text = y.encodeHex();
	for (const known of smallOrder) {
		if (known == text) return true;
	}
	return false;
}

/** The shape every backend refuses before any curve work: wrong sizes, small-order key or R, S not below L. */
export function ed25519Acceptable(publicKey: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	if (publicKey.length != ed25519PublicKeyLength || signature.length != ed25519SignatureLength) return false;
	if (isSmallOrder(publicKey, 0) || isSmallOrder(signature, 0)) return false;
	return isCanonicalScalar(signature, 32);
}

/** RFC 8032 5.1.7, cofactorless: [S]B - [k]A must equal R. False on any bad length, encoding or signature. */
export function ed25519Verify(publicKey: Readonly<uint8[]>, signature: Readonly<uint8[]>, message: Readonly<uint8[]>): boolean {
	if (!ed25519Acceptable(publicKey, signature)) return false;
	if (!isCanonicalEncoding(publicKey, 0)) return false;
	const a = fromBytes(publicKey, 0);
	if (a == null || isIdentityX(a)) return false;
	if (!isCanonicalEncoding(signature, 0)) return false;
	const expectedR = fromBytes(signature, 0);
	if (expectedR == null || isIdentityX(expectedR)) return false;
	const rBytes = bytesAt(signature, 0, 32);
	const hram = reduce64(sha512Of([rBytes, publicKey, message]));
	const sbAh = mulDoubleBasePublic(bytesAt(signature, 32, 32), neg(a), hram);
	if (sbAh == null) return false;
	const check = subPoints(sbAh, expectedR);
	return check.x == 0n && check.y == check.z;
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
