/**
 * Differential test of the pure RSA against std/crypto/rsa (mbedTLS on the C backend) in both directions: seeded
 * messages over many lengths, PKCS#1 v1.5 and PSS with sha256, sha384 and sha512, OAEP-SHA-256, tampered
 * signatures and ciphertexts, on the fixture key and on a key each side generated. Run it on C; on JS the
 * `*Sync` forms of std/crypto/rsa are this same pure code.
 */ import {
	RsaPrivateKey,
	RsaPublicKey,
	signSync,
	verifySync,
	encryptSync,
	decryptSync,
} from "../oracle/rsa";
import { pemDecode, pemEncode } from "std/crypto/pure/pem";
import {
	RsaPrivateData,
	rsaPrivateFromPkcs1,
	rsaPrivateFromPkcs8,
	rsaPrivateToPkcs8,
	rsaPublicOf,
	rsaGenerate,
	rsaSignPkcs1,
	rsaSignPss,
	rsaVerifyPkcs1,
	rsaVerifyPss,
	rsaOaepEncrypt,
	rsaOaepDecrypt,
} from "std/crypto/pure/rsa";
import { keyAPkcs8 } from "std/crypto/pure/rsaFixtures";

class Rng {
	state: uint32 = 0x2545f491;
}

function next(rng: Rng): uint32 {
	let x = rng.state;
	x = x ^ (x << 13);
	x = x ^ (x >> 17);
	x = x ^ (x << 5);
	rng.state = x;
	return x;
}

function randomBytes(rng: Rng, length: int32): uint8[] {
	const out = new Array<uint8>(length);
	for (let i = 0; i < length; i++) out[i] = (next(rng) & 0xff) as uint8;
	return out;
}

function flipped(bytes: Readonly<uint8[]>, at: int32): uint8[] {
	const out = bytes.slice(0);
	out[at] = (out[at] ^ 0x10) as uint8;
	return out;
}

class Differences {
	cases: int32 = 0;
	found: string[] = [];
}

function check(d: Differences, same: boolean, what: string): void {
	d.cases++;
	if (!same) d.found.push(what);
}

function pureOf(pem: string): RsaPrivateData {
	const block = pemDecode(pem);
	const key =
		block == null
			? null
			: block.label == "RSA PRIVATE KEY"
				? rsaPrivateFromPkcs1(block.der)
				: rsaPrivateFromPkcs8(block.der);
	if (key == null) throw new Error("the pure side cannot parse the key");
	return key;
}

function vendorOf(pem: string): RsaPrivateKey {
	const key = RsaPrivateKey.importPemSync(pem);
	if (!key.ok) throw new Error("the vendor cannot parse the key");
	return key.value;
}

const messageLengths: Readonly<int32[]> = [
	0,
	1,
	31,
	32,
	55,
	56,
	63,
	64,
	111,
	112,
	127,
	128,
	129,
	255,
	256,
	1023,
	1024,
	2048,
];
const hashes: Readonly<string[]> = ["sha256", "sha384", "sha512"];

function signatures(
	d: Differences,
	rng: Rng,
	name: string,
	pure: RsaPrivateData,
	vendor: RsaPrivateKey,
	vendorPublic: RsaPublicKey,
): void {
	const pub = rsaPublicOf(pure);
	for (let i = 0; i < messageLengths.length; i++) {
		const hash = hashes[i % 3];
		const pss = i % 2 == 1;
		const message = randomBytes(rng, messageLengths[i]);
		const what = `${name} ${pss ? "pss" : "pkcs1"} ${hash} length ${messageLengths[i]}`;
		const ours = pss
			? rsaSignPss(pure, hash, message)
			: rsaSignPkcs1(pure, hash, message);
		const theirs = signSync(vendor, message, hash, pss ? "pss" : "pkcs1v15");
		if (ours == null || !theirs.ok) {
			check(d, false, `${what}: a side failed to sign`);
			continue;
		}
		const theirBytes = theirs.value as uint8[];
		const pureVerifies = (signature: Readonly<uint8[]>): boolean =>
			pss
				? rsaVerifyPss(pub, hash, message, signature)
				: rsaVerifyPkcs1(pub, hash, message, signature);
		check(
			d,
			verifySync(vendorPublic, message, ours, hash, pss ? "pss" : "pkcs1v15"),
			`${what}: vendor rejects the pure signature`,
		);
		check(
			d,
			pureVerifies(theirBytes),
			`${what}: pure rejects the vendor signature`,
		);
		if (!pss) check(
			d,
			ours.encodeHex() == theirBytes.encodeHex(),
			`${what}: PKCS#1 v1.5 signatures differ`,
		);
		const tampered = flipped(theirBytes, (i * 13) % 256);
		check(
			d,
			pureVerifies(tampered) ==
				verifySync(
					vendorPublic,
					message,
					tampered,
					hash,
					pss ? "pss" : "pkcs1v15",
				),
			`${what}: sides disagree on a tampered signature`,
		);
	}
}

function ciphertexts(
	d: Differences,
	rng: Rng,
	name: string,
	pure: RsaPrivateData,
	vendor: RsaPrivateKey,
	vendorPublic: RsaPublicKey,
): void {
	for (const length of [0, 1, 32, 100, 189, 190]) {
		const message = randomBytes(rng, length);
		const what = `${name} oaep length ${length}`;
		const ours = rsaOaepEncrypt(rsaPublicOf(pure), message);
		const theirs = encryptSync(vendorPublic, message);
		if (ours == null || !theirs.ok) {
			check(d, false, `${what}: a side failed to encrypt`);
			continue;
		}
		const opened = decryptSync(vendor, ours);
		// The vendor's decryptSync reports an empty plaintext as a failure, so its side of length 0 is not compared.
		if (length > 0) check(
			d,
			opened.ok && (opened.value as uint8[]).encodeHex() == message.encodeHex(),
			`${what}: vendor cannot open the pure ciphertext`,
		);
		const ourOpened = rsaOaepDecrypt(pure, theirs.value as uint8[]);
		check(
			d,
			ourOpened != null && ourOpened.encodeHex() == message.encodeHex(),
			`${what}: pure cannot open the vendor ciphertext`,
		);
		const tampered = flipped(theirs.value as uint8[], length % 256);
		check(
			d,
			(rsaOaepDecrypt(pure, tampered) == null) ==
				!decryptSync(vendor, tampered).ok,
			`${what}: sides disagree on a tampered ciphertext`,
		);
	}
}

function compareKey(d: Differences, rng: Rng, name: string, pem: string): void {
	const pure = pureOf(pem);
	const vendor = vendorOf(pem);
	const vendorPublic = vendor.publicKey();
	signatures(d, rng, name, pure, vendor, vendorPublic);
	ciphertexts(d, rng, name, pure, vendor, vendorPublic);
}

test "pure RSA and the vendor accept each other's signatures and ciphertexts" {
	const d = new Differences();
	const rng = new Rng();
	compareKey(d, rng, "fixture key", keyAPkcs8);
	compareKey(
		d,
		rng,
		"pure-generated key",
		pemEncode("PRIVATE KEY", rsaPrivateToPkcs8(rsaGenerate(2048))),
	);
	const generated = RsaPrivateKey.generateSync(2048);
	assert generated.ok;
	const exported = generated.value.exportPemSync();
	assert exported.ok;
	compareKey(d, rng, "vendor-generated key", exported.value);
	console.log(
		`rsa differential: ${d.cases} comparisons, ${d.found.length} differences`,
	);
	for (const found of d.found) console.log(found);
	assert d.found.length == 0;
}
