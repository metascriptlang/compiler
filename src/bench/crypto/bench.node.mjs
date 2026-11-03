// Keep each row on node's synchronous call, its fastest form. Node has no XChaCha20-Poly1305: its row seals with the
// IETF variant, which lacks only the one HChaCha20 block XChaCha adds per seal.

import crypto from "node:crypto";

const MIN_ROUND_MS = 250.0;
const ROUNDS = 3;
let sink = 0;

function bytesOf(count) {
	const buf = Buffer.alloc(count);
	for (let i = 0; i < count; i++) buf[i] = (i * 31 + 7) & 255;
	return buf;
}

function round(op) {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed / calls;
		calls = elapsed < 1.0 ? calls * 16 : Math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed));
	}
}

function fixed(value, digits) {
	const scale = Math.pow(10, digits);
	return (Math.round(value * scale) / scale).toString();
}

function bench(name, perCallBytes, op) {
	const rates = [];
	for (let r = 0; r < ROUNDS; r++) {
		const ms = round(op);
		rates.push(perCallBytes > 0 ? perCallBytes / ms / 1000.0 : ms * 1000.0);
	}
	rates.sort((a, b) => a - b);
	const median = rates[1];
	const spread = (rates[2] - rates[0]) / median * 100.0;
	const unit = perCallBytes > 0 ? "MB/s" : "us/op";
	console.log(name.padEnd(28) + (fixed(median, 3) + " " + unit).padEnd(18) + "spread " + fixed(spread, 1) + "%");
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
bench("hmac-sha256 32 B", 0, () => { sink += crypto.createHmac("sha256", b32).update(b32).digest().length; });
bench("pbkdf2-sha256 100k", 0, () => { sink += crypto.pbkdf2Sync("password", "salt", 100000, 32, "sha256").length; });
bench("hkdf-sha256 32 B", 0, () => { sink += crypto.hkdfSync("sha256", b32, b32, b32, 32).byteLength; });
bench("randomBytes 32 B", 0, () => { sink += crypto.randomBytes(32).length; });

const pkcs8 = (prefix, raw) => crypto.createPrivateKey({ key: Buffer.concat([Buffer.from(prefix, "hex"), raw]), format: "der", type: "pkcs8" });
const edKey = pkcs8("302e020100300506032b657004220420", b32);
const edPublic = crypto.createPublicKey(edKey);
const edSig = crypto.sign(null, b64, edKey);
bench("ed25519 sign 64 B", 0, () => { sink += crypto.sign(null, b64, edKey).length; });
bench("ed25519 verify 64 B", 0, () => { if (crypto.verify(null, b64, edPublic, edSig)) sink += 1; });

const xKey = pkcs8("302e020100300506032b656e04220420", b32);
const xPublic = crypto.createPublicKey(xKey);
bench("x25519 shared", 0, () => { sink += crypto.diffieHellman({ privateKey: xKey, publicKey: xPublic }).length; });

function seal(algorithm, key, nonceLength, text) {
	const cipher = crypto.createCipheriv(algorithm, key, crypto.randomBytes(nonceLength), { authTagLength: 16 });
	const body = Buffer.concat([cipher.update(text), cipher.final()]);
	return body.length + cipher.getAuthTag().length;
}
bench("aes-256-gcm seal 1 MB", 1048576, () => { sink += seal("aes-256-gcm", b32, 12, b1m); });
bench("chacha20-poly1305 seal 1 MB", 1048576, () => { sink += seal("chacha20-poly1305", b32, 12, b1m); });

bench("sha256 stream 16x64 KB", 1048576, () => {
	const hasher = crypto.createHash("sha256");
	for (let i = 0; i < 16; i++) hasher.update(b64k);
	sink += hasher.digest().length;
});

if (sink < 0) console.log("unreachable", sink);
