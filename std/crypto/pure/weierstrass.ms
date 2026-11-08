/**
 * Short Weierstrass curves (P-256 and P-384): key encodings (SPKI, PKCS#8, SEC1), ECDSA signature
 * encodings, ECDSA with RFC 6979 nonces and ECDH. The native backend computes on the fixed-width
 * limbs of ./pcurve, multiplying a secret scalar in constant time; JavaScript computes on its own
 * `bigint` through ./bigCurve, which is not constant-time.
 */

import {
	DerItem, derItem, derChildren, derRoot, derUnsigned, derSame, derSequence, derUnsignedInteger, derSmallInteger,
	derOctets, derBits, derOidOf, derTlv, derJoin, tagSequence, tagOctetString, tagBitString, tagOid,
	oidEcPublicKey, keyRoot, keyChildren,
} from "./asn1";
import { Limbs, mul, add, equal, invert, nonzero, toMontgomery, fromMontgomery, fromBytes, reduceBytes, toBytes } from "./montgomery";
import { CurveMath, mulBase, mulSecret, mulDoubleBasePublic, affineBytes, decodePoint, encodePoint } from "./pcurve";
import { hashOf } from "./hash";
import { hmacOf } from "./hmac";
import { declassify, wipeBytes } from "./secret";

when (js) {
	import { bigPointValid, bigPublicPoint, bigEcdhShared, bigSignRaw, bigVerifyRaw, bigExpandPoint } from "./bigCurve";
}

export interface Curve {
	name: string;
	webName: string;
	oid: uint8[];
	/** Bytes of a field element and of a scalar: the order has exactly `8 * size` bits on both curves. */
	size: int32;
	math: CurveMath;
}

export interface EcPublicData {
	curve: Curve;
	point: uint8[];
}

export interface EcPrivateData {
	curve: Curve;
	d: uint8[];
	point: uint8[];
}

/** A key owns its own curve record, because a curve constant is a read-only view and a view cannot be returned or stored. */
export function ownCurve(c: Readonly<Curve>): Curve {
	return { name: c.name, webName: c.webName, oid: [...c.oid], size: c.size, math: c.math };
}

function curveWithOid(curves: Readonly<Curve[]>, buf: Readonly<uint8[]>, item: DerItem): Curve | null {
	if (item.tag != tagOid) return null;
	for (const curve of curves) {
		if (derSame(buf, item, curve.oid)) return ownCurve(curve);
	}
	return null;
}

function pointAt(buf: Readonly<uint8[]>, bits: DerItem, curve: Readonly<Curve>): uint8[] | null {
	const length = bits.end - bits.body;
	if (bits.tag != tagBitString || length < 2 || buf[bits.body] != 0) return null;
	const prefix = buf[bits.body + 1];
	const compressed = (prefix == 2 || prefix == 3) && length == 2 + curve.size;
	if (!compressed && (prefix != 4 || length != 2 + 2 * curve.size)) return null;
	const out: uint8[] = [];
	for (let i = bits.body + 1; i < bits.end; i++) out.push(buf[i]);
	if (!compressed) return out;
	when (js) {
		return bigExpandPoint(curve.size, out);
	} else {
		const point = decodePoint(curve.math, out);
		return point == null ? null : encodePoint(curve.math, point);
	}
}

export function ecPublicFromSpki(
	der: Readonly<uint8[]>, curves: Readonly<Curve[]>,
	pemLengths: boolean = false,
): EcPublicData | null {
	const root = pemLengths ? keyRoot(der, tagSequence) :
		derRoot(der, tagSequence);
	if (root == null) return null;
	const parts = pemLengths ? keyChildren(der, root) : derChildren(der, root);
	if (parts == null || parts.length != 2 || parts[0].tag != tagSequence) return null;
	const algorithm = pemLengths ? keyChildren(der, parts[0]) :
		derChildren(der, parts[0]);
	if (algorithm == null || algorithm.length != 2 || algorithm[0].tag != tagOid || !derSame(der, algorithm[0], oidEcPublicKey())) return null;
	const curve = curveWithOid(curves, der, algorithm[1]);
	if (curve == null) return null;
	const point = pointAt(der, parts[1], curve);
	if (point == null) return null;
	return { curve, point };
}

export function ecPublicToSpki(key: EcPublicData): uint8[] {
	const algorithm = derSequence([derOidOf(oidEcPublicKey()), derOidOf(key.curve.oid)]);
	return derSequence([algorithm, derBits(key.point)]);
}

function privateFromSec1(buf: Readonly<uint8[]>, seq: DerItem, outer: Curve | null, curves: Readonly<Curve[]>): EcPrivateData | null {
	const parts = derChildren(buf, seq);
	if (parts == null || parts.length < 2 || parts.length > 4) return null;
	const version = derUnsigned(buf, parts[0]);
	if (version == null || version.length != 1 || version[0] != 1) return null;
	if (parts[1].tag != tagOctetString) return null;
	let curve = outer;
	let bits: DerItem | null = null;
	for (let i = 2; i < parts.length; i++) {
		const inner = derItem(buf, parts[i].body, parts[i].end);
		if (inner == null || inner.end != parts[i].end) return null;
		if (parts[i].tag == 0xa0) {
			const named = curveWithOid(curves, buf, inner);
			if (named == null || (curve != null && named.name != curve.name)) return null;
			curve = named;
		} else if (parts[i].tag == 0xa1) {
			bits = inner;
		} else {
			return null;
		}
	}
	if (curve == null) return null;
	const length = parts[1].end - parts[1].body;
	if (length < 1 || length > curve.size) return null;
	const d: uint8[] = new Array<uint8>(curve.size);
	const pad = curve.size - length;
	for (let i = 0; i < length; i++) d[pad + i] = buf[parts[1].body + i];
	let point: uint8[] = [];
	if (bits != null) {
		const found = pointAt(buf, bits, curve);
		if (found == null) {
			wipeBytes(d);
			return null;
		}
		point = found;
	}
	return { curve, d, point };
}

export function ecPrivateFromSec1(der: Readonly<uint8[]>, curves: Readonly<Curve[]>): EcPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	return privateFromSec1(der, root, null, curves);
}

export function ecPrivateFromPkcs8(der: Readonly<uint8[]>, curves: Readonly<Curve[]>): EcPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	const parts = derChildren(der, root);
	if (parts == null || parts.length != 3 || parts[2].tag != tagOctetString) return null;
	const version = derUnsigned(der, parts[0]);
	if (version == null || version.length != 1 || version[0] != 0 || parts[1].tag != tagSequence) return null;
	const algorithm = derChildren(der, parts[1]);
	if (algorithm == null || algorithm.length != 2 || algorithm[0].tag != tagOid || !derSame(der, algorithm[0], oidEcPublicKey())) return null;
	const curve = curveWithOid(curves, der, algorithm[1]);
	if (curve == null) return null;
	const inner = derItem(der, parts[2].body, parts[2].end);
	if (inner == null || inner.tag != tagSequence || inner.end != parts[2].end) return null;
	return privateFromSec1(der, inner, curve, curves);
}

function sec1Body(key: EcPrivateData, withParameters: boolean): uint8[] {
	const secret = derOctets(key.d);
	const parts: uint8[][] = [derSmallInteger(1), secret];
	if (withParameters) parts.push(derTlv(0xa0, derOidOf(key.curve.oid)));
	if (key.point.length > 0) parts.push(derTlv(0xa1, derBits(key.point)));
	const out = derSequence(parts);
	wipeBytes(secret);
	return out;
}

export function ecPrivateToSec1(key: EcPrivateData): uint8[] {
	return sec1Body(key, true);
}

export function ecPrivateToPkcs8(key: EcPrivateData): uint8[] {
	const algorithm = derSequence([derOidOf(oidEcPublicKey()), derOidOf(key.curve.oid)]);
	const inner = sec1Body(key, false);
	const octets = derOctets(inner);
	const out = derSequence([derSmallInteger(0), algorithm, octets]);
	wipeBytes(inner);
	wipeBytes(octets);
	return out;
}

/** DER writes an integer in its fewest bytes: a leading zero only before a byte with the top bit set. */
function derMinimal(buf: Readonly<uint8[]>, item: DerItem): boolean {
	return item.end - item.body < 2 || buf[item.body] != 0 || (buf[item.body + 1] & 0x80) != 0;
}

export function ecdsaDerToRaw(sig: Readonly<uint8[]>, size: int32): uint8[] | null {
	const root = derRoot(sig, tagSequence);
	if (root == null) return null;
	const parts = derChildren(sig, root);
	if (parts == null || parts.length != 2) return null;
	const out: uint8[] = new Array<uint8>(2 * size);
	for (let k = 0; k < 2; k++) {
		if (!derMinimal(sig, parts[k])) return null;
		const value = derUnsigned(sig, parts[k]);
		if (value == null || value.length > size) return null;
		const pad = k * size + size - value.length;
		for (let i = 0; i < value.length; i++) out[pad + i] = value[i];
	}
	return out;
}

export function ecdsaRawToDer(raw: Readonly<uint8[]>): uint8[] {
	const half = (raw.length / 2) as int32;
	const r: uint8[] = [];
	const s: uint8[] = [];
	for (let i = 0; i < half; i++) {
		r.push(raw[i]);
		s.push(raw[half + i]);
	}
	return derSequence([derUnsignedInteger(r), derUnsignedInteger(s)]);
}

/** A secret scalar in [1, n) as limbs, or null; `d` must be exactly `size` bytes. */
function secretScalar(c: Readonly<Curve>, d: Readonly<uint8[]>): Limbs | null {
	if (d.length != c.size) return null;
	const k = fromBytes(c.math.order, d, 0);
	if (k == null || declassify(nonzero(c.math.order, k)) == 0) return null;
	return k;
}

/** bits2int of RFC 6979 for an order of exactly `8 * size` bits: the leftmost `size` bytes, left-padded. */
function leftmost(size: int32, bytes: Readonly<uint8[]>): uint8[] {
	const out = new Array<uint8>(size);
	if (bytes.length >= size) {
		for (let i = 0; i < size; i++) out[i] = bytes[i];
	} else {
		for (let i = 0; i < bytes.length; i++) out[size - bytes.length + i] = bytes[i];
	}
	return out;
}

function digestScalar(c: Readonly<Curve>, digest: Readonly<uint8[]>): Limbs {
	return reduceBytes(c.math.order, leftmost(c.size, digest), 0);
}

function pointValid(c: Readonly<Curve>, point: Readonly<uint8[]>): boolean {
	return decodePoint(c.math, point) != null;
}

function publicPoint(c: Readonly<Curve>, d: Readonly<uint8[]>): uint8[] | null {
	if (secretScalar(c, d) == null) return null;
	const point = mulBase(c.math, d);
	return point == null ? null : encodePoint(c.math, point);
}

function sharedSecret(c: Readonly<Curve>, d: Readonly<uint8[]>, point: Readonly<uint8[]>): uint8[] | null {
	const peer = decodePoint(c.math, point);
	if (peer == null || secretScalar(c, d) == null) return null;
	const shared = mulSecret(c.math, peer, d);
	if (shared == null) return null;
	const xy = affineBytes(c.math, shared);
	if (xy == null) return null;
	wipeBytes(xy[1]);
	return xy[0];
}

/** K = HMAC_K(parts joined), clearing the joined input and the old K. */
function rekey(kind: int32, k: uint8[], parts: Readonly<uint8[]>[]): uint8[] {
	const input = derJoin(parts);
	const next = hmacOf(kind, k, input);
	wipeBytes(input);
	wipeBytes(k);
	return next;
}

/** V = HMAC_K(V), clearing the old V. */
function restep(kind: int32, k: Readonly<uint8[]>, v: uint8[]): uint8[] {
	const next = hmacOf(kind, k, v);
	wipeBytes(v);
	return next;
}

/** The RFC 6979 nonce as `size` bytes, in [1, n). */
function nonceFor(c: Readonly<Curve>, kind: int32, d: Readonly<uint8[]>, digest: Readonly<uint8[]>): uint8[] {
	const size = hashOf(kind, []).length as int32;
	const seed = derJoin([d, toBytes(c.math.order, digestScalar(c, digest))]);
	let v = new Array<uint8>(size);
	v.fill(1);
	let k = new Array<uint8>(size);
	k = rekey(kind, k, [v, [0], seed]);
	v = restep(kind, k, v);
	k = rekey(kind, k, [v, [1], seed]);
	v = restep(kind, k, v);
	wipeBytes(seed);
	while (true) {
		const stream: uint8[] = [];
		while (stream.length < c.size) {
			v = restep(kind, k, v);
			for (const b of v) stream.push(b);
		}
		const candidate = leftmost(c.size, stream);
		wipeBytes(stream);
		if (secretScalar(c, candidate) != null) {
			wipeBytes(k);
			wipeBytes(v);
			return candidate;
		}
		wipeBytes(candidate);
		k = rekey(kind, k, [v, [0]]);
		v = restep(kind, k, v);
	}
}

function signRaw(c: Readonly<Curve>, kind: int32, d: Readonly<uint8[]>, digest: Readonly<uint8[]>): uint8[] | null {
	const order = c.math.order;
	const scalar = secretScalar(c, d);
	if (scalar == null) return null;
	const nonce = nonceFor(c, kind, d, digest);
	const k = fromBytes(order, nonce, 0) as Limbs;
	const point = mulBase(c.math, nonce);
	wipeBytes(nonce);
	const xy = point == null ? null : affineBytes(c.math, point);
	if (xy == null) return null;
	const r = reduceBytes(order, xy[0], 0);
	const rd = mul(order, toMontgomery(order, r), toMontgomery(order, scalar));
	const sum = add(order, toMontgomery(order, digestScalar(c, digest)), rd);
	const s = fromMontgomery(order, mul(order, invert(order, toMontgomery(order, k)), sum));
	if (declassify(nonzero(order, r) & nonzero(order, s)) == 0) return null;
	return derJoin([toBytes(order, r), toBytes(order, s)]);
}

function verifyRaw(c: Readonly<Curve>, point: Readonly<uint8[]>, digest: Readonly<uint8[]>, raw: Readonly<uint8[]>): boolean {
	const order = c.math.order;
	const q = decodePoint(c.math, point);
	if (q == null || raw.length != 2 * c.size) return false;
	const r = fromBytes(order, raw, 0);
	const s = fromBytes(order, raw, c.size);
	if (r == null || s == null || nonzero(order, r) == 0 || nonzero(order, s) == 0) return false;
	const e = digestScalar(c, digest);
	if (nonzero(order, e) == 0) return false;
	const w = invert(order, toMontgomery(order, s));
	const u1 = fromMontgomery(order, mul(order, toMontgomery(order, e), w));
	const u2 = fromMontgomery(order, mul(order, toMontgomery(order, r), w));
	const sum = mulDoubleBasePublic(c.math, toBytes(order, u1), q, toBytes(order, u2));
	const xy = sum == null ? null : affineBytes(c.math, sum);
	return xy != null && equal(order, reduceBytes(order, xy[0], 0), r);
}

export function ecPointValid(c: Readonly<Curve>, point: Readonly<uint8[]>): boolean {
	when (js) {
		return bigPointValid(c.size, point);
	} else {
		return pointValid(c, point);
	}
}

export function ecPublicPoint(c: Readonly<Curve>, d: Readonly<uint8[]>): uint8[] | null {
	when (js) {
		return bigPublicPoint(c.size, d);
	} else {
		return publicPoint(c, d);
	}
}

export function ecdhShared(c: Readonly<Curve>, d: Readonly<uint8[]>, point: Readonly<uint8[]>): uint8[] | null {
	when (js) {
		return bigEcdhShared(c.size, d, point);
	} else {
		return sharedSecret(c, d, point);
	}
}

export function ecdsaSignRaw(c: Readonly<Curve>, kind: int32, d: Readonly<uint8[]>, digest: Readonly<uint8[]>): uint8[] | null {
	when (js) {
		return bigSignRaw(c.size, kind, d, digest);
	} else {
		return signRaw(c, kind, d, digest);
	}
}

export function ecdsaVerifyRaw(c: Readonly<Curve>, point: Readonly<uint8[]>, digest: Readonly<uint8[]>, raw: Readonly<uint8[]>): boolean {
	when (js) {
		return bigVerifyRaw(c.size, point, digest, raw);
	} else {
		return verifyRaw(c, point, digest, raw);
	}
}

when (c) {
	@include("runtime/crypto/randomFill.h");
	extern function osRandomFill(
		buffer: Ptr<uint8>,
		length: uint64,
	): int32 from "ms_random_fill";
}

when (js) {
	@emit(`function msEcRandom(size) {
	const out = new Uint8Array(size);
	globalThis.crypto.getRandomValues(out);
	return Array.from(out);
}`);

	extern function jsRandom(size: int32): uint8[] from "msEcRandom(#)";
}

function drawBytes(size: int32): uint8[] | null {
	when (js) {
		return jsRandom(size);
	} else {
		const out = new Array<uint8>(size);
		const span: Span<uint8> = out;
		if (osRandomFill(span as Ptr<uint8>, size as uint64) != 0) return null;
		return out;
	}
}

/** A uniform scalar in [1, n), drawn by rejection; null when the random source failed. */
export function ecDrawScalar(c: Readonly<Curve>): uint8[] | null {
	while (true) {
		const bytes = drawBytes(c.size);
		if (bytes == null) return null;
		if (secretScalar(c, bytes) != null) return bytes;
		wipeBytes(bytes);
	}
}

export function ecRandomScalar(c: Readonly<Curve>): uint8[] {
	const d = ecDrawScalar(c);
	if (d == null) throw new Error("ecRandomScalar: the random source failed");
	return d;
}
