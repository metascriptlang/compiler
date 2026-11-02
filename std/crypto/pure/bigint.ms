/** Arbitrary-size integer helpers for the portable RSA and elliptic-curve code, and the random bytes they draw. Not constant-time. */

when (js) {
	@emit(`function msPureRandom(size) {
	const out = new Uint8Array(size);
	for (let at = 0; at < size; at += 65536) globalThis.crypto.getRandomValues(out.subarray(at, Math.min(at + 65536, size)));
	return Array.from(out);
}`);

	extern function pureRandom(size: int32): uint8[] from "msPureRandom(#)";
}

export function randomOctets(size: int32): uint8[] {
	when (js) { return pureRandom(size); } else { throw new Error("randomOctets: the portable code draws its random bytes on the JS tier only"); }
}

export function bigFromBytes(bytes: Readonly<uint8[]>): bigint {
	let value = 0n;
	for (let i = 0; i < bytes.length; i++) value = (value << 8n) | BigInt(bytes[i]);
	return value;
}

export function bigToBytes(value: bigint, size: int32): uint8[] {
	const out: uint8[] = new Array<uint8>(size);
	let rest = value;
	for (let i = size - 1; i >= 0; i--) {
		out[i] = Number(rest & 0xffn) as uint8;
		rest = rest >> 8n;
	}
	return out;
}

export function bitLength(value: bigint): int32 {
	let bits = 0;
	let rest = value;
	while (rest >= 4294967296n) {
		rest = rest >> 32n;
		bits += 32;
	}
	let small = Number(rest);
	while (small > 0) {
		small = Math.floor(small / 2);
		bits += 1;
	}
	return bits;
}

export function mod(value: bigint, modulus: bigint): bigint {
	const r = value % modulus;
	return r < 0n ? r + modulus : r;
}

export function modPow(base: bigint, exponent: bigint, modulus: bigint): bigint {
	const table: bigint[] = [1n];
	const b = mod(base, modulus);
	for (let i = 1; i < 16; i++) table.push((table[i - 1] * b) % modulus);
	const bits = bitLength(exponent);
	let result = 1n;
	let at: int32 = ((bits + 3) >> 2) << 2;
	while (at > 0) {
		at -= 4;
		for (let i = 0; i < 4; i++) result = (result * result) % modulus;
		const nibble = Number((exponent >> BigInt(at)) & 15n);
		if (nibble != 0) result = (result * table[nibble]) % modulus;
	}
	return result;
}

export function modInverse(value: bigint, modulus: bigint): bigint {
	let a = mod(value, modulus);
	let b = modulus;
	let x0 = 1n;
	let x1 = 0n;
	while (b != 0n) {
		const q = a / b;
		const r = a - q * b;
		a = b;
		b = r;
		const next = x0 - q * x1;
		x0 = x1;
		x1 = next;
	}
	if (a != 1n) return 0n;
	return mod(x0, modulus);
}

export function gcd(a: bigint, b: bigint): bigint {
	let x = a;
	let y = b;
	while (y != 0n) {
		const r = x % y;
		x = y;
		y = r;
	}
	return x;
}

export function randomBelow(limit: bigint): bigint {
	const bits = bitLength(limit);
	const size: int32 = (bits + 7) >> 3;
	const excess: int32 = size * 8 - bits;
	while (true) {
		const bytes = randomOctets(size);
		bytes[0] = ((bytes[0] as int32) & (255 >> excess)) as uint8;
		const candidate = bigFromBytes(bytes);
		if (candidate >= 1n && candidate < limit) return candidate;
	}
}
