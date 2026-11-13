// The MetaScript crypto core against the vendor-backed std/crypto surface, C backend.
//
//   msc build src/bench/crypto/vendor/coreBench.ms --danger --output=out/coreBench && out/coreBench
//
// Each row runs the pure and the vendor operation in alternating rounds and prints the median
// time per call of each and their ratio (pure / vendor; below 1 means the pure path is faster).

import { Buffer } from "std/core/buffer";
import * as vendor from "../../../test/crypto/oracle";
import * as pure from "std/crypto/pure/coreNative";

const ROUNDS = 7;
const ROUND_MS = 15.0;

let sink: number = 0;

function sample(size: int32): Buffer {
	const bytes = Buffer.alloc(size);
	for (let i = 0; i < size; i++) bytes[i] = ((i * 31 + 7) & 255) as uint8;
	return bytes;
}

function callsFor(op: () => void): int32 {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		if (performance.now() - start >= ROUND_MS) return calls;
		calls *= 2;
	}
}

function nsPerCall(op: () => void, calls: int32): number {
	const start = performance.now();
	for (let i = 0; i < calls; i++) op();
	return (performance.now() - start) * 1000000.0 / calls;
}

function median(values: number[]): number {
	values.sort((a, b) => a - b);
	return values[values.length >> 1];
}

function fixed(value: number): string {
	return (Math.round(value * 100) / 100).toString();
}

function pad(text: string, width: int32): string {
	let padded = text;
	while (padded.length < width) padded = padded + " ";
	return padded;
}

function row(
	name: string,
	bytes: int32,
	pureOp: () => void,
	vendorOp: () => void,
): void {
	const calls = callsFor(vendorOp);
	const pureTimes: number[] = [];
	const vendorTimes: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		pureTimes.push(nsPerCall(pureOp, calls));
		vendorTimes.push(nsPerCall(vendorOp, calls));
	}
	const p = median(pureTimes);
	const v = median(vendorTimes);
	const unit = bytes > 0 ? "ns/B" : "ns/op";
	const scale = bytes > 0 ? bytes : 1;
	console.log(
		pad(name, 24) + pad(`pure ${fixed(p / scale)} ${unit}`, 22) +
			pad(`vendor ${fixed(v / scale)} ${unit}`, 24) + `ratio ${fixed(p / v)}`,
	);
}

for (const size of [64, 1024, 65536]) {
	const data = sample(size);
	const hex = vendor.toHex(data);
	const b64 = vendor.toBase64(data);
	row(`toHex ${size}`, size, () => { sink += pure.toHex(data).length; },
		() => { sink += vendor.toHex(data).length; });
	row(`fromHex ${size}`, size,
		() => { sink += pure.fromHex(hex).ok ? 1 : 0; },
		() => { sink += vendor.fromHex(hex).ok ? 1 : 0; });
	row(`toBase64 ${size}`, size, () => { sink += pure.toBase64(data).length; },
		() => { sink += vendor.toBase64(data).length; });
	row(`fromBase64 ${size}`, size,
		() => { sink += pure.fromBase64(b64).ok ? 1 : 0; },
		() => { sink += vendor.fromBase64(b64).ok ? 1 : 0; });
}

const small = sample(64);
row("createHash sha256 64", 0,
	() => { sink += pure.createHash("sha256").update(small).digest().length; },
	() => { sink += vendor.createHash("sha256").update(small).digest().length; });
row("createHash sha256 only", 0,
	() => { sink += pure.createHash("sha256") == null ? 0 : 1; },
	() => { sink += vendor.createHash("sha256") == null ? 0 : 1; });
row("digestSync sha256 64", 0,
	() => { sink += pure.digestSync("sha256", small).ok ? 1 : 0; },
	() => { sink += vendor.digestSync("sha256", small).ok ? 1 : 0; });
const secretA = sample(32);
const secretB = sample(32);
row("timingSafeEqual 32", 0,
	() => { sink += pure.timingSafeEqual(secretA, secretB) ? 1 : 0; },
	() => { sink += vendor.timingSafeEqual(secretA, secretB) ? 1 : 0; });
row("randomBytes 32", 0,
	() => { sink += pure.randomBytesSync(32).ok ? 1 : 0; },
	() => { sink += vendor.randomBytesSync(32).ok ? 1 : 0; });
row("randomInt 0..1000", 0,
	() => { sink += pure.randomIntSync(0, 1000).ok ? 1 : 0; },
	() => { sink += vendor.randomIntSync(0, 1000).ok ? 1 : 0; });
row("randomUUID", 0,
	() => { sink += pure.randomUUIDSync().ok ? 1 : 0; },
	() => { sink += vendor.randomUUIDSync().ok ? 1 : 0; });
console.log(`sink ${sink > 0}`);
