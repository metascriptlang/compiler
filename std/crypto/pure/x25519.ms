import { encodeHex, decodeHex } from "../../core/encoding";
import { Fe, feZero, feOne, feFromBytes, feToBytes, feAddLoose, feSubLoose, feMul, feMul121666, feSqr, feInv, feCMov } from "./ed25519Field";
import { wipeBytes } from "./secret";

/** The RFC 7748 Montgomery ladder: 255 steps that swap by mask, never by branch. An all-zero result means a low-order input. */
export function x25519(scalar: Readonly<uint8[]>, u: Readonly<uint8[]>): uint8[] {
	const k = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) k[i] = scalar[i];
	k[0] = k[0] & 248;
	k[31] = (k[31] & 127) | 64;
	const x1 = feFromBytes(u, 0);
	let x2: Fe = feOne;
	let z2: Fe = feZero;
	let x3: Fe = x1;
	let z3: Fe = feOne;
	let swap: uint32 = 0;
	for (let t = 254; t >= 0; t--) {
		const bit = (((k[t >> 3] as int32) >> (t & 7)) & 1) as uint32;
		swap = swap ^ bit;
		const sx2 = feCMov(x2, x3, swap);
		x3 = feCMov(x3, x2, swap);
		x2 = sx2;
		const sz2 = feCMov(z2, z3, swap);
		z3 = feCMov(z3, z2, swap);
		z2 = sz2;
		swap = bit;
		const a = feAddLoose(x2, z2);
		const aa = feSqr(a);
		const b = feSubLoose(x2, z2);
		const bb = feSqr(b);
		const e = feSubLoose(aa, bb);
		const c = feAddLoose(x3, z3);
		const d = feSubLoose(x3, z3);
		const da = feMul(d, a);
		const cb = feMul(c, b);
		x3 = feSqr(feAddLoose(da, cb));
		z3 = feMul(x1, feSqr(feSubLoose(da, cb)));
		x2 = feMul(aa, bb);
		z2 = feMul(e, feAddLoose(bb, feMul121666(e)));
	}
	x2 = feCMov(x2, x3, swap);
	z2 = feCMov(z2, z3, swap);
	wipeBytes(k);
	return feToBytes(feMul(x2, feInv(z2)));
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
