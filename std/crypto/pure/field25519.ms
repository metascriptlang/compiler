import { encodeHex, decodeHex } from "../../core/encoding";

export const P: bigint = (1n << 255n) - 19n;

/** Sum, below 2P when both operands are below P; only mul and mod accept it onward. */
export function add(a: bigint, b: bigint): bigint {
	return a + b;
}

/** Difference kept positive by adding 2P, so the subtrahend must be below 2P. */
export function sub(a: bigint, b: bigint): bigint {
	return a + 2n * P - b;
}

export function mul(a: bigint, b: bigint): bigint {
	return (a * b) % P;
}

export function sqr(a: bigint): bigint {
	return (a * a) % P;
}

export function mod(a: bigint): bigint {
	return a % P;
}

export function sqrK(a: bigint, count: int32): bigint {
	let r = a;
	for (let i = 0; i < count; i++) r = (r * r) % P;
	return r;
}

/** x^(2^252 - 3), the shared exponent of the inverse and of the square root. */
export function pow2252m3(x: bigint): bigint {
	const b2 = mul(sqr(x), x);
	const b4 = mul(sqrK(b2, 2), b2);
	const b5 = mul(sqrK(b4, 1), x);
	const b10 = mul(sqrK(b5, 5), b5);
	const b20 = mul(sqrK(b10, 10), b10);
	const b40 = mul(sqrK(b20, 20), b20);
	const b80 = mul(sqrK(b40, 40), b40);
	const b160 = mul(sqrK(b80, 80), b80);
	const b240 = mul(sqrK(b160, 80), b80);
	const b250 = mul(sqrK(b240, 10), b10);
	return mul(sqrK(b250, 2), x);
}

/** x^(P - 2) = (x^(2^252 - 3))^8 * x^3; the exponent is fixed, so the operation sequence never depends on x. */
export function inv(x: bigint): bigint {
	return mul(sqrK(pow2252m3(x), 3), mul(sqr(x), x));
}

export function bigFromBytes(bytes: Readonly<uint8[]>, from: int32, length: int32): bigint {
	let n = 0n;
	for (let i = length - 1; i >= 0; i--) n = (n << 8n) | BigInt(bytes[from + i] as int32);
	return n;
}

export function bigToBytes(value: bigint, length: int32): uint8[] {
	const out = new Array<uint8>(length);
	let rest = value;
	for (let i = 0; i < length; i++) {
		out[i] = Number(rest & 255n) as uint8;
		rest = rest >> 8n;
	}
	return out;
}

test "the inverse multiplies back to one, including for a value above P" {
	const x = 0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdefn;
	assert mul(x, inv(x)) == 1n;
	assert mul(inv(P + 5n), 5n) == 1n;
}

test "bytes round trip through bigint in little-endian order" {
	const bytes = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20".decodeHex();
	assert bigFromBytes(bytes, 0, 32) % 256n == 1n;
	assert bigToBytes(bigFromBytes(bytes, 0, 32), 32).encodeHex() == "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
}
