import { encodeHex, decodeHex } from "../../core/encoding";
import { add, sub, mul, sqr, inv, bigFromBytes, bigToBytes } from "./field25519";

const a24 = 121665n;
const swapMasks: Readonly<bigint[]> = [0n, (1n << 256n) - 1n];

/** The RFC 7748 Montgomery ladder: 255 steps that swap by mask, never by branch. An all-zero result means a low-order input. */
export function x25519(scalar: Readonly<uint8[]>, u: Readonly<uint8[]>): uint8[] {
	const k = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) k[i] = scalar[i];
	k[0] = k[0] & 248;
	k[31] = (k[31] & 127) | 64;
	const x1 = bigFromBytes(u, 0, 32) & ((1n << 255n) - 1n);
	let x2 = 1n;
	let z2 = 0n;
	let x3 = x1;
	let z3 = 1n;
	let swap = 0;
	for (let t = 254; t >= 0; t--) {
		const bit = ((k[t >> 3] as int32) >> (t & 7)) & 1;
		swap = swap ^ bit;
		const mask = swapMasks[swap];
		const dx = mask & (x2 ^ x3);
		x2 = x2 ^ dx;
		x3 = x3 ^ dx;
		const dz = mask & (z2 ^ z3);
		z2 = z2 ^ dz;
		z3 = z3 ^ dz;
		swap = bit;
		const a = add(x2, z2);
		const aa = sqr(a);
		const b = sub(x2, z2);
		const bb = sqr(b);
		const e = sub(aa, bb);
		const c = add(x3, z3);
		const d = sub(x3, z3);
		const da = mul(d, a);
		const cb = mul(c, b);
		x3 = sqr(add(da, cb));
		z3 = mul(x1, sqr(sub(da, cb)));
		x2 = mul(aa, bb);
		z2 = mul(e, add(aa, mul(a24, e)));
	}
	const mask = swapMasks[swap];
	const dx = mask & (x2 ^ x3);
	x2 = x2 ^ dx;
	const dz = mask & (z2 ^ z3);
	z2 = z2 ^ dz;
	return bigToBytes(mul(x2, inv(z2)), 32);
}

test "RFC 7748 5.2 first vector" {
	const out = x25519(
		"a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4".decodeHex(),
		"e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c".decodeHex(),
	);
	assert out.encodeHex() == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552";
}

test "RFC 7748 6.1 shared secret, and a zero input gives all zero" {
	const alice = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a".decodeHex();
	const bob = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb".decodeHex();
	const base = "0900000000000000000000000000000000000000000000000000000000000000".decodeHex();
	const alicePub = x25519(alice, base);
	const bobPub = x25519(bob, base);
	assert alicePub.encodeHex() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a";
	assert bobPub.encodeHex() == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f";
	assert x25519(alice, bobPub).encodeHex() == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
	assert x25519(bob, "00".repeat(32).decodeHex()).encodeHex() == "00".repeat(32);
}
