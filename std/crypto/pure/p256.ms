import { Curve, ecPublicPoint, ecdsaSignRaw, ecdsaVerifyRaw, ecdhShared, ecPointValid, ecRandomScalar } from "./weierstrass";
import { hashOf } from "./hash";
import { kindSha256 } from "./state";
import { encodeHex } from "../../core/encoding";

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

test "p256 key and signature from RFC 6979 appendix A.2.5, and ECDH agrees both ways" {
	const d = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721".decodeHex();
	const point = ecPublicPoint(p256, d);
	assert point != null;
	assert encodeHex(point as uint8[]) == "0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299";
	const digest = hashOf(kindSha256, "sample".asBytes().slice(0));
	const signature = ecdsaSignRaw(p256, kindSha256, d, digest);
	assert signature != null;
	assert encodeHex(signature as uint8[]) == "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";
	assert ecdsaVerifyRaw(p256, point as uint8[], digest, signature as uint8[]);
	const other = ecRandomScalar(p256);
	const otherPoint = ecPublicPoint(p256, other);
	assert otherPoint != null;
	const ab = ecdhShared(p256, d, otherPoint as uint8[]);
	const ba = ecdhShared(p256, other, point as uint8[]);
	assert ab != null && ba != null;
	assert encodeHex(ab as uint8[]) == encodeHex(ba as uint8[]);
}

test "p256 refuses a point off the curve and a scalar outside the group order" {
	const d = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721".decodeHex();
	const point = ecPublicPoint(p256, d) as uint8[];
	const bent = point.slice(0);
	bent[64] = (bent[64] ^ 1) as uint8;
	assert ecPointValid(p256, point);
	assert !ecPointValid(p256, bent);
	assert ecdhShared(p256, d, bent) == null;
	assert ecPublicPoint(p256, new Array<uint8>(32)) == null;
}
