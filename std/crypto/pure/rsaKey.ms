/** RSA key integers as minimal big-endian bytes, shared by the key encodings and both arithmetic backends. */

import { Modulus } from "./ff";
import { wipeBytes, wipeWords, wipeWords64 } from "./secret";

/**
 * Key integers as minimal big-endian bytes. The `Modulus` fields carry the Montgomery constants the C arithmetic
 * built once when the key was made (`rsaModulusOf`); they are null on JavaScript and for an unusable modulus.
 */
export interface RsaPublicData {
	n: uint8[];
	e: uint8[];
	nModulus: Modulus | null;
}

export interface RsaPrivateData {
	n: uint8[];
	e: uint8[];
	d: uint8[];
	p: uint8[];
	q: uint8[];
	dp: uint8[];
	dq: uint8[];
	qi: uint8[];
	nModulus: Modulus | null;
	pModulus: Modulus | null;
	qModulus: Modulus | null;
}

function wipePrime(modulus: Modulus | null): void {
	if (modulus == null) return;
	wipeWords(modulus.v);
	wipeWords(modulus.rr);
	wipeWords64(modulus.w);
	wipeWords64(modulus.wrr);
	wipeWords64(modulus.wone);
}

/** Clears the private integers and prime moduli; the public half (`n`, `e`, `nModulus`) stays usable. */
export function rsaWipePrivate(data: RsaPrivateData): void {
	for (const bytes of [data.d, data.p, data.q, data.dp, data.dq, data.qi]) {
		wipeBytes(bytes);
	}
	wipePrime(data.pModulus);
	wipePrime(data.qModulus);
	data.pModulus = null;
	data.qModulus = null;
}

/** The bit length of a big-endian integer. */
export function bytesBitLength(bytes: Readonly<uint8[]>): int32 {
	let at = 0;
	while (at < bytes.length && bytes[at] == 0) at += 1;
	if (at == bytes.length) return 0;
	let bits = 8;
	let top = bytes[at] as int32;
	while (top < 0x80) {
		top = top << 1;
		bits -= 1;
	}
	return (bytes.length - at - 1) * 8 + bits;
}

export function rsaModulusBytes(n: Readonly<uint8[]>): int32 {
	return (bytesBitLength(n) + 7) >> 3;
}

export function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= (a[i] ^ b[i]) as int32;
	return diff == 0;
}
