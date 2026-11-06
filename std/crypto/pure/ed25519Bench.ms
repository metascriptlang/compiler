/**
 * Pure Ed25519 against std/crypto/ed25519 (Monocypher on C): sign and verify
 * ops/s on the same inputs, the two sides interleaved, median of the rounds.
 * Build with --danger.
 */
import {
	Ed25519PrivateKey,
	signSync,
	verifySync,
} from "std/crypto/oracle/ed25519";
import { ed25519PublicFromSeed, ed25519Sign, ed25519Verify } from "./ed25519";

const rounds = 7;
const operations = 300;

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

function message(length: int32): uint8[] {
	const out = new Array<uint8>(length);
	for (let i = 0; i < length; i++) out[i] = ((i * 7 + 3) & 255) as uint8;
	return out;
}

function opsPerSecond(start: number): number {
	return (operations * 1000) / (performance.now() - start);
}

function bench(length: int32): void {
	const seed = message(32);
	const text = message(length);
	const publicKey = ed25519PublicFromSeed(seed);
	const signature = ed25519Sign(seed, publicKey, text);
	const key = Ed25519PrivateKey.fromSeedSync(seed.slice(0));
	if (!key.ok) return;
	const vendorPublic = key.value.publicKey();
	const pureSign: number[] = [];
	const vendorSign: number[] = [];
	const pureVerify: number[] = [];
	const vendorVerify: number[] = [];
	let checks = 0;
	for (let round = 0; round < rounds; round++) {
		let start = performance.now();
		for (let i = 0; i < operations; i++) {
			checks += ed25519Sign(seed, publicKey, text).length;
		}
		pureSign.push(opsPerSecond(start));
		start = performance.now();
		for (let i = 0; i < operations; i++) {
			const s = signSync(key.value, text);
			if (s.ok) checks += s.value.length;
		}
		vendorSign.push(opsPerSecond(start));
		start = performance.now();
		for (let i = 0; i < operations; i++) {
			if (ed25519Verify(publicKey, signature, text)) checks++;
		}
		pureVerify.push(opsPerSecond(start));
		start = performance.now();
		for (let i = 0; i < operations; i++) {
			if (verifySync(vendorPublic, signature, text)) checks++;
		}
		vendorVerify.push(opsPerSecond(start));
	}
	const ps = median(pureSign);
	const vs = median(vendorSign);
	const pv = median(pureVerify);
	const vv = median(vendorVerify);
	console.log(
		`${length} B: sign pure ${ps.toFixed(0)}/s ` +
			`vendor ${vs.toFixed(0)}/s ratio ${(ps / vs).toFixed(2)}; ` +
			`verify pure ${pv.toFixed(0)}/s ` +
			`vendor ${vv.toFixed(0)}/s ratio ${(pv / vv).toFixed(2)} (${checks})`,
	);
}

bench(64);
bench(1024);
