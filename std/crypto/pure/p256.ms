import { Curve } from "./weierstrass";

/** NIST P-256 (secp256r1, prime256v1), SEC 2 v2 section 2.4.2. */
export const p256: Curve = {
	name: "p256",
	webName: "P-256",
	oid: [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07],
	size: 32,
	p: 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn,
	a: 0xffffffff00000001000000000000000000000000fffffffffffffffffffffffcn,
	b: 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604bn,
	n: 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n,
	gx: 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n,
	gy: 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n,
};
