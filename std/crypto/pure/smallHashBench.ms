// Per-phase cost of one small digest on the C backend: state allocation, init, update, finish,
// wipe and output, each row cumulative, against the vendor digest of the same input.
//
//   msc build std/crypto/pure/smallHashBench.ms --danger --output=out/bench && out/bench

import { HashAlgorithm, digestSync } from "std/crypto";
import { digestSync as pureDigestSync } from "./coreNative";
import { newHashState, wipeHashState } from "./state";
import { Buffer } from "std/core/buffer";
import { wipeBytes, wipeWords } from "./secret";
import { newHash, updateHash, finishHashInto, finishHash, hashOf } from "./hash";

const ROUNDS = 7;
const ROUND_MS = 20.0;
let sink: number = 0;

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
	return (Math.round(value * 10) / 10).toString();
}

function measure(name: string, ops: (() => void)[], labels: string[]): void {
	const calls = callsFor(ops[ops.length - 1]);
	const times: number[][] = [];
	for (let k = 0; k < ops.length; k++) times.push([]);
	for (let r = 0; r < ROUNDS; r++) {
		for (let k = 0; k < ops.length; k++) times[k].push(nsPerCall(ops[k], calls));
	}
	let line = name;
	for (let k = 0; k < ops.length; k++) line = line + ` ${labels[k]}=${fixed(median(times[k]))}`;
	console.log(line + " ns");
}

const names: HashAlgorithm[] = ["sha256", "sha512", "sha1", "md5"];
const kinds: int32[] = [0, 2, 4, 5];
const outSizes: int32[] = [32, 64, 20, 16];
const sizes: int32[] = [64];
for (let a = 0; a < 4; a++) {
	for (const size of sizes) {
		const kind = kinds[a];
		const algorithm = names[a];
		const data = new Array<uint8>(size);
		for (let i = 0; i < size; i++) data[i] = ((i * 31 + 7) & 255) as uint8;
		const out = new Array<uint8>(outSizes[a]);
		const words = new Array<uint32>(kind == 2 ? 16 : 8);
		const block = new Array<uint8>(kind == 2 ? 128 : 64);
		const ops: (() => void)[] = [
			() => { sink += newHashState(kind).outputSize; },
			() => { sink += newHash(kind).outputSize; },
			() => { const h = newHash(kind); updateHash(h, data); sink += h.filled; },
			() => { const h = newHash(kind); updateHash(h, data); finishHashInto(h, out); sink += out[0]; },
			() => { wipeWords(words); wipeBytes(block); sink += block.length; },
			() => { const h = newHash(kind); updateHash(h, data); finishHashInto(h, out); wipeHashState(h); sink += out[0]; },
			() => { sink += Buffer.allocUnsafe(outSizes[a]).length; },
			() => { const h = newHash(kind); updateHash(h, data); finishHashInto(h, out); wipeWords(h.state); sink += out[0]; },
			() => { const h = newHash(kind); updateHash(h, data); finishHashInto(h, out); wipeBytes(h.block); sink += out[0]; },
			() => { const h = newHash(kind); updateHash(h, data); sink += finishHash(h)[0]; },
			() => { sink += hashOf(kind, data)[0]; },
			() => { const r = pureDigestSync(algorithm, data); if (r.ok) sink += r.value[0]; },
			() => { const r = digestSync(algorithm, data); if (r.ok) sink += r.value[0]; },
		];
		measure(`${algorithm} ${size}B`, ops,
			["alloc", "+init", "+update", "+finishInto", "wipe16+block", "+wipeState", "outAlloc", "+wipeWords", "+wipeBlock", "finishHash", "hashOf", "pureDigest", "vendor"]);
	}
}
console.log(`sink ${sink > 0}`);
