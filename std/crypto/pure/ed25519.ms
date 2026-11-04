/**
 * Ed25519 (RFC 8032), ported from Zig's std.crypto (ed25519.zig, edwards25519.zig, scalar.zig; MIT, see
 * LICENSE.zig.MIT) over the field of ./ed25519Field and the scalars of ./scalar25519. Verification
 * is the cofactorless strict form, the equation the C backend's Monocypher checks, with Zig's refusals of a
 * non-canonical S, A or R and of identity points, plus the C backend's small-order denylist.
 *
 * Signing multiplies the base point with ref10's per-row table (./ed25519BaseTable) and picks entries with masks
 * in the manner of Zig's pcSelect, never by a secret index; the JS backend still promises no constant time,
 * because its field is BigInt.
 */
import { encodeHex, decodeHex } from "../../core/encoding";
import { kindSha512 } from "./state";
import { hashOf, newHash, updateHash, finishHash } from "./hash";
import { wipeBytes } from "./secret";
import { baseTableHex } from "./ed25519BaseTable";
import {
	Fe,
	feZero,
	feOne,
	feFromBytes,
	feToBytes,
	feAdd,
	feSub,
	feAddLoose,
	feSubLoose,
	feNeg,
	feMul,
	feSqr,
	feInv,
	fePow2252m3,
	feIsZero,
	feEqual,
	feIsNegative,
	feCMov,
} from "./ed25519Field";
import { scalarReduce32, scalarReduce64, scalarMulAdd, scalarIsCanonical } from "./scalar25519";

function feHex(hex: string): Fe {
	return feFromBytes(hex.decodeHex(), 0);
}

const edwardsD = feHex("a3785913ca4deb75abd841414d0a700098e879777940c78c73fe6f2bee6c0352");
const edwardsD2 = feHex("59f1b226949bd6eb56b183829a14e00030d1f3eef2808e19e7fcdf56dcd90624");
const sqrtMinusOne = feHex("b0a00e4a271beec478e42fad0618432fa7d7fb3d99004d2b0bdfc14f8024832b");
const baseX = feHex("1ad5258f602d56c9b2a7259560c72c695cdcd6fd31e2a4c0fe536ecdd3366921");
const baseY = feHex("5866666666666666666666666666666666666666666666666666666666666666");

export const ed25519SeedLength = 32;
export const ed25519SecretKeyLength = 64;
export const ed25519PublicKeyLength = 32;
export const ed25519SignatureLength = 64;

/** Extended twisted Edwards coordinates: x = X/Z, y = Y/Z, xy = T/Z. */
struct Point {
	x: Fe;
	y: Fe;
	z: Fe;
	t: Fe;
}

function identity(): Point {
	return { x: feZero, y: feOne, z: feOne, t: feZero };
}

function basePoint(): Point {
	return { x: baseX, y: baseY, z: feOne, t: feMul(baseX, baseY) };
}

function fromBytes(s: Readonly<uint8[]>, from: int32): Point | null {
	const z = feOne;
	const y = feFromBytes(s, from);
	let u = feSqr(y);
	let v = feMul(u, edwardsD);
	u = feSub(u, z);
	v = feAdd(v, z);
	let x = feMul(fePow2252m3(feMul(u, v)), u);
	const vxx = feMul(feSqr(x), v);
	const hasMRoot = feIsZero(feSub(vxx, u));
	const hasPRoot = feIsZero(feAdd(vxx, u));
	if (!hasMRoot && !hasPRoot) return null;
	if (!hasMRoot) x = feMul(x, sqrtMinusOne);
	const sign = (s[from + 31] as int32) >> 7;
	if (feIsZero(x) && sign != 0) return null;
	if ((feIsNegative(x) ? 1 : 0) != sign) x = feNeg(x);
	return { x, y, z, t: feMul(x, y) };
}

function toBytes(p: Readonly<Point>): uint8[] {
	const zi = feInv(p.z);
	const s = feToBytes(feMul(p.y, zi));
	if (feIsNegative(feMul(p.x, zi))) s[31] = s[31] ^ 0x80;
	return s;
}

/** Whether y, the sign bit ignored, is below P: Zig's Fe.rejectNonCanonical with the extra bit ignored. */
function isCanonicalEncoding(s: Readonly<uint8[]>, from: int32): boolean {
	let c = ((s[from + 31] as int32) & 0x7f) ^ 0x7f;
	for (let i = 30; i > 0; i--) c = c | ((s[from + i] as int32) ^ 0xff);
	c = ((c - 1) >> 8) & 1;
	const d = ((0xed - 1 - (s[from] as int32)) >> 8) & 1;
	return (c & d) == 0;
}

function isIdentityX(p: Readonly<Point>): boolean {
	return feIsZero(p.x);
}

function neg(p: Readonly<Point>): Point {
	return { x: feNeg(p.x), y: p.y, z: p.z, t: feNeg(p.t) };
}

function dbl(p: Readonly<Point>): Point {
	const t0 = feSqr(feAddLoose(p.x, p.y));
	let x = feSqr(p.x);
	let z = feSqr(p.y);
	const y = feAdd(z, x);
	z = feSub(z, x);
	x = feSubLoose(t0, y);
	const t = feSubLoose(feAdd(feSqr(p.z), feSqr(p.z)), z);
	return { x: feMul(x, t), y: feMul(y, z), z: feMul(z, t), t: feMul(x, y) };
}

function addPoints(p: Readonly<Point>, q: Readonly<Point>): Point {
	const a = feMul(feSubLoose(p.y, p.x), feSubLoose(q.y, q.x));
	const b = feMul(feAddLoose(p.x, p.y), feAddLoose(q.x, q.y));
	const c = feMul(feMul(p.t, q.t), edwardsD2);
	let d = feMul(p.z, q.z);
	d = feAdd(d, d);
	const x = feSubLoose(b, a);
	const y = feAddLoose(b, a);
	const z = feAddLoose(d, c);
	const t = feSubLoose(d, c);
	return { x: feMul(x, t), y: feMul(y, z), z: feMul(z, t), t: feMul(x, y) };
}

function subPoints(p: Readonly<Point>, q: Readonly<Point>): Point {
	return addPoints(p, neg(q));
}

function precompute(p: Point, count: int32): Point[] {
	const pc: Point[] = [identity(), p];
	for (let i = 2; i <= count; i++) pc.push(i % 2 == 0 ? dbl(pc[i / 2]) : addPoints(pc[i - 1], p));
	return pc;
}

const basePointPc: Readonly<Point[]> = precompute(basePoint(), 8);

/** An affine table point in ref10's niels form: y + x, y - x and 2dxy. */
struct Niels {
	yPlusX: Fe;
	yMinusX: Fe;
	xy2d: Fe;
}

function nielsOf(hex: string): Niels {
	const bytes = hex.decodeHex();
	return { yPlusX: feFromBytes(bytes, 0), yMinusX: feFromBytes(bytes, 32), xy2d: feFromBytes(bytes, 64) };
}

function loadBaseTable(): Niels[] {
	const table: Niels[] = [];
	for (const hex of baseTableHex) table.push(nielsOf(hex));
	return table;
}

const baseTable: Readonly<Niels[]> = loadBaseTable();

/** p + q for an affine q: addPoints without the products Z1 * Z2 and T2 * 2d. */
function addNiels(p: Readonly<Point>, q: Readonly<Niels>): Point {
	const a = feMul(feSubLoose(p.y, p.x), q.yMinusX);
	const b = feMul(feAddLoose(p.x, p.y), q.yPlusX);
	const c = feMul(p.t, q.xy2d);
	const d = feAdd(p.z, p.z);
	const x = feSubLoose(b, a);
	const y = feAddLoose(b, a);
	const z = feAddLoose(d, c);
	const t = feSubLoose(d, c);
	return { x: feMul(x, t), y: feMul(y, z), z: feMul(z, t), t: feMul(x, y) };
}

function cMovNiels(p: Readonly<Niels>, q: Readonly<Niels>, bit: uint32): Niels {
	return {
		yPlusX: feCMov(p.yPlusX, q.yPlusX, bit),
		yMinusX: feCMov(p.yMinusX, q.yMinusX, bit),
		xy2d: feCMov(p.xy2d, q.xy2d, bit),
	};
}

/** [digit * 256^row]B for a digit in -8..8, read by touching all eight entries of the row and without a branch. */
function selectBase(row: int32, digit: int32): Niels {
	const negative = (digit >> 31) & 1;
	const magnitude = digit - (((0 - negative) & digit) << 1);
	let t: Niels = { yPlusX: feOne, yMinusX: feOne, xy2d: feZero };
	for (let j = 1; j <= 8; j++) {
		t = cMovNiels(t, baseTable[row * 8 + j - 1], ((((magnitude ^ j) - 1) >> 31) & 1) as uint32);
	}
	const minus: Niels = { yPlusX: t.yMinusX, yMinusX: t.yPlusX, xy2d: feNeg(t.xy2d) };
	return cMovNiels(t, minus, negative as uint32);
}

function clamp(s: uint8[]): void {
	s[0] = s[0] & 248;
	s[31] = (s[31] & 127) | 64;
}

function slide(s: Readonly<uint8[]>): int32[] {
	const reduced = ((s[31] as int32) & 0x80) == 0 ? s : scalarReduce32(s);
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

/** [s]B in constant time from radix-16 signed digits, ref10's ge_scalarmult_base; null for the identity. */
function mulBase(s: Readonly<uint8[]>): Point | null {
	const e = slide(s);
	let q = identity();
	for (let i = 1; i < 64; i += 2) q = addNiels(q, selectBase(i >> 1, e[i]));
	q = dbl(dbl(dbl(dbl(q))));
	for (let i = 0; i < 64; i += 2) q = addNiels(q, selectBase(i >> 1, e[i]));
	if (isIdentityX(q)) return null;
	return q;
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
	const h = newHash(kindSha512);
	for (const part of parts) updateHash(h, part);
	return finishHash(h);
}

/** The public key of a 32-byte seed; empty for any other length. */
export function ed25519PublicFromSeed(seed: Readonly<uint8[]>): uint8[] {
	if (seed.length != ed25519SeedLength) return [];
	const az = hashOf(kindSha512, seed);
	const s = az.slice(0, 32);
	clamp(s);
	const pk = mulBase(s);
	wipeBytes(az);
	wipeBytes(s);
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
	const scalar = az.slice(0, 32);
	clamp(scalar);
	const prefix = az.slice(32, 64);
	wipeBytes(az);
	const nonce = scalarReduce64(sha512Of([prefix, message]));
	wipeBytes(prefix);
	const r = mulBase(nonce);
	const rBytes = r == null ? [] : toBytes(r);
	const hram = scalarReduce64(sha512Of([rBytes, publicKey, message]));
	const s = scalarMulAdd(hram, scalar, nonce);
	wipeBytes(scalar);
	wipeBytes(nonce);
	if (r == null) return [];
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
	return ed25519Sign(secretKey.slice(0, 32), secretKey.slice(32, 64), message);
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
	const y = encoded.slice(from, from + 32);
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
	return scalarIsCanonical(signature, 32);
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
	const rBytes = signature.slice(0, 32);
	const hram = scalarReduce64(sha512Of([rBytes, publicKey, message]));
	const sbAh = mulDoubleBasePublic(signature.slice(32, 64), neg(a), hram);
	if (sbAh == null) return false;
	const check = subPoints(sbAh, expectedR);
	return feIsZero(check.x) && feEqual(check.y, check.z);
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
