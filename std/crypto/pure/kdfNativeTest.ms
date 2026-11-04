import { hmacOf, newHmac, updateHmac, finishHmac, pbkdf2Of, hkdfOf } from "./hmac";
import { kindSha1, kindSha224, kindSha256, kindSha384, kindSha512, kindMd5 } from "./state";
import { encodeHex } from "../../core/encoding";

function rep(count: int32, value: uint8): uint8[] {
	const out = new Array<uint8>(count);
	for (let i = 0; i < count; i++) out[i] = value;
	return out;
}

function seq(start: int32, count: int32): uint8[] {
	const out = new Array<uint8>(count);
	for (let i = 0; i < count; i++) out[i] = (start + i) as uint8;
	return out;
}

function text(value: string): uint8[] {
	return value.asBytes().slice(0);
}

test "RFC4231 TC2 HMAC-SHA-256 short ASCII key" {
	assert hmacOf(kindSha256, text("Jefe"), text("what do ya want for nothing?")).encodeHex()
		== "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843";
}

test "RFC4231 TC2 HMAC-SHA-512 short ASCII key" {
	assert hmacOf(kindSha512, text("Jefe"), text("what do ya want for nothing?")).encodeHex()
		== "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737";
}

test "RFC4231 TC3 HMAC-SHA-256 repeated-byte key and data" {
	assert hmacOf(kindSha256, rep(20, 0xaa), rep(50, 0xdd)).encodeHex()
		== "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe";
}

test "RFC4231 TC3 HMAC-SHA-512 repeated-byte key and data" {
	assert hmacOf(kindSha512, rep(20, 0xaa), rep(50, 0xdd)).encodeHex()
		== "fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb";
}

test "RFC4231 TC4 HMAC-SHA-256 sequential-byte key" {
	assert hmacOf(kindSha256, seq(0x01, 25), rep(50, 0xcd)).encodeHex()
		== "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b";
}

test "RFC4231 TC7 HMAC-SHA-256 large key and large data" {
	const d = text("This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.");
	assert hmacOf(kindSha256, rep(131, 0xaa), d).encodeHex()
		== "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2";
}

test "RFC4231 TC7 HMAC-SHA-512 large key and large data" {
	const d = text("This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.");
	assert hmacOf(kindSha512, rep(131, 0xaa), d).encodeHex()
		== "e37b6a775dc87dbaa4dfa9f96e5e3ffddebd71f8867289865df5a32d20cdc944b6022cac3c4982b10d5eeb55c3e4de15134676fb6de0446065c97440fa8c6a58";
}

test "RFC5869 TC2 HKDF-SHA-256 80-byte ikm salt info L=82" {
	assert hkdfOf(kindSha256, seq(0x00, 80), seq(0x60, 80), seq(0xb0, 80), 82).encodeHex()
		== "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87";
}

test "RFC5869 TC4 HKDF-SHA-1 11-byte ikm 13-byte salt L=42" {
	assert hkdfOf(kindSha1, rep(11, 0x0b), seq(0x00, 13), seq(0xf0, 10), 42).encodeHex()
		== "085a01ea1b10f36933068b56efa5ad81a4f14b822f5b091568a9cdd4f155fda2c22e422478d305f3f896";
}

test "RFC5869 TC5 HKDF-SHA-1 80-byte ikm salt info L=82" {
	assert hkdfOf(kindSha1, seq(0x00, 80), seq(0x60, 80), seq(0xb0, 80), 82).encodeHex()
		== "0bd770a74d1160f7c9f12cd5912a06ebff6adcae899d92191fe4305673ba2ffe8fa3f1a4e5ad79f3f334b3b202b2173c486ea37ce3d397ed034c7f9dfeb15c5e927336d0441f4c4300e2cff0d0900b52d3b4";
}

test "RFC5869 TC6 HKDF-SHA-1 no salt no info L=42" {
	assert hkdfOf(kindSha1, rep(22, 0x0b), new Array<uint8>(0), new Array<uint8>(0), 42).encodeHex()
		== "0ac1af7002b3d761d1e55298da9d0506b9ae52057220a306e07b6b87e8df21d0ea00033de03984d34918";
}

test "PBKDF2-SHA-256 password salt iterations=2 dkLen=32" {
	assert pbkdf2Of(kindSha256, text("password"), text("salt"), 2, 32).encodeHex()
		== "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43";
}

test "pbkdf2 must throw on iterations 0" {
	let threw = false;
	try {
		pbkdf2Of(kindSha1, text("p"), text("s"), 0, 20);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "pbkdf2 must throw on negative iterations" {
	let threw = false;
	try {
		pbkdf2Of(kindSha1, text("p"), text("s"), -1, 20);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "hkdf must throw when length exceeds 255 SHA-256 hash lengths" {
	let threw = false;
	try {
		hkdfOf(kindSha256, rep(22, 0x0b), new Array<uint8>(0), new Array<uint8>(0), 255 * 32 + 1);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "hkdf must throw when length exceeds 255 SHA-1 hash lengths" {
	let threw = false;
	try {
		hkdfOf(kindSha1, rep(22, 0x0b), new Array<uint8>(0), new Array<uint8>(0), 255 * 20 + 1);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

function pbkdf2Refused(iterations: int32, length: int32): boolean {
	try {
		pbkdf2Of(kindSha1, text("p"), text("s"), iterations, length);
	} catch (e) {
		return true;
	}
	return false;
}

function hkdfRefused(kind: int32, length: int32): boolean {
	try {
		hkdfOf(kind, rep(22, 0x0b), new Array<uint8>(0), new Array<uint8>(0), length);
	} catch (e) {
		return true;
	}
	return false;
}

function hmacRefused(kind: int32): boolean {
	try {
		hmacOf(kind, text("k"), text("d"));
	} catch (e) {
		return true;
	}
	return false;
}

test "RFC4231 TC1 HMAC-SHA-384" {
	assert hmacOf(kindSha384, rep(20, 0x0b), text("Hi There")).encodeHex()
		== "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6";
}

test "RFC4231 TC6 key longer than block size, SHA-256 SHA-384 SHA-512" {
	const d = text("Test Using Larger Than Block-Size Key - Hash Key First");
	assert hmacOf(kindSha256, rep(131, 0xaa), d).encodeHex()
		== "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54";
	assert hmacOf(kindSha384, rep(131, 0xaa), d).encodeHex()
		== "4ece084485813e9088d2c63a041bc5b44f9ef1012a2b588f3cd11f05033ac4c60c2ef6ab4030fe8296248df163f44952";
	assert hmacOf(kindSha512, rep(131, 0xaa), d).encodeHex()
		== "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f3526b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598";
}

test "RFC2202 HMAC-SHA-1 and HMAC-MD5 key longer than block size" {
	const d = text("Test Using Larger Than Block-Size Key - Hash Key First");
	assert hmacOf(kindSha1, rep(80, 0xaa), d).encodeHex() == "aa4ae5e15272d00e95705637ce8a3b55ed402112";
	assert hmacOf(kindMd5, rep(80, 0xaa), d).encodeHex() == "6b1ab7fe4bd7bf8f0b62e6ce61b9d0cd";
}

test "HMAC with an empty key and empty data" {
	assert hmacOf(kindSha256, new Array<uint8>(0), new Array<uint8>(0)).encodeHex()
		== "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad";
}

test "RFC6070 PBKDF2-SHA-1 long password and salt dkLen=25" {
	assert pbkdf2Of(kindSha1, text("passwordPASSWORDpassword"), text("saltSALTsaltSALTsaltSALTsaltSALTsalt"), 4096, 25).encodeHex()
		== "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038";
}

test "RFC6070 PBKDF2-SHA-1 embedded NUL dkLen=16" {
	const password: uint8[] = [0x70, 0x61, 0x73, 0x73, 0x00, 0x77, 0x6f, 0x72, 0x64];
	const salt: uint8[] = [0x73, 0x61, 0x00, 0x6c, 0x74];
	assert pbkdf2Of(kindSha1, password, salt, 4096, 16).encodeHex() == "56fa6aa75548099dcc37d7f03425e0c3";
}

test "RFC5869 TC7 HKDF-SHA-1 salt not provided L=42" {
	assert hkdfOf(kindSha1, rep(22, 0x0c), new Array<uint8>(0), new Array<uint8>(0), 42).encodeHex()
		== "2c91117204d745f3500d636a62f64f0ab3bae548aa53d423b0d1f27ebba6f5e5673a081d70cce7acfc48";
}

test "hkdf at the 255 hash-length boundary is accepted" {
	assert hkdfOf(kindSha1, rep(22, 0x0b), new Array<uint8>(0), new Array<uint8>(0), 255 * 20).length == 255 * 20;
}

test "pbkdf2 refuses zero, negative and oversized key lengths" {
	assert pbkdf2Refused(1, 0);
	assert pbkdf2Refused(1, -1);
	assert pbkdf2Refused(1, 1048577);
	assert !pbkdf2Refused(1, 1);
}

test "hkdf refuses zero and negative lengths" {
	assert hkdfRefused(kindSha256, 0);
	assert hkdfRefused(kindSha256, -5);
	assert !hkdfRefused(kindSha256, 1);
}

test "hmac refuses an unknown hash kind" {
	assert hmacRefused(-1);
	assert hmacRefused(99);
	assert hkdfRefused(99, 32);
}

test "hmac vectors from RFC 4231 and RFC 2202" {
	const short = rep(20, 0x0b);
	assert hmacOf(kindSha256, short, text("Hi There")).encodeHex() == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
	assert hmacOf(kindSha512, short, text("Hi There")).encodeHex() == "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854";
	assert hmacOf(kindSha1, short, text("Hi There")).encodeHex() == "b617318655057264e28bc0b6fb378c8ef146be00";
	assert hmacOf(kindMd5, rep(16, 0x0b), text("Hi There")).encodeHex() == "9294727a3638bb1c13f48ef8158bfc9d";
	const long = rep(131, 0xaa);
	assert hmacOf(kindSha256, long, text("Test Using Larger Than Block-Size Key - Hash Key First")).encodeHex() == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54";
}

test "pbkdf2 vectors from RFC 6070 and the SHA-256 companion" {
	assert pbkdf2Of(kindSha1, text("password"), text("salt"), 1, 20).encodeHex() == "0c60c80f961f0e71f3a9b524af6012062fe037a6";
	assert pbkdf2Of(kindSha1, text("password"), text("salt"), 2, 20).encodeHex() == "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957";
	assert pbkdf2Of(kindSha1, text("password"), text("salt"), 4096, 20).encodeHex() == "4b007901b765489abead49d926f721d065a429c1";
	assert pbkdf2Of(kindSha256, text("password"), text("salt"), 1, 32).encodeHex() == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b";
}

test "hkdf vectors from RFC 5869" {
	const salt = seq(0x00, 13);
	const info = seq(0xf0, 10);
	assert hkdfOf(kindSha256, rep(22, 0x0b), salt, info, 42).encodeHex() == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865";
	const none = new Array<uint8>(0);
	assert hkdfOf(kindSha256, rep(22, 0x0b), none, none, 42).encodeHex() == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8";
}

test "RFC4231 TC5 truncated output compares the 128-bit prefix" {
	const key = rep(20, 0x0c);
	const data = text("Test With Truncation");
	assert hmacOf(kindSha224, key, data).slice(0, 16).encodeHex() == "0e2aea68a90c8d37c988bcdb9fca6fa8";
	assert hmacOf(kindSha256, key, data).slice(0, 16).encodeHex() == "a3b6167473100ee06e0c796c2955552b";
	assert hmacOf(kindSha384, key, data).slice(0, 16).encodeHex() == "3abf34c3503b2a23a46efc619baef897";
	assert hmacOf(kindSha512, key, data).slice(0, 16).encodeHex() == "415fad6271580a531d4179bc891d87a6";
}

test "streaming hmac matches one-shot and restarts on the same key after finishing" {
	const key = rep(131, 0xaa);
	const data = seq(0, 200);
	const expected = hmacOf(kindSha256, key, data).encodeHex();
	const hmac = newHmac(kindSha256, key);
	updateHmac(hmac, data.slice(0, 7));
	updateHmac(hmac, data.slice(7, 200));
	assert finishHmac(hmac).encodeHex() == expected;
	updateHmac(hmac, data);
	assert finishHmac(hmac).encodeHex() == expected;
}
