// Pure BLAKE2b against the Monocypher oracle, interleaved, median ns/byte per size.
//   msc build src/bench/crypto/vendor/blake2bBench.ms --danger --output=out/bench && out/bench

import { blake2bOf } from "std/crypto/pure/blake2b";
import { blake2bSync as vendorSync } from "../../../test/crypto/oracle/blake2bVendor";

const MIN_ROUND_MS = 60.0;
const ROUNDS = 5;
let sink: number = 0;

function nsPerByte(op: () => void, size: int32): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed * 1000000.0 / calls / size;
		calls = calls * 4;
	}
}

function median(xs: number[]): number {
	xs.sort((a, b) => a - b);
	return xs[xs.length >> 1];
}

for (const size of [64, 1024, 65536]) {
	const data = new Array<uint8>(size);
	for (let i = 0; i < size; i++) data[i] = ((i * 31 + 7) & 255) as uint8;
	const key = new Array<uint8>(0);
	const pure: number[] = [];
	const vendor: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		pure.push(nsPerByte(() => { sink += blake2bOf(64, key, data)[0]; }, size));
		vendor.push(nsPerByte(() => { const v = vendorSync(data, 64); if (v.ok) sink += v.value[0]; }, size));
	}
	const p = median(pure);
	const v = median(vendor);
	console.log(`${size} B  pure ${p.toFixed(2)} ns/B  vendor ${v.toFixed(2)} ns/B  pure/vendor ${(p / v).toFixed(2)}`);
}
console.log(`sink ${sink}`);
