/** RSA key integers as minimal big-endian bytes, shared by the key encodings and both arithmetic backends. */

/** Key integers as minimal big-endian bytes. */
export interface RsaPublicData {
	n: uint8[];
	e: uint8[];
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

/** Zeroes secret bytes once they are no longer needed. */
export function wipeBytes(bytes: uint8[]): void {
	for (let i = 0; i < bytes.length; i++) bytes[i] = 0;
}
