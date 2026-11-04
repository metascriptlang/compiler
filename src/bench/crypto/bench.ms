// Run one binary at a time: a parallel job moves every number.

import { Buffer } from "std/core/buffer";
import { bench, benchAsync } from "../harness";
import { CryptoError, digestSync, hmacSync, pbkdf2, hkdf, randomBytesSync, createHash } from "std/crypto";
import { Ed25519PrivateKey, sign as edSign, verify as edVerify } from "std/crypto/ed25519";
import { X25519PrivateKey, sharedSecret } from "std/crypto/x25519";
import { AesKey, seal as aesSeal } from "std/crypto/aes";
import { ChaChaKey, seal as chachaSeal } from "std/crypto/chacha20";

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
bench("hmac-sha256 32 B", 0, () => { sink += must(hmacSync("sha256", b32, b32)).length; });
await benchAsync("pbkdf2-sha256 100k", 0, async () => { sink += must(await pbkdf2("password", "salt", 100000, 32, "sha256")).length; });
await benchAsync("hkdf-sha256 32 B", 0, async () => { sink += must(await hkdf("sha256", b32, b32, b32, 32)).length; });
bench("randomBytes 32 B", 0, () => { sink += must(randomBytesSync(32)).length; });

const edKey = must(await Ed25519PrivateKey.fromSeed(b32));
const edPublic = edKey.publicKey();
const edSig = must(await edSign(edKey, b64));
await benchAsync("ed25519 sign 64 B", 0, async () => { sink += must(await edSign(edKey, b64)).length; });
await benchAsync("ed25519 verify 64 B", 0, async () => { if (await edVerify(edPublic, edSig, b64)) sink += 1; });

const xKey = must(await X25519PrivateKey.fromRaw(b32));
const xPublic = xKey.publicKey();
await benchAsync("x25519 shared", 0, async () => { sink += must(await sharedSecret(xKey, xPublic)).length; });

const aesKey = must(AesKey.import(b32));
await benchAsync("aes-256-gcm seal 1 MB", 1048576, async () => { sink += must(await aesSeal(aesKey, b1m)).length; });
const chachaKey = must(ChaChaKey.import(b32));
await benchAsync("chacha20-poly1305 seal 1 MB", 1048576, async () => { sink += must(await chachaSeal(chachaKey, b1m)).length; });

bench("sha256 stream 16x64 KB", 1048576, () => {
	const hasher = createHash("sha256");
	for (let i = 0; i < 16; i++) hasher.update(b64k);
	sink += hasher.digest().length;
});

if (sink < 0) console.log("unreachable", sink);
