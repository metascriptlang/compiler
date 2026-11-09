import { Buffer } from "std/core/buffer";
import { argv } from "std/process";
import { hmacSync as nativeHmac } from "../../../test/crypto/oracle";
import { hmacSync as pureHmac } from "std/crypto/pure/coreNative";
import { CryptoError } from "std/crypto/errors";

let sink: number = 0;

function digestOf(result: Result<Buffer, CryptoError>): Buffer {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function nsPerCall(operation: () => Buffer): number {
	let calls: int32 = 256;
	while (true) {
		const start = performance.now();
		for (let call = 0; call < calls; call++) {
			sink += operation()[0];
		}
		const elapsed = performance.now() - start;
		if (elapsed >= 20) return elapsed * 1000000 / calls;
		if (calls >= 16777216) {
			throw new Error("HMAC timer did not reach 20 ms");
		}
		calls *= 4;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

const keyText = "0123456789abcdef".repeat(2);
const dataText = "0123456789abcdef".repeat(4);
const key = Buffer.fromString(keyText, "utf8");
const data = Buffer.fromString(dataText, "utf8");
if (key.length != 32 || data.length != 64) {
	throw new Error("HMAC benchmark requires a 32-byte key and 64-byte message");
}
const names = ["native-bytes", "pure-bytes", "native-text", "pure-text"];
const operations: (() => Buffer)[] = [
	() => digestOf(nativeHmac("sha256", key, data)),
	() => digestOf(pureHmac("sha256", key, data)),
	() => digestOf(nativeHmac("sha256", keyText, dataText)),
	() => digestOf(pureHmac("sha256", keyText, dataText)),
];
const expected = operations[0]().encodeHex();
for (let index = 0; index < operations.length; index++) {
	const digest = operations[index]();
	if (digest.length != 32 || digest.encodeHex() != expected) {
		throw new Error("HMAC benchmark mismatch: " + names[index]);
	}
}
console.log(`hmac-sha256 key=32 B data=64 B checksum=${expected}`);

if (argv.includes("--measure")) {
	const samples: number[][] = [[], [], [], []];
	for (let round = 0; round < 5; round++) {
		for (let step = 0; step < operations.length; step++) {
			const index = round % 2 == 0 ? step : 3 - step;
			samples[index].push(nsPerCall(operations[index]));
		}
	}
	const medians: number[] = [];
	for (let index = 0; index < operations.length; index++) {
		const ns = median(samples[index]);
		medians.push(ns);
		console.log(`${names[index]} ${ns.toFixed(1)} ns/call`);
	}
	console.log(`pure/native bytes=${(medians[1] / medians[0]).toFixed(3)}`);
	console.log(`pure/native text=${(medians[3] / medians[2]).toFixed(3)}`);
	console.log(`pure text/bytes=${(medians[3] / medians[1]).toFixed(3)}`);
	console.log(`sink=${sink}`);
}
