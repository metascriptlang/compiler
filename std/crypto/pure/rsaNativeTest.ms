import { pemDecode, pemEncode } from "./pem";
import { bytesOf } from "./bytes";
import {
	RsaPublicData, RsaPrivateData, rsaPublicFromPkcs1, rsaPublicFromSpki, rsaPublicToSpki, rsaPrivateFromPkcs1,
	rsaPrivateFromPkcs8, rsaPrivateToPkcs1, rsaPrivateToPkcs8, rsaPublicOf, rsaGenerate, rsaSignPkcs1, rsaSignPss,
	rsaVerifyPkcs1, rsaVerifyPss, rsaOaepEncrypt, rsaOaepDecrypt, rsaModulusBytes,
} from "./rsa";
import {
	keyAPkcs8, keyAPkcs1, keyASpki, keyAPkcs1Public, keyBPkcs8, keyBSpki, key1024Pkcs8, key1024Spki, message,
	pkcs1Sha256, pkcs1Sha384, pkcs1Sha512, pkcs1Sha1, pssSha256, pssSha384, pssSha512, pssMaxSaltSha256,
	pssNoSaltSha256, oaepSha256,
} from "./rsaFixtures";

function privateOf(pem: string): RsaPrivateData | null {
	const block = pemDecode(pem);
	if (block == null) return null;
	if (block.label == "PRIVATE KEY") return rsaPrivateFromPkcs8(block.der);
	if (block.label == "RSA PRIVATE KEY") return rsaPrivateFromPkcs1(block.der);
	return null;
}

function publicOf(pem: string): RsaPublicData | null {
	const block = pemDecode(pem);
	if (block == null) return null;
	if (block.label == "PUBLIC KEY") return rsaPublicFromSpki(block.der);
	if (block.label == "RSA PUBLIC KEY") return rsaPublicFromPkcs1(block.der);
	return null;
}

function privateA(): RsaPrivateData {
	const key = privateOf(keyAPkcs8);
	if (key == null) throw new Error("fixture key A does not parse");
	return key;
}

function publicA(): RsaPublicData {
	const key = publicOf(keyASpki);
	if (key == null) throw new Error("fixture public key A does not parse");
	return key;
}

function publicB(): RsaPublicData {
	const key = publicOf(keyBSpki);
	if (key == null) throw new Error("fixture public key B does not parse");
	return key;
}

function flipped(hex: string, at: int32): uint8[] {
	const bytes = hex.decodeHex() as uint8[];
	bytes[at] = (bytes[at] ^ 1) as uint8;
	return bytes;
}

test "every key format parses to the same 2048-bit key" {
	const p8 = privateA();
	const p1 = privateOf(keyAPkcs1);
	const spki = publicA();
	const pub1 = publicOf(keyAPkcs1Public);
	assert p1 != null && pub1 != null;
	assert rsaModulusBytes(p8.n) == 256;
	const n = p8.n.encodeHex();
	assert p1.n.encodeHex() == n && p1.d.encodeHex() == p8.d.encodeHex() && spki.n.encodeHex() == n;
	assert pub1.n.encodeHex() == n && spki.e.encodeHex() == "010001";
	const crlf = publicOf(keyASpki.split("\n").join(" \t\r\n"));
	assert crlf != null && crlf.n.encodeHex() == n;
}

test "encoders write the same PEM text openssl wrote" {
	const key = privateA();
	assert pemEncode("PUBLIC KEY", rsaPublicToSpki(rsaPublicOf(key))) == keyASpki;
	assert pemEncode("RSA PRIVATE KEY", rsaPrivateToPkcs1(key)) == keyAPkcs1;
	assert pemEncode("PRIVATE KEY", rsaPrivateToPkcs8(key)) == keyAPkcs8;
}

test "malformed, foreign and short keys are refused" {
	assert privateOf("") == null;
	assert privateOf("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n") == null;
	assert privateOf(keyAPkcs8.replace("-----END PRIVATE KEY-----", "")) == null;
	assert privateOf(keyAPkcs8.slice(0, 400) + "\n-----END PRIVATE KEY-----\n") == null;
	assert publicOf(keyAPkcs8) == null;
	assert privateOf(keyASpki) == null;
	assert privateOf(key1024Pkcs8) == null;
	assert publicOf(key1024Spki) == null;
}

test "PKCS#1 v1.5 signatures match openssl byte for byte" {
	const key = privateA();
	const data = bytesOf(message);
	const s256 = rsaSignPkcs1(key, "sha256", data);
	const s384 = rsaSignPkcs1(key, "sha384", data);
	const s512 = rsaSignPkcs1(key, "sha512", data);
	assert s256 != null && s384 != null && s512 != null;
	assert s256.encodeHex() == pkcs1Sha256;
	assert s384.encodeHex() == pkcs1Sha384;
	assert s512.encodeHex() == pkcs1Sha512;
}

test "PKCS#1 v1.5 verifies openssl signatures and refuses tampering and the wrong key" {
	const pub = publicA();
	const data = bytesOf(message);
	assert rsaVerifyPkcs1(pub, "sha256", data, pkcs1Sha256.decodeHex());
	assert rsaVerifyPkcs1(pub, "sha384", data, pkcs1Sha384.decodeHex());
	assert rsaVerifyPkcs1(pub, "sha512", data, pkcs1Sha512.decodeHex());
	assert rsaVerifyPkcs1(pub, "sha1", data, pkcs1Sha1.decodeHex());
	assert !rsaVerifyPkcs1(pub, "sha384", data, pkcs1Sha256.decodeHex());
	assert !rsaVerifyPkcs1(pub, "sha256", data, flipped(pkcs1Sha256, 100));
	assert !rsaVerifyPkcs1(pub, "sha256", bytesOf(message + "!"), pkcs1Sha256.decodeHex());
	assert !rsaVerifyPkcs1(pub, "sha256", data, (pkcs1Sha256 + "00").decodeHex());
	assert !rsaVerifyPkcs1(pub, "md5", data, pkcs1Sha256.decodeHex());
	assert !rsaVerifyPkcs1(publicB(), "sha256", data, pkcs1Sha256.decodeHex());
}

test "PSS verifies openssl signatures of any salt length" {
	const pub = publicA();
	const data = bytesOf(message);
	assert rsaVerifyPss(pub, "sha256", data, pssSha256.decodeHex());
	assert rsaVerifyPss(pub, "sha384", data, pssSha384.decodeHex());
	assert rsaVerifyPss(pub, "sha512", data, pssSha512.decodeHex());
	assert rsaVerifyPss(pub, "sha256", data, pssMaxSaltSha256.decodeHex());
	assert rsaVerifyPss(pub, "sha256", data, pssNoSaltSha256.decodeHex());
	assert !rsaVerifyPss(pub, "sha256", data, flipped(pssSha256, 7));
	assert !rsaVerifyPss(pub, "sha256", bytesOf(message + "!"), pssSha256.decodeHex());
	assert !rsaVerifyPss(pub, "sha512", data, pssSha256.decodeHex());
	assert !rsaVerifyPss(pub, "sha256", data, pkcs1Sha256.decodeHex());
	assert !rsaVerifyPss(publicB(), "sha256", data, pssSha256.decodeHex());
}

test "PSS sign and verify roundtrip with a fresh salt" {
	const key = privateA();
	const pub = rsaPublicOf(key);
	const data = bytesOf(message);
	const first = rsaSignPss(key, "sha256", data);
	const second = rsaSignPss(key, "sha256", data);
	assert first != null && second != null;
	assert first.length == 256 && first.encodeHex() != second.encodeHex();
	assert rsaVerifyPss(pub, "sha256", data, first);
	assert rsaVerifyPss(pub, "sha256", data, second);
	assert !rsaVerifyPss(publicB(), "sha256", data, first);
}

test "OAEP decrypts the openssl ciphertext and refuses tampering and the wrong key" {
	const key = privateA();
	const opened = rsaOaepDecrypt(key, oaepSha256.decodeHex());
	assert opened != null && opened.encodeHex() == bytesOf(message).encodeHex();
	assert rsaOaepDecrypt(key, flipped(oaepSha256, 50)) == null;
	assert rsaOaepDecrypt(key, (oaepSha256 + "00").decodeHex()) == null;
	const other = privateOf(keyBPkcs8);
	assert other != null && rsaOaepDecrypt(other, oaepSha256.decodeHex()) == null;
}

test "OAEP roundtrips up to the size limit and refuses one byte more" {
	const key = privateA();
	const pub = rsaPublicOf(key);
	const longest: uint8[] = [];
	for (let i = 0; i < 190; i++) longest.push((i * 7) as uint8);
	const sealed = rsaOaepEncrypt(pub, longest);
	assert sealed != null && sealed.length == 256;
	const opened = rsaOaepDecrypt(key, sealed);
	assert opened != null && opened.encodeHex() == longest.encodeHex();
	const empty: uint8[] = [];
	const sealedEmpty = rsaOaepEncrypt(pub, empty);
	assert sealedEmpty != null;
	const openedEmpty = rsaOaepDecrypt(key, sealedEmpty);
	assert openedEmpty != null && openedEmpty.length == 0;
	longest.push(1);
	assert rsaOaepEncrypt(pub, longest) == null;
}

test "a generated 2048-bit key signs and verifies" {
	const key = rsaGenerate(2048);
	assert rsaModulusBytes(key.n) == 256 && key.e.encodeHex() == "010001";
	const reparsed = privateOf(pemEncode("PRIVATE KEY", rsaPrivateToPkcs8(key)));
	assert reparsed != null;
	const data = bytesOf(message);
	const signature = rsaSignPkcs1(reparsed, "sha256", data);
	assert signature != null && rsaVerifyPkcs1(rsaPublicOf(key), "sha256", data, signature);
}
