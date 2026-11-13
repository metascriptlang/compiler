// Pure sha3 against the vendor C digest, interleaved rounds, median ns/byte.
//
//   msc build src/bench/crypto/vendor/sha3Bench.ms --danger --output=out/bench && out/bench
//   msc run --target=js src/bench/crypto/vendor/sha3Bench.ms

import { Buffer } from "std/core/buffer";
import { digestSync, HashAlgorithm } from "../../../test/crypto/oracle";
import { sha3Of } from "std/crypto/pure/sha3";

const MIN_ROUND_MS = 40.0;
const ROUNDS = 7;

let sink: number = 0;

function nsPerByte(bytes: int32, op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed * 1000000.0 / calls / bytes;
		calls = (elapsed < 1.0 ? calls * 16.0 : Math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed))) as int32;
	}
}

function median(values: number[]): number {
	values.sort((a, b) => a - b);
	return values[values.length >> 1];
}

function fixed(value: number): string {
	return (Math.round(value * 100) / 100).toString();
}

function row(bits: int32, algorithm: HashAlgorithm, size: int32): void {
	const data = Buffer.alloc(size);
	for (let i = 0; i < size; i++) data[i] = ((i * 31 + 7) & 255) as uint8;
	const pure: number[] = [];
	const vendor: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		pure.push(nsPerByte(size, () => { sink += sha3Of(bits, data).length; }));
		when (c) {
			vendor.push(nsPerByte(size, () => {
				const d = digestSync(algorithm, data);
				if (d.ok) sink += d.value.length;
			}));
		}
	}
	const p = median(pure);
	const line = algorithm + " " + size.toString() + " B  pure " + fixed(p) + " ns/B";
	when (c) {
		const v = median(vendor);
		console.log(line + "  vendor " + fixed(v) + " ns/B  pure/vendor " + fixed(p / v));
	} else {
		console.log(line + "  (the JS backend has no vendor sha3)");
	}
}

for (const size of [64, 1024, 65536]) {
	row(256, "sha3-256", size);
	row(512, "sha3-512", size);
}
console.log("sink " + sink.toString());
