// The pure AES against the public std/crypto/aes surface on C, one row per operation and size.
//
//   msc build std/crypto/pure/aesBench.ms --danger --output=out/bench && nice -n 10 out/bench
//
// Each round times the pure call and then the vendor call, each looped for at least ROUND_MS; a row prints the median
// ns/byte of both over ROUNDS rounds and pure / vendor (below 1 is pure faster).

import { Buffer } from "std/core/buffer";
import { expandKey, expandKeyDecrypt, gcmSealWithNonce, gcmOpen, cbcEncrypt, cbcDecrypt } from "./aes";
import { AesKey, CryptoError, sealSync, openSync, cbcEncryptSync, cbcDecryptSync } from "../oracle/aes";

const ROUND_MS = 60.0;
const ROUNDS = 5;

let sink: int32 = 0;

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function patterned(size: int32): Buffer {
	const out = Buffer.alloc(size);
	for (let i = 0; i < size; i++) out[i] = ((i * 31 + 7) & 0xff) as uint8;
	return out;
}

function nsPerCall(op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= ROUND_MS) return (elapsed * 1000000.0) / calls;
		calls = calls * 4;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0);
	sorted.sort((a, b) => a - b);
	return sorted[(sorted.length / 2) as int32];
}

function fixed(value: number): string {
	return (Math.round(value * 1000.0) / 1000.0).toString();
}

function row(name: string, size: int32, pure: () => void, vendor: () => void): void {
	const pureNs: number[] = [];
	const vendorNs: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		pureNs.push(nsPerCall(pure) / size);
		vendorNs.push(nsPerCall(vendor) / size);
	}
	const p = median(pureNs);
	const v = median(vendorNs);
	console.log(`${name} ${size} B: pure ${fixed(p)} ns/B, vendor ${fixed(v)} ns/B, pure/vendor ${fixed(p / v)}`);
}

const raw = patterned(32);
const key = must(AesKey.import(raw));
const xk = expandKey(raw);
const xkD = expandKeyDecrypt(raw);
const iv = patterned(16);
const aad = patterned(13);

for (const size of [64, 1024, 65536]) {
	const plain = patterned(size);
	const sealed = must(sealSync(key, plain, aad));
	const nonce = sealed.slice(0, 12);
	const cipher = must(cbcEncryptSync(key, plain, iv));
	row("gcm seal", size, () => { sink += gcmSealWithNonce(xk, nonce, plain, aad).length; }, () => { sink += must(sealSync(key, plain, aad)).length; });
	row("gcm open", size, () => { const out = gcmOpen(xk, sealed, aad); if (out != null) sink += out.length; }, () => { sink += must(openSync(key, sealed, aad)).length; });
	row("cbc encrypt", size, () => { sink += cbcEncrypt(xk, iv, plain).length; }, () => { sink += must(cbcEncryptSync(key, plain, iv)).length; });
	row("cbc decrypt", size, () => { const out = cbcDecrypt(xkD, iv, cipher); if (out != null) sink += out.length; }, () => { sink += must(cbcDecryptSync(key, cipher, iv)).length; });
}
console.log(`sink ${sink}`);
