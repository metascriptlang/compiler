// Constant-time taint run of the native crypto port: `taintRun <case>` computes the case once untainted, then again
// with its secret marked undefined for Valgrind memcheck, checks that the taint reached the output and that the output
// is unchanged, and declassifies it. Memcheck then reports any branch or memory index that depends on the secret.
// Driven by tools/crypto/ctTaint.sh, one Valgrind process per case; `taintRun --list` prints the cases.
//
// Exit: 0 ok, 10 unknown case, 11 not under Valgrind (without --native), 14 taint never reached the output,
// 15 the tainted run changed the output; memcheck's own --error-exitcode reports a finding.

import { argv } from "std/process";
import { onValgrind, markSecret, markSecretWords, markSecretWords64, declassify, undefinedBytes } from "./memcheck";
import { x25519 } from "std/crypto/pure/x25519";
import { ed25519Sign, ed25519PublicFromSeed } from "std/crypto/pure/ed25519";
import { ecdsaSignRaw, ecdhShared, ecPublicPoint } from "std/crypto/pure/weierstrass";
import { p256 } from "std/crypto/pure/p256";
import { p384 } from "std/crypto/pure/p384";
import { hashOf } from "std/crypto/pure/hash";
import { hmacOf, hkdfOf, pbkdf2Of } from "std/crypto/pure/hmac";
import { kindSha256, kindSha512 } from "std/crypto/pure/state";
import { blake2bOf } from "std/crypto/pure/blake2b";
import { expandKey, expandKeyDecrypt, gcmSealWithNonce, gcmOpen, cbcEncrypt, cbcDecrypt } from "std/crypto/pure/aes";
import { keyWords, xchachaSealInto, xchachaOpenInto } from "std/crypto/pure/chacha";
import { argon2Raw, Argon2Mode } from "std/crypto/pure/argon2";
import { pemDecode } from "std/crypto/pure/pem";
import { RsaPrivateData } from "std/crypto/pure/rsaKey";
import { rsaPrivateFromPkcs8, rsaSignPkcs1, rsaOaepDecrypt } from "std/crypto/pure/rsa";
import { Modulus } from "std/crypto/pure/ff";
import { keyAPkcs8, oaepSha256 } from "std/crypto/pure/rsaFixtures";

/** A deterministic, non-trivial secret of `length` bytes for case `seed`. */
function fixed(seed: int32, length: int32): uint8[] {
	const out = new Array<uint8>(length);
	let x = (0x9e3779b9 ^ (seed * 0x85ebca6b)) as uint32;
	for (let i = 0; i < length; i++) {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		out[i] = (x & 255) as uint8;
	}
	return out;
}

function secretOf(seed: int32, length: int32, taint: boolean): uint8[] {
	const s = fixed(seed, length);
	if (taint) markSecret(s);
	return s;
}

function or(found: uint8[] | null, what: string): uint8[] {
	if (found == null) throw new Error(`${what} returned null`);
	return found;
}

function rsaKey(): RsaPrivateData {
	const block = pemDecode(keyAPkcs8);
	if (block == null) throw new Error("rsa fixture does not decode");
	const key = rsaPrivateFromPkcs8(block.der);
	if (key == null) throw new Error("rsa fixture does not parse");
	return key;
}

function markModulus(m: Modulus | null): void {
	if (m == null) return;
	markSecretWords(m.v);
	markSecretWords(m.rr);
	markSecretWords64(m.w);
	markSecretWords64(m.wrr);
	markSecretWords64(m.wone);
}

/** The private half after an untainted parse, so the parse's own length branches stay out of the signing verdict. */
function rsaKeyTainted(taint: boolean): RsaPrivateData {
	const key = rsaKey();
	if (taint) {
		for (const part of [key.d, key.p, key.q, key.dp, key.dq, key.qi]) markSecret(part);
		markModulus(key.pModulus);
		markModulus(key.qModulus);
	}
	return key;
}

const message: uint8[] = [0x6d, 0x65, 0x74, 0x61, 0x73, 0x63, 0x72, 0x69, 0x70, 0x74];
const nonce12: uint8[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
const iv16: uint8[] = [16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1];

const cases: string[] = [
	"x25519", "ed25519Public", "ed25519Sign", "p256Public", "p256Sign", "p256Ecdh", "p384Public", "p384Sign", "p384Ecdh",
	"rsaSignPkcs1", "rsaOaepDecrypt", "aesGcmSeal", "aesGcmOpen", "aesCbcEncrypt", "aesCbcDecrypt", "xchachaSeal",
	"xchachaOpen", "sha256", "sha512", "hmacSha256", "hkdfSha256", "pbkdf2Sha256", "blake2bKeyed", "argon2i", "argon2id",
	"leakyBranch", "leakyIndex", "noop",
];

function run(name: string, taint: boolean): uint8[] {
	if (name == "x25519") return x25519(secretOf(1, 32, taint), fixed(2, 32));
	if (name == "ed25519Public") return ed25519PublicFromSeed(secretOf(3, 32, taint));
	if (name == "ed25519Sign") {
		const pub = ed25519PublicFromSeed(fixed(3, 32));
		return ed25519Sign(secretOf(3, 32, taint), pub, message);
	}
	if (name == "p256Public") return or(ecPublicPoint(p256, secretOf(4, 32, taint)), name);
	if (name == "p384Public") return or(ecPublicPoint(p384, secretOf(5, 48, taint)), name);
	if (name == "p256Sign") return or(ecdsaSignRaw(p256, kindSha256, secretOf(4, 32, taint), hashOf(kindSha256, message)), name);
	if (name == "p384Sign") return or(ecdsaSignRaw(p384, kindSha512, secretOf(5, 48, taint), hashOf(kindSha512, message)), name);
	if (name == "p256Ecdh") return or(ecdhShared(p256, secretOf(4, 32, taint), or(ecPublicPoint(p256, fixed(6, 32)), "peer")), name);
	if (name == "p384Ecdh") return or(ecdhShared(p384, secretOf(5, 48, taint), or(ecPublicPoint(p384, fixed(7, 48)), "peer")), name);
	if (name == "rsaSignPkcs1") return or(rsaSignPkcs1(rsaKeyTainted(taint), "sha256", message), name);
	if (name == "rsaOaepDecrypt") return or(rsaOaepDecrypt(rsaKeyTainted(taint), oaepSha256.decodeHex()), name);
	if (name == "aesGcmSeal") return gcmSealWithNonce(expandKey(secretOf(8, 32, taint)), nonce12, secretOf(9, 100, taint), message);
	if (name == "aesGcmOpen") {
		const sealed = gcmSealWithNonce(expandKey(fixed(8, 32)), nonce12, fixed(9, 100), message);
		return or(gcmOpen(expandKey(secretOf(8, 32, taint)), sealed, message), name);
	}
	if (name == "aesCbcEncrypt") return cbcEncrypt(expandKey(secretOf(10, 16, taint)), iv16, secretOf(11, 64, taint));
	if (name == "aesCbcDecrypt") {
		const cipher = cbcEncrypt(expandKey(fixed(10, 16)), iv16, fixed(11, 64));
		return or(cbcDecrypt(expandKeyDecrypt(secretOf(10, 16, taint)), iv16, cipher), name);
	}
	if (name == "xchachaSeal" || name == "xchachaOpen") {
		const words = new Array<uint32>(8);
		const plain = fixed(13, 100);
		const sealed = new Array<uint8>(24 + plain.length + 16);
		for (let i = 0; i < 24; i++) sealed[i] = (i + 1) as uint8;
		if (name == "xchachaSeal") {
			keyWords(secretOf(12, 32, taint), words);
			if (taint) markSecret(plain);
			xchachaSealInto(words, message, plain, sealed);
			return sealed;
		}
		keyWords(fixed(12, 32), words);
		xchachaSealInto(words, message, plain, sealed);
		keyWords(secretOf(12, 32, taint), words);
		const opened = new Array<uint8>(plain.length);
		if (!xchachaOpenInto(words, message, sealed, opened)) throw new Error("xchacha open refused");
		return opened;
	}
	if (name == "sha256") return hashOf(kindSha256, secretOf(14, 200, taint));
	if (name == "sha512") return hashOf(kindSha512, secretOf(14, 200, taint));
	if (name == "hmacSha256") return hmacOf(kindSha256, secretOf(15, 32, taint), message);
	if (name == "hkdfSha256") return hkdfOf(kindSha256, secretOf(16, 32, taint), message, message, 64);
	if (name == "pbkdf2Sha256") return pbkdf2Of(kindSha256, secretOf(17, 16, taint), message, 2, 32);
	if (name == "blake2bKeyed") return blake2bOf(32, secretOf(18, 32, taint), message);
	if (name == "argon2i" || name == "argon2id") {
		const mode = name == "argon2i" ? Argon2Mode.Argon2i : Argon2Mode.Argon2id;
		const result = argon2Raw(secretOf(19, 16, taint), fixed(20, 16), 1, 64, 1, 32, mode);
		if (!result.ok) throw new Error(`argon2: ${result.error}`);
		return result.value;
	}
	if (name == "leakyBranch") {
		const s = secretOf(21, 32, taint);
		let acc: uint8 = 0;
		for (let r = 0; r < ((s[0] & 15) as int32); r++) acc = acc + message[r % message.length];
		const out = new Array<uint8>(32);
		for (let i = 0; i < 32; i++) out[i] = s[i] ^ acc;
		return out;
	}
	if (name == "leakyIndex") {
		const s = secretOf(22, 32, taint);
		const table = fixed(23, 32);
		const out = new Array<uint8>(32);
		for (let i = 0; i < 32; i++) out[i] = table[(s[i] & 31) as int32];
		return out;
	}
	if (name == "noop") {
		secretOf(24, 32, taint);
		return fixed(25, 32);
	}
	throw new Error(`unknown case ${name}`);
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
	return true;
}

function main(): int32 {
	const args = argv.slice(1);
	if (args.length == 1 && args[0] == "--list") {
		for (const c of cases) console.log(c);
		return 0;
	}
	const native = args.length == 2 && args[1] == "--native";
	if (args.length < 1 || !cases.includes(args[0]) || (args.length == 2 && !native)) {
		console.log(`usage: taintRun <case> [--native] | --list; unknown: ${args.join(" ")}`);
		return 10;
	}
	const name = args[0];
	if (!native && !onValgrind()) {
		console.log("not under Valgrind; pass --native to run the case without taint");
		return 11;
	}
	const expected = run(name, false);
	console.log(`STAGE native ok ${name} (${expected.length} bytes)`);
	if (native) return 0;
	const out = run(name, true);
	const tainted = undefinedBytes(out);
	declassify(out);
	if (tainted <= 0) {
		console.log(`taint never reached the output of ${name} (${tainted} of ${out.length} bytes undefined)`);
		return 14;
	}
	if (!sameBytes(out, expected)) {
		console.log(`the tainted run of ${name} changed its output`);
		return 15;
	}
	console.log(`STAGE taint ok ${name} (${tainted} of ${out.length} output bytes carried the secret)`);
	return 0;
}

const status = main();
if (status != 0) process.exit(status);
