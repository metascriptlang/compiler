// Every std/crypto result that is bytes is a Buffer: its length counts bytes (a string holding a
// digest or a ciphertext does not), and a Buffer feeds straight back into the next call.
//
// @stdout: sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 32
// @stdout: hmac f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
// @stdout: pbkdf2 120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b
// @stdout: hkdf 3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865
// @stdout: streaming ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 32
// @stdout: random 16 true
// @stdout: hex 3 ff00fe /wD+
// @stdout: hex 3
// @stdout: blake2b bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319 32
// @stdout: ed25519 d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a 64 e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b true true
// @stdout: x25519 8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a true
// @stdout: aes 42 true false
// @stdout: chacha 54 true false
// @stdout: cbc 16 true
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over mbedTLS and Monocypher); there is no .jms
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, hashBuffer, hmacBuffer, pbkdf2, hkdf, createHash, randomBytes, fromHex, fromBase64, toBase64, toHex } from "std/crypto";
import { blake2b } from "std/crypto/blake2b";
import { ed25519FromSeed, ed25519PublicKey, ed25519ToSeed, ed25519Sign, ed25519Verify } from "std/crypto/ed25519";
import { x25519PublicKey, x25519SharedSecret } from "std/crypto/x25519";
import { seal, open, cbcEncrypt, cbcDecrypt } from "std/crypto/aes";
import { chacha20Seal, chacha20Open } from "std/crypto/chacha20";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

const digest: Buffer = must(hashBuffer("sha256", "abc"));
console.log("sha256", toHex(digest), digest.length);

const mac: Buffer = must(hmacBuffer("sha256", "key", "The quick brown fox jumps over the lazy dog"));
console.log("hmac", toHex(mac));

const derived: Buffer = must(pbkdf2("password", "salt", 1, 32, "sha256"));
console.log("pbkdf2", toHex(derived));

const ikm = fromHex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
const salt = fromHex("000102030405060708090a0b0c");
const info = fromHex("f0f1f2f3f4f5f6f7f8f9");
console.log("hkdf", toHex(must(hkdf("sha256", ikm, salt, info, 42))));

const hasher = createHash("sha256");
hasher.update("a");
hasher.update(fromHex("6263"));
const streamed: Buffer = hasher.digestBuffer();
console.log("streaming", toHex(streamed), streamed.length);

const random: Buffer = must(randomBytes(16));
console.log("random", random.length, Buffer.compare(random, must(randomBytes(16))) != 0);

const binary = fromHex("ff00fe");
console.log("hex", binary.length, toHex(binary), toBase64(binary));
console.log("hex", fromBase64("/wD+").length);

const blake: Buffer = blake2b("abc", 32);
console.log("blake2b", toHex(blake), blake.length);

const seed = fromHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
const secret: Buffer = must(ed25519FromSeed(seed));
const pub: Buffer = must(ed25519PublicKey(secret));
const sig: Buffer = must(ed25519Sign(secret, ""));
console.log("ed25519", toHex(pub), secret.length, toHex(sig), ed25519Verify(sig, pub, ""), Buffer.compare(must(ed25519ToSeed(secret)), seed) == 0);

const alicePrivate = fromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
const bobPrivate = fromHex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
const alicePublic = must(x25519PublicKey(alicePrivate));
const bobPublic = must(x25519PublicKey(bobPrivate));
console.log("x25519", toHex(alicePublic), Buffer.compare(must(x25519SharedSecret(alicePrivate, bobPublic)), must(x25519SharedSecret(bobPrivate, alicePublic))) == 0);

const key16 = fromHex("000102030405060708090a0b0c0d0e0f");
const sealed: Buffer = must(seal(key16, "attack at dawn", "hdr"));
const opened: Buffer = must(open(key16, sealed, "hdr"));
const forged = open(key16, fromHex("00".repeat(sealed.length)), "hdr");
console.log("aes", sealed.length, opened.asString() == "attack at dawn", forged.ok);

const key32 = fromHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
const chacha: Buffer = must(chacha20Seal(key32, "attack at dawn", "hdr"));
const chachaOpened: Buffer = must(chacha20Open(key32, chacha, "hdr"));
const chachaForged = chacha20Open(key32, chacha, "other");
console.log("chacha", chacha.length, chachaOpened.asString() == "attack at dawn", chachaForged.ok);

const iv = fromHex("101112131415161718191a1b1c1d1e1f");
const cbc: Buffer = must(cbcEncrypt(key16, "attack at dawn", iv));
console.log("cbc", cbc.length, must(cbcDecrypt(key16, cbc, iv)).asString() == "attack at dawn");
