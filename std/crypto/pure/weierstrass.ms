/**
 * Short Weierstrass curves (P-256 and P-384) on `bigint`: key encodings (SPKI, PKCS#8, SEC1), ECDSA signature
 * encodings and, for the JavaScript `*Sync` forms, ECDSA with RFC 6979 nonces and ECDH. Not constant-time:
 * scalar multiplication branches on the scalar's bits, so use the asynchronous forms (WebCrypto) for secrets
 * that an observer of timing could reach.
 */

import {
	DerItem, derItem, derChildren, derRoot, derUnsigned, derSame, derSequence, derUnsignedInteger, derSmallInteger,
	derOctets, derBits, derOidOf, derTlv, derJoin, tagSequence, tagOctetString, tagBitString, tagOid,
	oidEcPublicKey,
} from "./asn1";
import { bigFromBytes, bigToBytes, bitLength, modInverse, randomBelow } from "./bigint";
import { hashOf } from "./hash";
import { hmacOf } from "./hmac";

export interface Curve {
	name: string;
	webName: string;
	oid: uint8[];
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
	point: uint8[];
}

export interface EcPrivateData {
	curve: Curve;
	d: uint8[];
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

export function ecPrivateFromSec1(der: Readonly<uint8[]>, curves: Curve[]): EcPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	return privateFromSec1(der, root, null, curves);
}

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

export function ecPrivateToSec1(key: EcPrivateData): uint8[] {
	return sec1Body(key, true);
}

export function ecPrivateToPkcs8(key: EcPrivateData): uint8[] {
	const algorithm = derSequence([derOidOf(oidEcPublicKey), derOidOf(key.curve.oid)]);
	return derSequence([derSmallInteger(0), algorithm, derOctets(sec1Body(key, false))]);
}

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


interface Jacobian {
	x: bigint;
	y: bigint;
	z: bigint;
}

const pointTag: uint8[] = [4];
const zeroByte: uint8[] = [0];
const oneByte: uint8[] = [1];

function repeated(count: int32, value: uint8): uint8[] {
	const out: uint8[] = [];
	for (let i = 0; i < count; i++) out.push(value);
	return out;
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

function double(c: Curve, a: Jacobian): Jacobian {
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

function add(c: Curve, a: Jacobian, b: Jacobian): Jacobian {
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

function windowOf(c: Curve, a: Jacobian): Jacobian[] {
	const table: Jacobian[] = [infinity(), a];
	for (let i = 2; i < 16; i++) table.push(i % 2 == 0 ? double(c, table[i / 2]) : add(c, table[i - 1], a));
	return table;
}

function multiplyWith(c: Curve, table: Jacobian[], scalar: bigint): Jacobian {
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

const generatorWindows: Jacobian[][] = [];
const generatorWindowOwners: string[] = [];

function generatorWindow(c: Curve): Jacobian[] {
	const found = generatorWindowOwners.indexOf(c.name);
	if (found >= 0) return generatorWindows[found];
	const table = windowOf(c, jacobianOf(c.gx, c.gy));
	generatorWindowOwners.push(c.name);
	generatorWindows.push(table);
	return table;
}

interface Affine {
	x: bigint;
	y: bigint;
}

function affineOf(c: Curve, a: Jacobian): Affine | null {
	if (a.z == 0n) return null;
	const zi = modInverse(a.z, c.p);
	const zi2 = (zi * zi) % c.p;
	return { x: (a.x * zi2) % c.p, y: (a.y * zi2 * zi) % c.p };
}

function decodePoint(c: Curve, point: Readonly<uint8[]>): Affine | null {
	if (point.length != 1 + 2 * c.size || point[0] != 4) return null;
	const x = bigFromBytes(point.slice(1, 1 + c.size));
	const y = bigFromBytes(point.slice(1 + c.size));
	if (x >= c.p || y >= c.p) return null;
	if ((y * y) % c.p != fmod(x * x * x + c.a * x + c.b, c.p)) return null;
	return { x, y };
}

function encodePoint(c: Curve, a: Affine): uint8[] {
	return derJoin([pointTag, bigToBytes(a.x, c.size), bigToBytes(a.y, c.size)]);
}

export function ecPointValid(c: Curve, point: Readonly<uint8[]>): boolean {
	return decodePoint(c, point) != null;
}

export function ecPublicPoint(c: Curve, d: Readonly<uint8[]>): uint8[] | null {
	const scalar = bigFromBytes(d);
	if (scalar < 1n || scalar >= c.n) return null;
	const point = affineOf(c, multiplyWith(c, generatorWindow(c), scalar));
	if (point == null) return null;
	return encodePoint(c, point);
}

export function ecdhShared(c: Curve, d: Readonly<uint8[]>, point: Readonly<uint8[]>): uint8[] | null {
	const scalar = bigFromBytes(d);
	const peer = decodePoint(c, point);
	if (peer == null || scalar < 1n || scalar >= c.n) return null;
	const shared = affineOf(c, multiplyWith(c, windowOf(c, jacobianOf(peer.x, peer.y)), scalar));
	if (shared == null) return null;
	return bigToBytes(shared.x, c.size);
}

function digestInt(c: Curve, digest: Readonly<uint8[]>): bigint {
	const value = bigFromBytes(digest);
	const extra = digest.length * 8 - bitLength(c.n);
	return extra > 0 ? value >> BigInt(extra) : value;
}

function nonceFor(c: Curve, kind: int32, d: Readonly<uint8[]>, digest: Readonly<uint8[]>): bigint {
	const size = hashOf(kind, []).length as int32;
	const reduced = bigToBytes(digestInt(c, digest) % c.n, c.size);
	const seed = derJoin([d, reduced]);
	let v = repeated(size, 1);
	let k = repeated(size, 0);
	k = hmacOf(kind, k, derJoin([v, zeroByte, seed]));
	v = hmacOf(kind, k, v);
	k = hmacOf(kind, k, derJoin([v, oneByte, seed]));
	v = hmacOf(kind, k, v);
	while (true) {
		let stream: uint8[] = [];
		while (stream.length < c.size) {
			v = hmacOf(kind, k, v);
			stream = derJoin([stream, v]);
		}
		const candidate = digestInt(c, stream);
		if (candidate >= 1n && candidate < c.n) return candidate;
		k = hmacOf(kind, k, derJoin([v, zeroByte]));
		v = hmacOf(kind, k, v);
	}
}

export function ecdsaSignRaw(c: Curve, kind: int32, d: Readonly<uint8[]>, digest: Readonly<uint8[]>): uint8[] | null {
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

export function ecdsaVerifyRaw(c: Curve, point: Readonly<uint8[]>, digest: Readonly<uint8[]>, raw: Readonly<uint8[]>): boolean {
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

export function ecRandomScalar(c: Curve): uint8[] {
	return bigToBytes(randomBelow(c.n), c.size);
}
