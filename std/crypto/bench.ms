// std/crypto throughput and latency on the C backend, one row per operation.
//
//   msc build std/crypto/bench.ms --release --output=out/cryptoBench && nice -n 10 out/cryptoBench
//
// Each row loops its operation until a round lasts at least 250 ms and runs 3 rounds; it prints the
// median and the spread (max - min) / median, then the target. Targets are Node 24 on an M3 Max
// (2026-11-01); a row passes when it meets its target. Run one binary at a time: a parallel job
// moves every number.

import { Buffer } from "std/core/buffer";
import { CryptoError, digestSync, hmacSync, pbkdf2, hkdf, randomBytesSync, createHash } from "std/crypto";
import { Ed25519PrivateKey, sign as edSign, verify as edVerify } from "std/crypto/ed25519";
import { X25519PrivateKey, sharedSecret } from "std/crypto/x25519";
import { AesKey, seal as aesSeal } from "std/crypto/aes";
import { ChaChaKey, seal as chachaSeal } from "std/crypto/chacha20";

const MIN_ROUND_MS = 250.0;
const ROUNDS = 3;

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

// Milliseconds per call of `op`, one round of at least MIN_ROUND_MS.
function round(op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed / calls;
		calls = (elapsed < 1.0 ? calls * 16.0 : Math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed))) as int32;
	}
}

function pad(text: string, width: number): string {
	let out = text;
	while (out.length < width) out = out + " ";
	return out;
}

function fixed(value: number, digits: number): string {
	const scale = Math.pow(10, digits);
	return (Math.round(value * scale) / scale).toString();
}

// `perCallBytes > 0` reports MB/s against `target` (a floor); 0 reports us/op against `target` (a ceiling).
// `target` 0 prints no target.
function bench(name: string, perCallBytes: number, target: number, op: () => void): void {
	const rates: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		const ms = round(op);
		rates.push(perCallBytes > 0 ? perCallBytes / ms / 1000.0 : ms * 1000.0);
	}
	rates.sort((a, b) => a - b);
	const median = rates[1];
	const spread = (rates[2] - rates[0]) / median * 100.0;
	const unit = perCallBytes > 0 ? "MB/s" : "us/op";
	let verdict = "";
	if (target > 0) {
		const ok = perCallBytes > 0 ? median >= target : median <= target;
		const bound = perCallBytes > 0 ? ">= " : "<= ";
		verdict = "  target " + bound + target.toString() + (ok ? "  ok" : "  MISS");
	}
	console.log(pad(name, 28) + pad(fixed(median, 3) + " " + unit, 18) + "spread " + fixed(spread, 1) + "%" + verdict);
}

const b32 = bytesOf(32);
const b64 = bytesOf(64);
const b1k = bytesOf(1024);
const b64k = bytesOf(65536);
const b1m = bytesOf(1048576);

bench("sha256 digest 32 B", 0, 0.57, () => { sink += must(digestSync("sha256", b32)).length; });
bench("sha256 digest 1 KB", 1024, 0, () => { sink += must(digestSync("sha256", b1k)).length; });
bench("sha256 digest 64 KB", 65536, 0, () => { sink += must(digestSync("sha256", b64k)).length; });
bench("sha256 digest 1 MB", 1048576, 2667, () => { sink += must(digestSync("sha256", b1m)).length; });
bench("sha512 digest 64 B", 0, 0, () => { sink += must(digestSync("sha512", b64)).length; });
bench("sha512 digest 1 MB", 1048576, 0, () => { sink += must(digestSync("sha512", b1m)).length; });
bench("hmac-sha256 32 B", 0, 2.1, () => { sink += must(hmacSync("sha256", b32, b32)).length; });
await benchAsync("pbkdf2-sha256 100k", 0, 18500, async () => { sink += must(await pbkdf2("password", "salt", 100000, 32, "sha256")).length; });
await benchAsync("hkdf-sha256 32 B", 0, 0, async () => { sink += must(await hkdf("sha256", b32, b32, b32, 32)).length; });
bench("randomBytes 32 B", 0, 0, () => { sink += must(randomBytesSync(32)).length; });

async function roundAsync(op: () => Promise<void>): Promise<number> {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) await op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed / calls;
		calls = (elapsed < 1.0 ? calls * 16.0 : Math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed))) as int32;
	}
}

async function benchAsync(name: string, perCallBytes: number, target: number, op: () => Promise<void>): Promise<void> {
	const rates: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		const ms = await roundAsync(op);
		rates.push(perCallBytes > 0 ? perCallBytes / ms / 1000.0 : ms * 1000.0);
	}
	rates.sort((a, b) => a - b);
	const median = rates[1];
	const spread = (rates[2] - rates[0]) / median * 100.0;
	const unit = perCallBytes > 0 ? "MB/s" : "us/op";
	let verdict = "";
	if (target > 0) {
		const ok = perCallBytes > 0 ? median >= target : median <= target;
		const bound = perCallBytes > 0 ? ">= " : "<= ";
		verdict = "  target " + bound + target.toString() + (ok ? "  ok" : "  MISS");
	}
	console.log(pad(name, 28) + pad(fixed(median, 3) + " " + unit, 18) + "spread " + fixed(spread, 1) + "%" + verdict);
}

const edKey = must(await Ed25519PrivateKey.fromSeed(b32));
const edPublic = edKey.publicKey();
const edSig = must(await edSign(edKey, b64));
await benchAsync("ed25519 sign 64 B", 0, 37, async () => { sink += must(await edSign(edKey, b64)).length; });
await benchAsync("ed25519 verify 64 B", 0, 84, async () => { if (await edVerify(edPublic, edSig, b64)) sink += 1; });

const xKey = must(await X25519PrivateKey.fromRaw(b32));
const xPublic = xKey.publicKey();
await benchAsync("x25519 shared", 0, 38, async () => { sink += must(await sharedSecret(xKey, xPublic)).length; });

const aesKey = must(AesKey.import(b32));
await benchAsync("aes-256-gcm seal 1 MB", 1048576, 4950, async () => { sink += must(await aesSeal(aesKey, b1m)).length; });
const chachaKey = must(ChaChaKey.import(b32));
await benchAsync("chacha20-poly1305 seal 1 MB", 1048576, 0, async () => { sink += must(await chachaSeal(chachaKey, b1m)).length; });

bench("sha256 stream 16x64 KB", 1048576, 0, () => {
	const hasher = createHash("sha256");
	for (let i = 0; i < 16; i++) hasher.update(b64k);
	sink += hasher.digest().length;
});

if (sink < 0) console.log("unreachable", sink);
