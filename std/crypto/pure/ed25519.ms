/**
 * Ed25519 (RFC 8032), ported from Zig's std.crypto (ed25519.zig,
 * edwards25519.zig, scalar.zig; MIT, see LICENSE.zig.MIT) over the field of
 * ./ed25519Field and the scalars of ./scalar25519. Verification is the
 * cofactorless strict form, the equation the C backend's Monocypher checks,
 * with Zig's refusals of a non-canonical S, A or R and of identity points, plus
 * the C backend's small-order denylist.
 *
 * Signing multiplies the base point with ref10's per-row table
 * (./ed25519BaseTable) and picks entries with masks in the manner of Zig's
 * pcSelect, never by a secret index; the JS backend still promises no constant
 * time, because its field is BigInt.
 */
import { encodeHex, decodeHex } from "../../core/encoding";
import { kindSha512 } from "./state";
import { hashOf, newHash, updateHash, finishHash } from "./hash";
import { wipeBytes } from "./secret";
import { baseTableFe, baseOddTableFe } from "./ed25519BaseTable";
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
	Niels,
	feSelectNiels,
} from "./ed25519Field";
import {
	scalarReduce32,
	scalarReduce64,
	scalarMulAdd,
	scalarIsCanonical,
} from "./scalar25519";

function feHex(hex: string): Fe {
	return feFromBytes(hex.decodeHex(), 0);
}

const edwardsD = feHex(
	"a3785913ca4deb75abd841414d0a700098e879777940c78c73fe6f2bee6c0352",
);
const edwardsD2 = feHex(
	"59f1b226949bd6eb56b183829a14e00030d1f3eef2808e19e7fcdf56dcd90624",
);
const sqrtMinusOne = feHex(
	"b0a00e4a271beec478e42fad0618432fa7d7fb3d99004d2b0bdfc14f8024832b",
);

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

/**
 * Whether y, the sign bit ignored, is below P: Zig's Fe.rejectNonCanonical with
 * the extra bit ignored.
 */
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

/** (X : Y : Z) without T, all a doubling reads. */
struct Projective {
	x: Fe;
	y: Fe;
	z: Fe;
}

/**
 * ref10's completed point, x = X/Z and y = Y/T: what a doubling or an addition
 * yields before its last products. Its fields may be loose, so only feMul reads
 * them.
 */
struct Completed {
	x: Fe;
	y: Fe;
	z: Fe;
	t: Fe;
}

/** ref10's cached form of a point: Y + X, Y - X, Z and 2dT. */
struct Cached {
	yPlusX: Fe;
	yMinusX: Fe;
	z: Fe;
	t2d: Fe;
}

function toProjective(c: Readonly<Completed>): Projective {
	return { x: feMul(c.x, c.t), y: feMul(c.y, c.z), z: feMul(c.z, c.t) };
}

function toExtended(c: Readonly<Completed>): Point {
	return {
		x: feMul(c.x, c.t),
		y: feMul(c.y, c.z),
		z: feMul(c.z, c.t),
		t: feMul(c.x, c.y),
	};
}

function toCached(p: Readonly<Point>): Cached {
	return {
		yPlusX: feAdd(p.y, p.x),
		yMinusX: feSub(p.y, p.x),
		z: p.z,
		t2d: feMul(p.t, edwardsD2),
	};
}

/** 2p, ref10's ge_p2_dbl. */
function doubled(p: Readonly<Projective>): Completed {
	const xx = feSqr(p.x);
	const yy = feSqr(p.y);
	const zz = feSqr(p.z);
	const sum = feAdd(yy, xx);
	const difference = feSub(yy, xx);
	return {
		x: feSubLoose(feSqr(feAddLoose(p.x, p.y)), sum),
		y: sum,
		z: difference,
		t: feSubLoose(feAdd(zz, zz), difference),
	};
}

function dbl(p: Readonly<Point>): Point {
	return toExtended(doubled({ x: p.x, y: p.y, z: p.z }));
}

/** 16p, Zig's shift(p, 4). */
function shift4(p: Readonly<Point>): Point {
	let q = toProjective(doubled({ x: p.x, y: p.y, z: p.z }));
	q = toProjective(doubled(q));
	q = toProjective(doubled(q));
	return toExtended(doubled(q));
}

/** p + q, ref10's ge_add. */
function addCached(p: Readonly<Point>, q: Readonly<Cached>): Completed {
	const a = feMul(feSubLoose(p.y, p.x), q.yMinusX);
	const b = feMul(feAddLoose(p.y, p.x), q.yPlusX);
	const c = feMul(p.t, q.t2d);
	const z = feMul(p.z, q.z);
	const d = feAdd(z, z);
	return {
		x: feSubLoose(b, a),
		y: feAddLoose(b, a),
		z: feAddLoose(d, c),
		t: feSubLoose(d, c),
	};
}

function negCached(q: Readonly<Cached>): Cached {
	return { yPlusX: q.yMinusX, yMinusX: q.yPlusX, z: q.z, t2d: feNeg(q.t2d) };
}

function addPoints(p: Readonly<Point>, q: Readonly<Point>): Point {
	return toExtended(addCached(p, toCached(q)));
}

function subPoints(p: Readonly<Point>, q: Readonly<Point>): Point {
	return addPoints(p, neg(q));
}

/** Entry 8i + j - 1 of baseTableFe, [j * 256^i]B. */
function baseNiels(entry: int32): Niels {
	return {
		yPlusX: baseTableFe[3 * entry],
		yMinusX: baseTableFe[3 * entry + 1],
		xy2d: baseTableFe[3 * entry + 2],
	};
}

/** Entry k of baseOddTableFe, [2k + 1]B. */
function baseOddNiels(entry: int32): Niels {
	return {
		yPlusX: baseOddTableFe[3 * entry],
		yMinusX: baseOddTableFe[3 * entry + 1],
		xy2d: baseOddTableFe[3 * entry + 2],
	};
}

/** p + q for an affine q, ref10's ge_madd: no Z1 * Z2 and no T2 * 2d. */
function addNielsCompleted(p: Readonly<Point>, q: Readonly<Niels>): Completed {
	const a = feMul(feSubLoose(p.y, p.x), q.yMinusX);
	const b = feMul(feAddLoose(p.x, p.y), q.yPlusX);
	const c = feMul(p.t, q.xy2d);
	const d = feAdd(p.z, p.z);
	return {
		x: feSubLoose(b, a),
		y: feAddLoose(b, a),
		z: feAddLoose(d, c),
		t: feSubLoose(d, c),
	};
}

function addNiels(p: Readonly<Point>, q: Readonly<Niels>): Point {
	return toExtended(addNielsCompleted(p, q));
}

function negNiels(p: Readonly<Niels>): Niels {
	return { yPlusX: p.yMinusX, yMinusX: p.yPlusX, xy2d: feNeg(p.xy2d) };
}

/**
 * [digit * 256^row]B for a digit in -8..8, read by touching all eight entries
 * of the row and without a branch.
 */
function selectBase(row: int32, digit: int32): Niels {
	const negative = (digit >> 31) & 1;
	const magnitude = digit - (((0 - negative) & digit) << 1);
	return feSelectNiels(baseTableFe, row, magnitude, negative as uint32);
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

/**
 * ref10's slide: s as 256 signed digits, each zero or odd and below
 * 2^(width - 1) in magnitude, with at least width - 1 zeros after every
 * nonzero digit. Variable time.
 */
function slideWindows(s: Readonly<uint8[]>, width: int32): int32[] {
	const reduced = ((s[31] as int32) & 0x80) == 0 ? s : scalarReduce32(s);
	const limit = (1 << (width - 1)) - 1;
	const r = new Array<int32>(256);
	for (let i = 0; i < 256; i++) {
		r[i] = ((reduced[i >> 3] as int32) >> (i & 7)) & 1;
	}
	for (let i = 0; i < 256; i++) {
		if (r[i] == 0) continue;
		for (let b = 1; b < width && i + b < 256; b++) {
			if (r[i + b] == 0) continue;
			const shifted = r[i + b] << b;
			if (r[i] + shifted <= limit) {
				r[i] += shifted;
				r[i + b] = 0;
			} else if (r[i] - shifted >= -limit) {
				r[i] -= shifted;
				for (let k = i + b; k < 256; k++) {
					if (r[k] == 0) {
						r[k] = 1;
						break;
					}
					r[k] = 0;
				}
			} else break;
		}
	}
	return r;
}

/**
 * [s]B in constant time from radix-16 signed digits, ref10's
 * ge_scalarmult_base; null for the identity.
 */
function mulBase(s: Readonly<uint8[]>): Point | null {
	const e = slide(s);
	let q = identity();
	for (let i = 1; i < 64; i += 2) q = addNiels(q, selectBase(i >> 1, e[i]));
	q = shift4(q);
	for (let i = 0; i < 64; i += 2) q = addNiels(q, selectBase(i >> 1, e[i]));
	if (isIdentityX(q)) return null;
	return q;
}

const baseWindowWidth = 8;
const pointWindowWidth = 4;

/** [p], [3p], [5p], ... up to the 2^(pointWindowWidth - 2) odd multiples. */
function oddMultiples(p: Readonly<Point>, twice: Readonly<Point>): Cached[] {
	const table: Cached[] = [toCached(p)];
	const step = toCached(twice);
	let multiple = p;
	for (let i = 1; i < 1 << (pointWindowWidth - 2); i++) {
		multiple = toExtended(addCached(multiple, step));
		table.push(toCached(multiple));
	}
	return table;
}

/**
 * [s1]B + [s2]p2 in variable time, ref10's ge_double_scalarmult_vartime: signed
 * sliding windows over both scalars from the top nonzero digit, odd multiples
 * of B from a static table and of p2 from a small one, and T computed only
 * before an addition. Null when p2 generates a small-order group.
 */
function mulDoubleBasePublic(
	s1: Readonly<uint8[]>,
	p2: Readonly<Point>,
	s2: Readonly<uint8[]>,
): Point | null {
	const twice = dbl(p2);
	if (isIdentityX(dbl(twice))) return null;
	const table = oddMultiples(p2, twice);
	const e1 = slideWindows(s1, baseWindowWidth);
	const e2 = slideWindows(s2, pointWindowWidth);
	let top = 255;
	while (top >= 0 && e1[top] == 0 && e2[top] == 0) top -= 1;
	let r: Completed = { x: feZero, y: feOne, z: feOne, t: feOne };
	for (let i = top; i >= 0; i--) {
		r = doubled(toProjective(r));
		const digit1 = e1[i];
		if (digit1 > 0) {
			r = addNielsCompleted(toExtended(r), baseOddNiels(digit1 >> 1));
		} else if (digit1 < 0) {
			const entry = negNiels(baseOddNiels(-digit1 >> 1));
			r = addNielsCompleted(toExtended(r), entry);
		}
		const digit2 = e2[i];
		if (digit2 > 0) r = addCached(toExtended(r), table[digit2 >> 1]);
		else if (digit2 < 0) {
			r = addCached(toExtended(r), negCached(table[-digit2 >> 1]));
		}
	}
	return toExtended(r);
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

/**
 * The 64-byte secret key (seed then public key) the C backend keeps; empty for
 * a seed not 32 bytes long.
 */
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

/**
 * RFC 8032 5.1.6; `publicKey` is the one derived from `seed`. Empty on a bad
 * length.
 */
export function ed25519Sign(
	seed: Readonly<uint8[]>,
	publicKey: Readonly<uint8[]>,
	message: Readonly<uint8[]>,
): uint8[] {
	if (
		seed.length != ed25519SeedLength ||
		publicKey.length != ed25519PublicKeyLength
	) return [];
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

/**
 * Signs with the 64-byte secret key of ed25519SecretKeyFromSeed; empty on a bad
 * length.
 */
export function ed25519SignWithSecretKey(
	secretKey: Readonly<uint8[]>,
	message: Readonly<uint8[]>,
): uint8[] {
	if (secretKey.length != ed25519SecretKeyLength) return [];
	return ed25519Sign(secretKey.slice(0, 32), secretKey.slice(32, 64), message);
}

// The eight small-order points with the sign bit cleared, plus the
// non-canonical aliases of y = 0 and y = 1, as the C backend refuses them.
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

/**
 * The shape every backend refuses before any curve work: wrong sizes,
 * small-order key or R, S not below L.
 */
export function ed25519Acceptable(
	publicKey: Readonly<uint8[]>,
	signature: Readonly<uint8[]>,
): boolean {
	if (
		publicKey.length != ed25519PublicKeyLength ||
		signature.length != ed25519SignatureLength
	) return false;
	if (isSmallOrder(publicKey, 0) || isSmallOrder(signature, 0)) return false;
	return scalarIsCanonical(signature, 32);
}

/**
 * RFC 8032 5.1.7, cofactorless: [S]B - [k]A must equal R. False on any bad
 * length, encoding or signature.
 */
export function ed25519Verify(
	publicKey: Readonly<uint8[]>,
	signature: Readonly<uint8[]>,
	message: Readonly<uint8[]>,
): boolean {
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
	const seed =
		"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60".decodeHex();
	const pub = ed25519PublicFromSeed(seed);
	assert pub.encodeHex() ==
		"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
	const sig = ed25519Sign(seed, pub, []);
	assert sig.encodeHex() ==
		"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
	assert ed25519Acceptable(pub, sig);
	assert ed25519Verify(pub, sig, []);
	assert !ed25519Verify(pub, sig, [1]);
}

test "RFC 8032 test 2: one byte" {
	const seed =
		"4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb".decodeHex();
	const pub = ed25519PublicFromSeed(seed);
	assert pub.encodeHex() ==
		"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c";
	const sig = ed25519Sign(seed, pub, [0x72]);
	assert sig.encodeHex() ==
		"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";
	assert ed25519Verify(pub, sig, [0x72]);
}

test "every base table entry is [j * 256^i]B in niels form" {
	let row = fromBytes("5866666666666666666666666666666666666666666666666666666666666666".decodeHex(), 0) as Point;
	for (let i = 0; i < 32; i++) {
		let p = row;
		for (let j = 1; j <= 8; j++) {
			const zi = feInv(p.z);
			const x = feMul(p.x, zi);
			const y = feMul(p.y, zi);
			const n = baseNiels(8 * i + j - 1);
			assert feEqual(n.yPlusX, feAdd(y, x));
			assert feEqual(n.yMinusX, feSub(y, x));
			assert feEqual(n.xy2d, feMul(feMul(x, y), edwardsD2));
			p = addPoints(p, row);
		}
		for (let k = 0; k < 8; k++) row = dbl(row);
	}
}

test "every odd base table entry is [2k + 1]B in niels form" {
	const base = fromBytes("5866666666666666666666666666666666666666666666666666666666666666".decodeHex(), 0) as Point;
	const twice = dbl(base);
	let p = base;
	for (let k = 0; k < 1 << (baseWindowWidth - 2); k++) {
		const zi = feInv(p.z);
		const x = feMul(p.x, zi);
		const y = feMul(p.y, zi);
		const n = baseOddNiels(k);
		assert feEqual(n.yPlusX, feAdd(y, x));
		assert feEqual(n.yMinusX, feSub(y, x));
		assert feEqual(n.xy2d, feMul(feMul(x, y), edwardsD2));
		p = addPoints(p, twice);
	}
	assert baseOddTableFe.length == 3 << (baseWindowWidth - 2);
}

/** [s]p by plain double-and-add over all 256 bits, with no reduction. */
function mulPlain(p: Readonly<Point>, s: Readonly<uint8[]>): Point {
	let q = identity();
	for (let i = 255; i >= 0; i--) {
		q = dbl(q);
		if ((((s[i >> 3] as int32) >> (i & 7)) & 1) == 1) q = addPoints(q, p);
	}
	return q;
}

function randomScalar(state: uint32[]): uint8[] {
	const out = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) {
		let x = state[0];
		x = x ^ (x << 13);
		x = x ^ (x >> 17);
		x = x ^ (x << 5);
		state[0] = x;
		out[i] = (x & 255) as uint8;
	}
	return out;
}

test "the double multiplication equals mulBase plus a plain multiplication" {
	const edges = [
		"0000000000000000000000000000000000000000000000000000000000000000",
		"0100000000000000000000000000000000000000000000000000000000000000",
		"ecd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010",
		"edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010",
		"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0f",
		"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
		"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		"0000000000000000000000000000000000000000000000000000000000000080",
	];
	const scalars: uint8[][] = [];
	for (const hex of edges) scalars.push(hex.decodeHex());
	const state: uint32[] = [0x9e3779b9];
	for (let i = 0; i < 6; i++) scalars.push(randomScalar(state));
	const p = mulBase(randomScalar(state)) as Point;
	for (let i = 0; i < scalars.length; i++) {
		const s1 = scalars[i];
		const s2 = scalars[(i * 5 + 3) % scalars.length];
		const viaBase = mulBase(s1);
		const plain = mulPlain(p, s2);
		const expected = viaBase == null ? plain : addPoints(viaBase, plain);
		const actual = mulDoubleBasePublic(s1, p, s2) as Point;
		assert toBytes(actual).encodeHex() == toBytes(expected).encodeHex();
	}
}

test "the double multiplication refuses a small-order point" {
	const zeroY = new Array<uint8>(32);
	const identityY = new Array<uint8>(32);
	identityY[0] = 1;
	const one = identityY.slice(0);
	assert mulDoubleBasePublic(one, fromBytes(identityY, 0) as Point, one) == null;
	assert mulDoubleBasePublic(one, fromBytes(zeroY, 0) as Point, one) == null;
}
