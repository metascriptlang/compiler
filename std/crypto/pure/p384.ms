import { Curve, ecPublicPoint, ecdsaSignRaw, ecdsaVerifyRaw, ecdhShared, ecRandomScalar } from "./weierstrass";
import { p384Math } from "./pcurve";
import { hashOf } from "./hash";
import { kindSha384 } from "./state";
import { encodeHex } from "../../core/encoding";

/** NIST P-384 (secp384r1), SEC 2 v2 section 2.5.1. */
export const p384: Readonly<Curve> = {
	name: "p384",
	webName: "P-384",
	oid: [0x2b, 0x81, 0x04, 0x00, 0x22],
	size: 48,
	math: p384Math,
};

test "p384 key and signature from RFC 6979 appendix A.2.6, and ECDH with a random key agrees both ways" {
	const d = "6b9d3dad2e1b8c1c05b19875b6659f4de23c3b667bf297ba9aa47740787137d896d5724e4c70a825f872c9ea60d2edf5".decodeHex();
	const point = ecPublicPoint(p384, d);
	assert point != null;
	assert encodeHex(point as uint8[]) == "04ec3a4e415b4e19a4568618029f427fa5da9a8bc4ae92e02e06aae5286b300c64def8f0ea9055866064a254515480bc138015d9b72d7d57244ea8ef9ac0c621896708a59367f9dfb9f54ca84b3f1c9db1288b231c3ae0d4fe7344fd2533264720";
	const digest = hashOf(kindSha384, "sample".asBytes().slice(0));
	const signature = ecdsaSignRaw(p384, kindSha384, d, digest);
	assert signature != null;
	assert encodeHex(signature as uint8[]) == "94edbb92a5ecb8aad4736e56c691916b3f88140666ce9fa73d64c4ea95ad133c81a648152e44acf96e36dd1e80fabe4699ef4aeb15f178cea1fe40db2603138f130e740a19624526203b6351d0a3a94fa329c145786e679e7b82c71a38628ac8";
	assert ecdsaVerifyRaw(p384, point as uint8[], digest, signature as uint8[]);
	const other = ecRandomScalar(p384);
	const otherPoint = ecPublicPoint(p384, other);
	assert otherPoint != null;
	const ab = ecdhShared(p384, d, otherPoint as uint8[]);
	const ba = ecdhShared(p384, other, point as uint8[]);
	assert ab != null && ba != null;
	assert encodeHex(ab as uint8[]) == encodeHex(ba as uint8[]);
}
