/**
 * Short Weierstrass curves (P-256 and P-384) on `bigint`: key encodings (SPKI, PKCS#8, SEC1), ECDSA signature
 * encodings and, for the JavaScript `*Sync` forms, ECDSA with RFC 6979 nonces and ECDH. Not constant-time:
 * scalar multiplication branches on the scalar's bits, so use the asynchronous forms (WebCrypto) for secrets
 * that an observer of timing could reach.
 */

import {
	DerItem, derItem, derChildren, derRoot, derUnsigned, derSame, derSequence, derUnsignedInteger, derSmallInteger,
	derOctets, derBits, derOidOf, derTlv, tagSequence, tagOctetString, tagBitString, tagOid,
	oidEcPublicKey,
} from "./asn1";

export interface Curve {
	name: string;
	/** The name WebCrypto gives the curve. */
	webName: string;
	oid: uint8[];
	/** Bytes in a field element and in the group order. */
	size: int32;
	p: bigint;
	a: bigint;
	b: bigint;
	n: bigint;
	gx: bigint;
	gy: bigint;
}

export interface EcPublicData {
	curve: Curve;
	/** The uncompressed point: 0x04, x, y. */
	point: uint8[];
}

export interface EcPrivateData {
	curve: Curve;
	/** The scalar, `curve.size` bytes. */
	d: uint8[];
	/** The uncompressed public point, or empty when the encoding the key came from had none. */
	point: uint8[];
}

function curveWithOid(curves: Curve[], buf: Readonly<uint8[]>, item: DerItem): Curve | null {
	if (item.tag != tagOid) return null;
	for (const curve of curves) {
		if (derSame(buf, item, curve.oid)) return curve;
	}
	return null;
}

function pointAt(buf: Readonly<uint8[]>, bits: DerItem, curve: Curve): uint8[] | null {
	if (bits.tag != tagBitString || bits.end - bits.body != 2 + 2 * curve.size || buf[bits.body] != 0 || buf[bits.body + 1] != 4) return null;
	const out: uint8[] = [];
	for (let i = bits.body + 1; i < bits.end; i++) out.push(buf[i]);
	return out;
}

/** SubjectPublicKeyInfo (`PUBLIC KEY`). The point is only shape-checked here; the curve check is the importer's. */
export function ecPublicFromSpki(der: Readonly<uint8[]>, curves: Curve[]): EcPublicData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	const parts = derChildren(der, root);
	if (parts == null || parts.length != 2 || parts[0].tag != tagSequence) return null;
	const algorithm = derChildren(der, parts[0]);
	if (algorithm == null || algorithm.length != 2 || algorithm[0].tag != tagOid || !derSame(der, algorithm[0], oidEcPublicKey)) return null;
	const curve = curveWithOid(curves, der, algorithm[1]);
	if (curve == null) return null;
	const point = pointAt(der, parts[1], curve);
	if (point == null) return null;
	return { curve, point };
}

export function ecPublicToSpki(key: EcPublicData): uint8[] {
	const algorithm = derSequence([derOidOf(oidEcPublicKey), derOidOf(key.curve.oid)]);
	return derSequence([algorithm, derBits(key.point)]);
}

/** ECPrivateKey; `outer` is the curve a PKCS#8 wrapper named, or null for a bare SEC1 key, which must name its own. */
function privateFromSec1(buf: Readonly<uint8[]>, seq: DerItem, outer: Curve | null, curves: Curve[]): EcPrivateData | null {
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
			if (named == null || (curve != null && named != curve)) return null;
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
		if (found == null) return null;
		point = found;
	}
	return { curve, d, point };
}

/** ECPrivateKey (`EC PRIVATE KEY`). */
export function ecPrivateFromSec1(der: Readonly<uint8[]>, curves: Curve[]): EcPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	return privateFromSec1(der, root, null, curves);
}

/** PrivateKeyInfo (`PRIVATE KEY`). */
export function ecPrivateFromPkcs8(der: Readonly<uint8[]>, curves: Curve[]): EcPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	const parts = derChildren(der, root);
	if (parts == null || parts.length != 3 || parts[2].tag != tagOctetString) return null;
	const version = derUnsigned(der, parts[0]);
	if (version == null || version.length != 1 || version[0] != 0 || parts[1].tag != tagSequence) return null;
	const algorithm = derChildren(der, parts[1]);
	if (algorithm == null || algorithm.length != 2 || algorithm[0].tag != tagOid || !derSame(der, algorithm[0], oidEcPublicKey)) return null;
	const curve = curveWithOid(curves, der, algorithm[1]);
	if (curve == null) return null;
	const inner = derItem(der, parts[2].body, parts[2].end);
	if (inner == null || inner.tag != tagSequence || inner.end != parts[2].end) return null;
	return privateFromSec1(der, inner, curve, curves);
}

function sec1Body(key: EcPrivateData, withParameters: boolean): uint8[] {
	const parts: uint8[][] = [derSmallInteger(1), derOctets(key.d)];
	if (withParameters) parts.push(derTlv(0xa0, derOidOf(key.curve.oid)));
	if (key.point.length > 0) parts.push(derTlv(0xa1, derBits(key.point)));
	return derSequence(parts);
}

/** In the shape `mbedtls` writes: the curve parameters and the public point both present. */
export function ecPrivateToSec1(key: EcPrivateData): uint8[] {
	return sec1Body(key, true);
}

export function ecPrivateToPkcs8(key: EcPrivateData): uint8[] {
	const algorithm = derSequence([derOidOf(oidEcPublicKey), derOidOf(key.curve.oid)]);
	return derSequence([derSmallInteger(0), algorithm, derOctets(sec1Body(key, false))]);
}

/** The DER `SEQUENCE { r, s }` as the fixed-width `r || s` WebCrypto uses, or null for anything else. */
export function ecdsaDerToRaw(sig: Readonly<uint8[]>, size: int32): uint8[] | null {
	const root = derRoot(sig, tagSequence);
	if (root == null) return null;
	const parts = derChildren(sig, root);
	if (parts == null || parts.length != 2) return null;
	const out: uint8[] = new Array<uint8>(2 * size);
	for (let k = 0; k < 2; k++) {
		const value = derUnsigned(sig, parts[k]);
		if (value == null || value.length > size) return null;
		const pad = k * size + size - value.length;
		for (let i = 0; i < value.length; i++) out[pad + i] = value[i];
	}
	return out;
}

/** `r || s` of equal halves as the DER `SEQUENCE { r, s }` that the native backend produces. */
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
