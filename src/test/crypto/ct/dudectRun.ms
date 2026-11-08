// dudect timing run of the native crypto port: `dudectRun <case> <measurements> <batches> <seed> [--null]` times the
// case on a fixed secret (class 0) against a fresh random secret (class 1) with the pinned upstream statistics
// (src/test/crypto/harness/dudect, driven from dudectHost.c), the class drawn at random per measurement. `--null` draws
// both classes at random, so no difference exists. Driven by tools/crypto/ctDudect.sh; `dudectRun --list` prints the
// cases. Passing is "no leakage evidence within this bound", never a proof of constant time.
//
// Exit: 0 no leakage evidence, 20 leakage, 21 inconclusive, 10 usage.

import { argv } from "std/process";
import { x25519 } from "std/crypto/pure/x25519";
import { ed25519Sign, ed25519PublicFromSeed } from "std/crypto/pure/ed25519";
import { ecdsaSignRaw, ecdhShared, ecPublicPoint } from "std/crypto/pure/weierstrass";
import { p256 } from "std/crypto/pure/p256";
import { p384 } from "std/crypto/pure/p384";
import { hashOf } from "std/crypto/pure/hash";
import { hmacOf } from "std/crypto/pure/hmac";
import { kindSha256, kindSha512 } from "std/crypto/pure/state";
import { blake2bOf } from "std/crypto/pure/blake2b";
import { expandKey, gcmSealWithNonce, cbcEncrypt } from "std/crypto/pure/aes";
import { keyWords, xchachaSealInto } from "std/crypto/pure/chacha";
import { argon2Raw, Argon2Mode } from "std/crypto/pure/argon2";
import { pemDecode } from "std/crypto/pure/pem";
import { RsaPrivateData } from "std/crypto/pure/rsaKey";
import { rsaPrivateFromPkcs8, rsaSignPkcs1 } from "std/crypto/pure/rsa";
import { keyAPkcs8 } from "std/crypto/pure/rsaFixtures";
import { dudectRun } from "./dudect";

/** A deterministic, non-trivial input of `length` bytes for `seed`. */
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

function or(found: uint8[] | null, what: string): uint8[] {
	if (found == null) throw new Error(`${what} returned null`);
	return found;
}

const message: uint8[] = [0x6d, 0x65, 0x74, 0x61, 0x73, 0x63, 0x72, 0x69, 0x70, 0x74];
const nonce12: uint8[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
const iv16: uint8[] = [16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1];

/** Each case and the length of the secret dudect varies. */
const cases: string[] = [
	"x25519", "ed25519Sign", "p256Sign", "p256Ecdh", "p384Sign", "p384Ecdh", "rsaSignPkcs1", "aesGcmSeal",
	"aesCbcEncrypt", "xchachaSeal", "sha256", "hmacSha256", "blake2bKeyed", "argon2i", "leakyBranch",
];
const lengths: int32[] = [32, 32, 32, 32, 48, 48, 64, 32, 16, 32, 64, 32, 32, 16, 32];

let current = "";
let rsaKey: RsaPrivateData | null = null;
let p256Peer: uint8[] = [];
let p384Peer: uint8[] = [];

function compute(name: string, secret: uint8[]): uint8[] {
	if (name == "x25519") return x25519(secret, fixed(2, 32));
	if (name == "ed25519Sign") return ed25519Sign(secret, ed25519PublicFromSeed(secret), message);
	if (name == "p256Sign") return or(ecdsaSignRaw(p256, kindSha256, secret, hashOf(kindSha256, message)), name);
	if (name == "p384Sign") return or(ecdsaSignRaw(p384, kindSha512, secret, hashOf(kindSha512, message)), name);
	if (name == "p256Ecdh") return or(ecdhShared(p256, secret, p256Peer), name);
	if (name == "p384Ecdh") return or(ecdhShared(p384, secret, p384Peer), name);
	if (name == "rsaSignPkcs1") {
		const key = rsaKey;
		if (key == null) throw new Error("rsa key not loaded");
		return or(rsaSignPkcs1(key, "sha256", secret), name);
	}
	if (name == "aesGcmSeal") return [...gcmSealWithNonce(expandKey(secret), nonce12, fixed(9, 100), message)];
	if (name == "aesCbcEncrypt") return [...cbcEncrypt(expandKey(secret), iv16, fixed(11, 64))];
	if (name == "xchachaSeal") {
		const words = new Array<uint32>(8);
		const plain = fixed(13, 100);
		const sealed = new Array<uint8>(24 + plain.length + 16);
		for (let i = 0; i < 24; i++) sealed[i] = (i + 1) as uint8;
		keyWords(secret, words);
		xchachaSealInto(words, message, plain, sealed);
		return sealed;
	}
	if (name == "sha256") return hashOf(kindSha256, secret);
	if (name == "hmacSha256") return hmacOf(kindSha256, secret, message);
	if (name == "blake2bKeyed") return blake2bOf(32, secret, message);
	if (name == "argon2i") {
		const result = argon2Raw(secret, fixed(20, 16), 1, 64, 1, 32, Argon2Mode.Argon2i);
		if (!result.ok) throw new Error(`argon2: ${result.error}`);
		return result.value;
	}
	if (name == "leakyBranch") {
		let acc: uint8 = 0;
		for (let r = 0; r < ((secret[0] & 15) as int32) * 64; r++) acc = acc + message[r % message.length];
		const out = new Array<uint8>(32);
		for (let i = 0; i < 32; i++) out[i] = secret[i] ^ acc;
		return out;
	}
	throw new Error(`unknown case ${name}`);
}

/** dudect's do_one_computation: the current case on one input chunk, its output folded to a byte the host keeps. */
@exportName("msCtDudectCompute")
function computeChunk(data: Ptr<uint8>): uint8 {
	const length = lengths[cases.indexOf(current)];
	const secret = new Array<uint8>(length);
	for (let i = 0; i < length; i++) secret[i] = data[i];
	const out = compute(current, secret);
	let fold: uint8 = 0;
	for (const b of out) fold ^= b;
	return fold;
}

function parseCount(text: string): int64 {
	let value: int64 = 0;
	if (text.length == 0) return -1;
	for (let i = 0; i < text.length; i++) {
		const digit = text.charCodeAt(i) - 48;
		if (digit < 0 || digit > 9) return -1;
		value = value * 10 + digit;
	}
	return value;
}

function parseHex64(text: string): uint64 | null {
	if (text.length < 3 || text.length > 18 || !text.startsWith("0x")) return null;
	let value: uint64 = 0;
	for (let i = 2; i < text.length; i++) {
		const c = text.charCodeAt(i);
		const digit = c >= 48 && c <= 57 ? c - 48 : c >= 97 && c <= 102 ? c - 87 : -1;
		if (digit < 0) return null;
		value = (value << 4) | (digit as uint64);
	}
	return value;
}

function main(): int32 {
	const args = argv.slice(1);
	if (args.length == 1 && args[0] == "--list") {
		for (const c of cases) console.log(c);
		return 0;
	}
	const nullRun = args.length == 5 && args[4] == "--null";
	const measurements = args.length >= 4 ? parseCount(args[1]) : -1;
	const batches = args.length >= 4 ? parseCount(args[2]) : -1;
	const seed = args.length >= 4 ? parseHex64(args[3]) : null;
	if ((args.length != 4 && !nullRun) || !cases.includes(args[0]) || measurements < 1000 || measurements > 1000000
		|| batches < 2 || batches > 100000 || seed == null) {
		console.log(`usage: dudectRun <case> <measurements 1000..1000000> <batches 2..100000> <0xseed> [--null] | --list; got: ${args.join(" ")}`);
		return 10;
	}
	current = args[0];
	const block = pemDecode(keyAPkcs8);
	if (block != null) rsaKey = rsaPrivateFromPkcs8(block.der);
	p256Peer = or(ecPublicPoint(p256, fixed(6, 32)), "p256 peer");
	p384Peer = or(ecPublicPoint(p384, fixed(7, 48)), "p384 peer");
	const fixedInput = fixed(1, lengths[cases.indexOf(current)]);
	console.log(`STAGE warm ${current} (${compute(current, fixedInput).length} output bytes)`);
	console.log(`CONFIG case=${current} secretBytes=${fixedInput.length} measurementsPerBatch=${measurements} batches=${batches} null=${nullRun}`);
	return dudectRun(fixedInput, measurements, batches, seed, nullRun);
}

const status = main();
if (status != 0) process.exit(status);
