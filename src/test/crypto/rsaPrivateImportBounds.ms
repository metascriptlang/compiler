import { RsaPrivateKey } from "std/crypto/pure/rsaNative";
import { CryptoErrorKind } from "std/crypto/errors";
import { keyAPkcs1, keyAPkcs8 } from "std/crypto/pure/rsaFixtures";
import { pemDecode, pemEncode } from "std/crypto/pure/pem";
import {
	derRoot, derChildren, derBody, derUnsigned, derUnsignedInteger,
	derSequence, derSmallInteger, derOctets, derOidOf, derTlv,
	oidRsaEncryption, tagSequence, tagNull,
} from "std/crypto/pure/asn1";

when (c) {
	import { RsaPrivateKey as NativePrivateKey } from "std/crypto/rsa";
}

function integersOf(pem: string): uint8[][] {
	const block = pemDecode(pem);
	if (block == null) throw new Error("RSA fixture PEM decode failed");
	let der: uint8[] = block.der;
	if (block.label == "PRIVATE KEY") {
		const root = derRoot(der, tagSequence);
		const parts = root == null ? null : derChildren(der, root);
		if (parts == null || parts.length != 3) throw new Error("RSA fixture PKCS8 shape");
		der = derBody(der, parts[2]);
	} else if (block.label != "RSA PRIVATE KEY") {
		throw new Error("RSA fixture label");
	}
	const root = derRoot(der, tagSequence);
	const parts = root == null ? null : derChildren(der, root);
	if (parts == null || parts.length != 9) throw new Error("RSA fixture PKCS1 shape");
	const values: uint8[][] = [];
	for (const part of parts) {
		const value = derUnsigned(der, part);
		if (value == null) throw new Error("RSA fixture INTEGER decode failed");
		values.push(value);
	}
	return values;
}

function zeroExponent(pem: string, pkcs8: boolean): string {
	const values = integersOf(pem);
	values[3] = [0];
	const encoded: uint8[][] = [];
	for (const value of values) encoded.push(derUnsignedInteger(value));
	const key = derSequence(encoded);
	if (!pkcs8) return pemEncode("RSA PRIVATE KEY", key);
	return pemEncode("PRIVATE KEY", derSequence([
		derSmallInteger(0),
		derSequence([derOidOf(oidRsaEncryption()), derTlv(tagNull, [])]),
		derOctets(key),
	]));
}

test "zero-exponent RSA fixtures preserve every other INTEGER" {
	for (const pkcs8 of [false, true]) {
		const pem = pkcs8 ? keyAPkcs8 : keyAPkcs1;
		const before = integersOf(pem);
		const after = integersOf(zeroExponent(pem, pkcs8));
		assert before[3].length > 1;
		assert after[3].length == 1 && after[3][0] == 0;
		for (let i = 0; i < 9; i++) {
			if (i != 3) assert before[i].encodeHex() == after[i].encodeHex();
		}
	}
}

test "valid RSA private fixtures still import in both formats" {
	for (const pem of [keyAPkcs1, keyAPkcs8]) {
		assert RsaPrivateKey.importPemSync(pem).ok;
		when (c) { assert NativePrivateKey.importPemSync(pem).ok; }
	}
}

test "RSA PKCS1 import refuses a zero private exponent" {
	const pem = zeroExponent(keyAPkcs1, false);
	when (c) { assert !NativePrivateKey.importPemSync(pem).ok; }
	const imported = RsaPrivateKey.importPemSync(pem);
	assert !imported.ok, "RSA PKCS1 accepted zero private exponent";
	if (!imported.ok) {
		assert imported.error.kind == CryptoErrorKind.InvalidKey;
		assert imported.error.operation == "RsaPrivateKey.importPem";
	}
}

test "RSA PKCS8 import refuses a zero private exponent" {
	const pem = zeroExponent(keyAPkcs8, true);
	when (c) { assert !NativePrivateKey.importPemSync(pem).ok; }
	const imported = RsaPrivateKey.importPemSync(pem);
	assert !imported.ok, "RSA PKCS8 accepted zero private exponent";
	if (!imported.ok) {
		assert imported.error.kind == CryptoErrorKind.InvalidKey;
		assert imported.error.operation == "RsaPrivateKey.importPem";
	}
}
