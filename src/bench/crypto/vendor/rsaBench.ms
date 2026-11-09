// The pure RSA against the public std/crypto/rsa surface (mbedTLS) on C, one row per operation on a 2048-bit and a
// 3072-bit key.
//
//   msc build src/bench/crypto/vendor/rsaBench.ms --danger --output=out/bench && nice -n 10 out/bench
//
// Each round times the pure call and then the vendor call, each looped for at least ROUND_MS; a row prints the median
// operations per second of both over ROUNDS rounds and pure / vendor time (below 1 is pure faster). Key generation
// is random in its cost, so its row is the median of KEYGEN_RUNS single runs per side; the mean ratio steadies it.

import {
	RsaPrivateKey,
	CryptoError,
	signSync,
	verifySync,
	encryptSync,
	decryptSync,
} from "../../../test/crypto/oracle/rsa";
import { pemDecode } from "std/crypto/pure/pem";
import {
	rsaPrivateFromPkcs8,
	rsaPublicOf,
	rsaGenerate,
	rsaSignPkcs1,
	rsaVerifyPkcs1,
	rsaOaepEncrypt,
	rsaOaepDecrypt,
} from "std/crypto/pure/rsa";
import { keyAPkcs8, key3072Pkcs8 } from "std/crypto/pure/rsaFixtures";

const ROUND_MS = 150.0;
const ROUNDS = 3;
const KEYGEN_RUNS = 15;

let sink: int32 = 0;

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function msPerCall(op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= ROUND_MS) return elapsed / calls;
		calls = calls * 2;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0);
	sorted.sort((a, b) => a - b);
	return sorted[(sorted.length / 2) as int32];
}

function mean(values: number[]): number {
	let sum = 0.0;
	for (const value of values) sum += value;
	return sum / values.length;
}

function fixed(value: number): string {
	return (Math.round(value * 1000.0) / 1000.0).toString();
}

function row(
	name: string,
	rounds: int32,
	pure: () => number,
	vendor: () => number,
): void {
	const pureMs: number[] = [];
	const vendorMs: number[] = [];
	for (let r = 0; r < rounds; r++) {
		pureMs.push(pure());
		vendorMs.push(vendor());
	}
	const p = median(pureMs);
	const v = median(vendorMs);
	console.log(
		`${name}: pure ${fixed(1000.0 / p)} op/s (${fixed(p)} ms), vendor ${fixed(1000.0 / v)} op/s (${fixed(v)} ms), pure/vendor ${fixed(p / v)}, mean ratio ${fixed(mean(pureMs) / mean(vendorMs))}`,
	);
}

function once(op: () => void): number {
	const start = performance.now();
	op();
	return performance.now() - start;
}

function benchKey(bits: int32, pem: string, keygenRuns: int32): void {
	const block = pemDecode(pem);
	const pure = block == null ? null : rsaPrivateFromPkcs8(block.der);
	if (pure == null) throw new Error("fixture key does not parse");
	const pub = rsaPublicOf(pure);
	const vendor = must(RsaPrivateKey.importPemSync(pem));
	const vendorPublic = vendor.publicKey();
	const message: uint8[] = [];
	for (let i = 0; i < 64; i++) message.push((i * 31 + 7) as uint8);
	const signature = rsaSignPkcs1(pure, "sha256", message);
	const sealed = rsaOaepEncrypt(pub, message);
	if (signature == null || sealed == null) throw new Error("pure setup failed");

	row(
		`sign pkcs1 sha256 ${bits}`,
		ROUNDS,
		() =>
			msPerCall(() => {
				const s = rsaSignPkcs1(pure, "sha256", message);
				if (s != null) sink += s[0] as int32;
			}),
		() =>
			msPerCall(() => {
				sink += must(
					signSync(vendor, message, "sha256", "pkcs1v15"),
				)[0] as int32;
			}),
	);
	row(
		`verify pkcs1 sha256 ${bits}`,
		ROUNDS,
		() =>
			msPerCall(() => {
				if (rsaVerifyPkcs1(pub, "sha256", message, signature)) sink += 1;
			}),
		() =>
			msPerCall(() => {
				if (
					verifySync(vendorPublic, message, signature, "sha256", "pkcs1v15")
				) sink += 1;
			}),
	);
	row(
		`decrypt oaep sha256 ${bits}`,
		ROUNDS,
		() =>
			msPerCall(() => {
				const opened = rsaOaepDecrypt(pure, sealed);
				if (opened != null) sink += opened.length;
			}),
		() =>
			msPerCall(() => {
				sink += must(decryptSync(vendor, sealed)).length;
			}),
	);
	row(
		`encrypt oaep sha256 ${bits}`,
		ROUNDS,
		() =>
			msPerCall(() => {
				const c = rsaOaepEncrypt(pub, message);
				if (c != null) sink += c[0] as int32;
			}),
		() =>
			msPerCall(() => {
				sink += must(encryptSync(vendorPublic, message))[0] as int32;
			}),
	);
	row(
		`generate ${bits}`,
		keygenRuns,
		() =>
			once(() => {
				sink += rsaGenerate(bits).n.length;
			}),
		() =>
			once(() => {
				sink += must(RsaPrivateKey.generateSync(bits)).exportPemSync().ok
					? 1
					: 0;
			}),
	);
}

benchKey(2048, keyAPkcs8, KEYGEN_RUNS);
benchKey(3072, key3072Pkcs8, 25);
console.log(`sink ${sink}`);
