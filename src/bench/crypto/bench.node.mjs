// Keep each row on node's synchronous call, its fastest form, also for the rows bench.ms times async or Sync. Node 24.1
// has no argon2, so that row is absent here. Node has no XChaCha20-Poly1305: its row seals with the
// IETF variant, which lacks only the one HChaCha20 block XChaCha adds per seal.

import crypto from "node:crypto";
import { bench } from "../harness.mjs";

let sink = 0;

function bytesOf(count) {
	const buf = Buffer.alloc(count);
	for (let i = 0; i < count; i++) buf[i] = (i * 31 + 7) & 255;
	return buf;
}

const b32 = bytesOf(32);
const b64 = bytesOf(64);
const b1k = bytesOf(1024);
const b64k = bytesOf(65536);
const b1m = bytesOf(1048576);
const digest = (algorithm, data) => crypto.createHash(algorithm).update(data).digest();

bench("sha256 digest 32 B", 0, () => { sink += digest("sha256", b32).length; });
bench("sha256 digest 1 KB", 1024, () => { sink += digest("sha256", b1k).length; });
bench("sha256 digest 64 KB", 65536, () => { sink += digest("sha256", b64k).length; });
bench("sha256 digest 1 MB", 1048576, () => { sink += digest("sha256", b1m).length; });
bench("sha512 digest 64 B", 0, () => { sink += digest("sha512", b64).length; });
bench("sha512 digest 1 MB", 1048576, () => { sink += digest("sha512", b1m).length; });
bench("sha256 digest 1 MB async", 1048576, () => { sink += digest("sha256", b1m).length; });
bench("sha1 digest 1 MB", 1048576, () => { sink += digest("sha1", b1m).length; });
bench("md5 digest 1 MB", 1048576, () => { sink += digest("md5", b1m).length; });
bench("blake2b-512 digest 1 MB", 1048576, () => { sink += digest("blake2b512", b1m).length; });
bench("hmac-sha256 32 B", 0, () => { sink += crypto.createHmac("sha256", b32).update(b32).digest().length; });
bench("pbkdf2-sha256 100k", 0, () => { sink += crypto.pbkdf2Sync("password", "salt", 100000, 32, "sha256").length; });
bench("hkdf-sha256 32 B", 0, () => { sink += crypto.hkdfSync("sha256", b32, b32, b32, 32).byteLength; });
bench("randomBytes 32 B", 0, () => { sink += crypto.randomBytes(32).length; });

const pkcs8 = (prefix, raw) => crypto.createPrivateKey({ key: Buffer.concat([Buffer.from(prefix, "hex"), raw]), format: "der", type: "pkcs8" });
const edKey = pkcs8("302e020100300506032b657004220420", b32);
const edPublic = crypto.createPublicKey(edKey);
const edSig = crypto.sign(null, b64, edKey);
bench("ed25519 sign 64 B", 0, () => { sink += crypto.sign(null, b64, edKey).length; });
bench("ed25519 signSync 64 B", 0, () => { sink += crypto.sign(null, b64, edKey).length; });
bench("ed25519 verify 64 B", 0, () => { if (crypto.verify(null, b64, edPublic, edSig)) sink += 1; });

const xKey = pkcs8("302e020100300506032b656e04220420", b32);
const xPublic = crypto.createPublicKey(xKey);
bench("x25519 shared", 0, () => { sink += crypto.diffieHellman({ privateKey: xKey, publicKey: xPublic }).length; });

function seal(algorithm, key, nonceLength, text) {
	const cipher = crypto.createCipheriv(algorithm, key, crypto.randomBytes(nonceLength), { authTagLength: 16 });
	const body = Buffer.concat([cipher.update(text), cipher.final()]);
	return body.length + cipher.getAuthTag().length;
}
function sealed(algorithm, key, text) {
	const nonce = crypto.randomBytes(12);
	const cipher = crypto.createCipheriv(algorithm, key, nonce, { authTagLength: 16 });
	return { nonce, body: Buffer.concat([cipher.update(text), cipher.final()]), tag: cipher.getAuthTag() };
}
function open(algorithm, key, box) {
	const decipher = crypto.createDecipheriv(algorithm, key, box.nonce, { authTagLength: 16 });
	decipher.setAuthTag(box.tag);
	return Buffer.concat([decipher.update(box.body), decipher.final()]).length;
}
bench("aes-256-gcm seal 1 MB", 1048576, () => { sink += seal("aes-256-gcm", b32, 12, b1m); });
const aesBox = sealed("aes-256-gcm", b32, b1m);
bench("aes-256-gcm open 1 MB", 1048576, () => { sink += open("aes-256-gcm", b32, aesBox); });
bench("aes-256-gcm sealSync 1 MB", 1048576, () => { sink += seal("aes-256-gcm", b32, 12, b1m); });
bench("aes-256-cbc encrypt 1 MB", 1048576, () => {
	const cipher = crypto.createCipheriv("aes-256-cbc", b32, b32.subarray(0, 16));
	sink += cipher.update(b1m).length + cipher.final().length;
});
bench("chacha20-poly1305 seal 1 MB", 1048576, () => { sink += seal("chacha20-poly1305", b32, 12, b1m); });
const chachaBox = sealed("chacha20-poly1305", b32, b1m);
bench("chacha20-poly1305 open 1 MB", 1048576, () => { sink += open("chacha20-poly1305", b32, chachaBox); });

const rsa = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const rsaSig = crypto.sign("sha256", b64, rsa.privateKey);
const oaep = { padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha256" };
const rsaSealed = crypto.publicEncrypt({ key: rsa.publicKey, ...oaep }, b32);
bench("rsa-2048 sign pkcs1 64 B", 0, () => { sink += crypto.sign("sha256", b64, rsa.privateKey).length; });
bench("rsa-2048 verify pkcs1 64 B", 0, () => { if (crypto.verify("sha256", b64, rsa.publicKey, rsaSig)) sink += 1; });
bench("rsa-2048 oaep decrypt 32 B", 0, () => { sink += crypto.privateDecrypt({ key: rsa.privateKey, ...oaep }, rsaSealed).length; });

const ec = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const ecSig = crypto.sign("sha256", b64, ec.privateKey);
bench("ecdsa-p256 sign 64 B", 0, () => { sink += crypto.sign("sha256", b64, ec.privateKey).length; });
bench("ecdsa-p256 verify 64 B", 0, () => { if (crypto.verify("sha256", b64, ec.publicKey, ecSig)) sink += 1; });
bench("ecdh-p256 shared", 0, () => { sink += crypto.diffieHellman({ privateKey: ec.privateKey, publicKey: ec.publicKey }).length; });

bench("sha256 stream 16x64 KB", 1048576, () => {
	const hasher = crypto.createHash("sha256");
	for (let i = 0; i < 16; i++) hasher.update(b64k);
	sink += hasher.digest().length;
});

if (sink < 0) console.log("unreachable", sink);
