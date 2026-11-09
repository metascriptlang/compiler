// The portable digests against the vendor ones through the public one-shot call, C backend.
//
//   msc build src/bench/crypto/vendor/sha2Bench.ms --danger --output=out/bench && out/bench
//
// Each row alternates pure and vendor rounds and prints the median ns/B of each and pure/vendor
// (below 1 means the pure path is faster).

import { HashAlgorithm, digestSync } from "../../../test/crypto/oracle";
import { digestSync as pureDigestSync } from "std/crypto/pure/coreNative";

let sink: number = 0;

function nsPerByte(size: int32, op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= 40.0) return elapsed * 1000000.0 / (calls * size);
		calls = calls * 4;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

const sizes: int32[] = [64, 1024, 65536];
const algorithms: HashAlgorithm[] = ["sha256", "sha512", "sha1", "md5"];

for (const algorithm of algorithms) {
	for (const size of sizes) {
		const data = new Array<uint8>(size);
		for (let i = 0; i < size; i++) data[i] = ((i * 31 + 7) & 255) as uint8;
		const pure: number[] = [];
		const vendor: number[] = [];
		for (let r = 0; r < 5; r++) {
			pure.push(nsPerByte(size, () => {
				const result = pureDigestSync(algorithm, data);
				if (result.ok) sink += result.value[0];
			}));
			vendor.push(nsPerByte(size, () => {
				const result = digestSync(algorithm, data);
				if (result.ok) sink += result.value[0];
			}));
		}
		const p = median(pure);
		const v = median(vendor);
		console.log(`${algorithm} ${size} B: pure ${p.toFixed(2)} ns/B, vendor ${v.toFixed(2)} ns/B, pure/vendor ${(p / v).toFixed(2)}`);
	}
}
console.log(`sink ${sink > 0}`);
