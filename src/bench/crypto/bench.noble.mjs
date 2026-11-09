// The rows of bench.ms on the noble libraries (@noble/hashes, @noble/curves, @noble/ciphers), the pure-JS reference the
// js-port arm is weighed against. run.sh installs them into MSBENCH_NOBLE. Each row is noble's synchronous call, also
// for the rows bench.ms times async. noble has no RSA, so those rows are absent here. ChaCha is XChaCha20-Poly1305,
// as std/crypto seals it.

import { bench } from "../harness.mjs";

const root = process.env.MSBENCH_NOBLE;
if (!root) throw new Error("bench.noble.mjs: set MSBENCH_NOBLE to the directory holding node_modules/@noble");
const noble = (path) => import(`${root}/node_modules/@noble/${path}`);

const { sha256, sha512 } = await noble("hashes/sha2.js");
const { sha1, md5 } = await noble("hashes/legacy.js");
const { blake2b } = await noble("hashes/blake2.js");
const { hmac } = await noble("hashes/hmac.js");
const { pbkdf2 } = await noble("hashes/pbkdf2.js");
const { hkdf } = await noble("hashes/hkdf.js");
const { argon2id } = await noble("hashes/argon2.js");
const { randomBytes } = await noble("hashes/utils.js");
const { ed25519, x25519 } = await noble("curves/ed25519.js");
const { p256 } = await noble("curves/nist.js");
const { gcm, cbc } = await noble("ciphers/aes.js");
const { xchacha20poly1305 } = await noble("ciphers/chacha.js");

let sink = 0;

function bytesOf(count) {
	const buf = new Uint8Array(count);
	for (let i = 0; i < count; i++) buf[i] = (i * 31 + 7) & 255;
	return buf;
}

const utf8 = (text) => new TextEncoder().encode(text);
const b32 = bytesOf(32);
const b64 = bytesOf(64);
const b1k = bytesOf(1024);
const b64k = bytesOf(65536);
const b1m = bytesOf(1048576);

bench("sha256 digest 32 B", 0, () => { sink += sha256(b32).length; });
bench("sha256 digest 1 KB", 1024, () => { sink += sha256(b1k).length; });
bench("sha256 digest 64 KB", 65536, () => { sink += sha256(b64k).length; });
bench("sha256 digest 1 MB", 1048576, () => { sink += sha256(b1m).length; });
bench("sha512 digest 64 B", 0, () => { sink += sha512(b64).length; });
bench("sha512 digest 1 MB", 1048576, () => { sink += sha512(b1m).length; });
bench("sha256 digest 1 MB async", 1048576, () => { sink += sha256(b1m).length; });
bench("sha1 digest 1 MB", 1048576, () => { sink += sha1(b1m).length; });
bench("md5 digest 1 MB", 1048576, () => { sink += md5(b1m).length; });
bench("blake2b-512 digest 1 MB", 1048576, () => { sink += blake2b(b1m, { dkLen: 64 }).length; });
bench("hmac-sha256 32 B", 0, () => { sink += hmac(sha256, b32, b32).length; });
const password = utf8("password");
const salt = utf8("salt");
bench("pbkdf2-sha256 100k", 0, () => { sink += pbkdf2(sha256, password, salt, { c: 100000, dkLen: 32 }).length; });
bench("hkdf-sha256 32 B", 0, () => { sink += hkdf(sha256, b32, b32, b32, 32).length; });
bench("randomBytes 32 B", 0, () => { sink += randomBytes(32).length; });
bench("argon2id t3 m4M p1", 0, () => { sink += argon2id(b32, b32, { t: 3, m: 4096, p: 1, dkLen: 32 }).length; });

const edPublic = ed25519.getPublicKey(b32);
const edSig = ed25519.sign(b64, b32);
if (!ed25519.verify(edSig, b64, edPublic)) throw new Error("ed25519 verify preflight failed");
bench("ed25519 sign 64 B", 0, () => { sink += ed25519.sign(b64, b32).length; });
bench("ed25519 signSync 64 B", 0, () => { sink += ed25519.sign(b64, b32).length; });
bench("ed25519 verify 64 B", 0, () => { if (ed25519.verify(edSig, b64, edPublic)) sink += 1; });

const xPublic = x25519.getPublicKey(b32);
bench("x25519 shared", 0, () => { sink += x25519.getSharedSecret(b32, xPublic).length; });

const nonce12 = b32.subarray(0, 12);
bench("aes-256-gcm seal 1 MB", 1048576, () => { sink += gcm(b32, randomBytes(12)).encrypt(b1m).length; });
const aesSealed = gcm(b32, nonce12).encrypt(b1m);
if (gcm(b32, nonce12).decrypt(aesSealed).length != b1m.length) throw new Error("aes-gcm open preflight failed");
bench("aes-256-gcm open 1 MB", 1048576, () => { sink += gcm(b32, nonce12).decrypt(aesSealed).length; });
bench("aes-256-gcm sealSync 1 MB", 1048576, () => { sink += gcm(b32, randomBytes(12)).encrypt(b1m).length; });
bench("aes-256-cbc encrypt 1 MB", 1048576, () => { sink += cbc(b32, b32.subarray(0, 16)).encrypt(b1m).length; });
const nonce24 = b32.subarray(0, 24);
bench("chacha20-poly1305 seal 1 MB", 1048576, () => { sink += xchacha20poly1305(b32, randomBytes(24)).encrypt(b1m).length; });
const chachaSealed = xchacha20poly1305(b32, nonce24).encrypt(b1m);
if (xchacha20poly1305(b32, nonce24).decrypt(chachaSealed).length != b1m.length) throw new Error("chacha20 open preflight failed");
bench("chacha20-poly1305 open 1 MB", 1048576, () => { sink += xchacha20poly1305(b32, nonce24).decrypt(chachaSealed).length; });

const ecSecret = p256.utils.randomSecretKey();
const ecPublic = p256.getPublicKey(ecSecret);
const ecSig = p256.sign(b64, ecSecret);
if (!p256.verify(ecSig, b64, ecPublic)) throw new Error("ecdsa verify preflight failed");
bench("ecdsa-p256 sign 64 B", 0, () => { sink += p256.sign(b64, ecSecret).length; });
bench("ecdsa-p256 verify 64 B", 0, () => { if (p256.verify(ecSig, b64, ecPublic)) sink += 1; });
bench("ecdh-p256 shared", 0, () => { sink += p256.getSharedSecret(ecSecret, ecPublic).length; });

bench("sha256 stream 16x64 KB", 1048576, () => {
	const hasher = sha256.create();
	for (let i = 0; i < 16; i++) hasher.update(b64k);
	sink += hasher.digest().length;
});

if (sink < 0) console.log("unreachable", sink);
