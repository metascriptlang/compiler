import { HashAlgorithm, digestSync } from "std/crypto";
import { hashOf } from "./hash";
import { kindSha256, kindSha512 } from "./state";

let sink: number = 0;

function nsPerByte(size: int32, op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= 100.0) return elapsed * 1000000.0 / (calls * size);
		calls = calls * 4;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

const sizes: int32[] = [64, 1024, 65536];
const algorithms: HashAlgorithm[] = ["sha256", "sha512"];
const kinds: int32[] = [kindSha256, kindSha512];

for (let a = 0; a < 2; a++) {
	for (const size of sizes) {
		const data = new Array<uint8>(size);
		for (let i = 0; i < size; i++) data[i] = ((i * 31 + 7) & 255) as uint8;
		const pure: number[] = [];
		const vendor: number[] = [];
		for (let r = 0; r < 5; r++) {
			pure.push(nsPerByte(size, () => { sink += hashOf(kinds[a], data)[0]; }));
			vendor.push(nsPerByte(size, () => {
				const result = digestSync(algorithms[a], data);
				if (result.ok) sink += result.value.length;
			}));
		}
		const p = median(pure);
		const v = median(vendor);
		console.log(`${algorithms[a]} ${size} B: pure ${p.toFixed(2)} ns/B, vendor ${v.toFixed(2)} ns/B, pure/vendor ${(p / v).toFixed(2)}`);
	}
}
console.log(`sink ${sink}`);
