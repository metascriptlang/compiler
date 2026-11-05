// Run one binary at a time: a parallel job moves every number.

import { Buffer } from "std/core/buffer";
import { bench, benchAsync } from "../harness";
import { CryptoError, digest, digestSync, hmacSync, pbkdf2, hkdf, randomBytesSync, createHash } from "std/crypto";
import { blake2bSync } from "std/crypto/blake2b";
import { argon2HashRawSync } from "std/crypto/argon2";
import { Ed25519PrivateKey, sign as edSign, signSync as edSignSync, verify as edVerify } from "std/crypto/ed25519";
import { X25519PrivateKey, sharedSecret } from "std/crypto/x25519";
import { AesKey, seal as aesSeal, sealSync as aesSealSync, open as aesOpen, cbcEncrypt } from "std/crypto/aes";
import { ChaChaKey, seal as chachaSeal, open as chachaOpen } from "std/crypto/chacha20";
import { RsaPrivateKey, sign as rsaSign, verify as rsaVerify, encrypt as rsaEncrypt, decrypt as rsaDecrypt } from "std/crypto/rsa";
import { EcPrivateKey, ecdsaSign, ecdsaVerify, ecdh } from "std/crypto/ec";

let sink: number = 0;

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function bytesOf(count: int32): Buffer {
	const buf = Buffer.alloc(count);
	for (let i = 0; i < count; i++) buf.set(i, (i * 31 + 7) & 255);
	return buf;
}

const b32 = bytesOf(32);
const b64 = bytesOf(64);
const b1k = bytesOf(1024);
const b64k = bytesOf(65536);
const b1m = bytesOf(1048576);

bench("sha256 digest 32 B", 0, () => { sink += must(digestSync("sha256", b32)).length; });
bench("sha256 digest 1 KB", 1024, () => { sink += must(digestSync("sha256", b1k)).length; });
bench("sha256 digest 64 KB", 65536, () => { sink += must(digestSync("sha256", b64k)).length; });
bench("sha256 digest 1 MB", 1048576, () => { sink += must(digestSync("sha256", b1m)).length; });
bench("sha512 digest 64 B", 0, () => { sink += must(digestSync("sha512", b64)).length; });
bench("sha512 digest 1 MB", 1048576, () => { sink += must(digestSync("sha512", b1m)).length; });
await benchAsync("sha256 digest 1 MB async", 1048576, async () => { sink += must(await digest("sha256", b1m)).length; });
bench("sha1 digest 1 MB", 1048576, () => { sink += must(digestSync("sha1", b1m)).length; });
bench("md5 digest 1 MB", 1048576, () => { sink += must(digestSync("md5", b1m)).length; });
bench("blake2b-512 digest 1 MB", 1048576, () => { sink += must(blake2bSync(b1m, 64)).length; });
bench("hmac-sha256 32 B", 0, () => { sink += must(hmacSync("sha256", b32, b32)).length; });
await benchAsync("pbkdf2-sha256 100k", 0, async () => { sink += must(await pbkdf2("password", "salt", 100000, 32, "sha256")).length; });
await benchAsync("hkdf-sha256 32 B", 0, async () => { sink += must(await hkdf("sha256", b32, b32, b32, 32)).length; });
bench("randomBytes 32 B", 0, () => { sink += must(randomBytesSync(32)).length; });
bench("argon2id t3 m4M p1", 0, () => { sink += must(argon2HashRawSync(b32, b32, 3, 4096, 1, 32)).length; });

const edKey = must(await Ed25519PrivateKey.fromSeed(b32));
const edPublic = edKey.publicKey();
const edSig = must(await edSign(edKey, b64));
if (!(await edVerify(edPublic, edSig, b64))) throw new Error("ed25519 verify preflight failed");
await benchAsync("ed25519 sign 64 B", 0, async () => { sink += must(await edSign(edKey, b64)).length; });
bench("ed25519 signSync 64 B", 0, () => { sink += must(edSignSync(edKey, b64)).length; });
await benchAsync("ed25519 verify 64 B", 0, async () => { if (await edVerify(edPublic, edSig, b64)) sink += 1; });

const xKey = must(await X25519PrivateKey.fromRaw(b32));
const xPublic = xKey.publicKey();
await benchAsync("x25519 shared", 0, async () => { sink += must(await sharedSecret(xKey, xPublic)).length; });

const aesKey = must(AesKey.import(b32));
await benchAsync("aes-256-gcm seal 1 MB", 1048576, async () => { sink += must(await aesSeal(aesKey, b1m)).length; });
const aesSealed = must(await aesSeal(aesKey, b1m));
if (must(await aesOpen(aesKey, aesSealed)).length != b1m.length) throw new Error("aes-gcm open preflight failed");
await benchAsync("aes-256-gcm open 1 MB", 1048576, async () => { sink += must(await aesOpen(aesKey, aesSealed)).length; });
bench("aes-256-gcm sealSync 1 MB", 1048576, () => { sink += must(aesSealSync(aesKey, b1m)).length; });
await benchAsync("aes-256-cbc encrypt 1 MB", 1048576, async () => { sink += must(await cbcEncrypt(aesKey, b1m, b32.slice(0, 16))).length; });
const chachaKey = must(ChaChaKey.import(b32));
await benchAsync("chacha20-poly1305 seal 1 MB", 1048576, async () => { sink += must(await chachaSeal(chachaKey, b1m)).length; });
const chachaSealed = must(await chachaSeal(chachaKey, b1m));
if (must(await chachaOpen(chachaKey, chachaSealed)).length != b1m.length) throw new Error("chacha20 open preflight failed");
await benchAsync("chacha20-poly1305 open 1 MB", 1048576, async () => { sink += must(await chachaOpen(chachaKey, chachaSealed)).length; });

const rsaKey = must(await RsaPrivateKey.generate(2048));
const rsaPublic = rsaKey.publicKey();
const rsaSig = must(await rsaSign(rsaKey, b64));
const rsaSealed = must(await rsaEncrypt(rsaPublic, b32));
if (!(await rsaVerify(rsaPublic, b64, rsaSig))) throw new Error("rsa verify preflight failed");
if (must(await rsaDecrypt(rsaKey, rsaSealed)).length != 32) throw new Error("rsa oaep preflight failed");
await benchAsync("rsa-2048 sign pkcs1 64 B", 0, async () => { sink += must(await rsaSign(rsaKey, b64)).length; });
await benchAsync("rsa-2048 verify pkcs1 64 B", 0, async () => { if (await rsaVerify(rsaPublic, b64, rsaSig)) sink += 1; });
await benchAsync("rsa-2048 oaep decrypt 32 B", 0, async () => { sink += must(await rsaDecrypt(rsaKey, rsaSealed)).length; });

const ecKey = must(await EcPrivateKey.generate("p256"));
const ecPublic = ecKey.publicKey();
const ecSig = must(await ecdsaSign(ecKey, b64));
if (!(await ecdsaVerify(ecPublic, b64, ecSig))) throw new Error("ecdsa verify preflight failed");
await benchAsync("ecdsa-p256 sign 64 B", 0, async () => { sink += must(await ecdsaSign(ecKey, b64)).length; });
await benchAsync("ecdsa-p256 verify 64 B", 0, async () => { if (await ecdsaVerify(ecPublic, b64, ecSig)) sink += 1; });
await benchAsync("ecdh-p256 shared", 0, async () => { sink += must(await ecdh(ecKey, ecPublic)).length; });

bench("sha256 stream 16x64 KB", 1048576, () => {
	const hasher = createHash("sha256");
	for (let i = 0; i < 16; i++) hasher.update(b64k);
	sink += hasher.digest().length;
});

if (sink < 0) console.log("unreachable", sink);
