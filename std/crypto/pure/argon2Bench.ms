// Pure argon2 against the vendor C library through the public surface, on the C backend.
//
//   msc build std/crypto/pure/argon2Bench.ms --danger --output=out/argon2Bench && out/argon2Bench
//
// Each row times one hash per side per round, interleaved, and prints the median milliseconds per
// hash of each side and pure / vendor.

import { argon2HashRawSync } from "std/crypto/argon2";
import { argon2Raw } from "./argon2";

const ROUNDS = 9;

class Row {
	label: string;
	timeCost: int32;
	memoryCost: int32;
	parallelism: int32;
}

function median(values: number[]): number {
	const sorted = values.slice();
	sorted.sort((a: number, b: number): number => a - b);
	return sorted[Math.floor(sorted.length / 2) as int32];
}

const password: uint8[] = [112, 97, 115, 115, 119, 111, 114, 100];
const salt: uint8[] = [115, 111, 109, 101, 115, 97, 108, 116, 115, 97, 108, 116];
const rows: Row[] = [
	{ label: "argon2id m=1024 t=1 p=1", timeCost: 1, memoryCost: 1024, parallelism: 1 },
	{ label: "argon2id m=19456 t=2 p=1 (OWASP)", timeCost: 2, memoryCost: 19456, parallelism: 1 },
];

for (const row of rows) {
	const pureMs: number[] = [];
	const vendorMs: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		const a = performance.now();
		const pure = argon2Raw(password, salt, row.timeCost, row.memoryCost, row.parallelism, 32);
		const b = performance.now();
		const vendor = argon2HashRawSync(password, salt, row.timeCost, row.memoryCost, row.parallelism, 32);
		const c = performance.now();
		if (!pure.ok || !vendor.ok || pure.value.length != vendor.value.length) throw new Error("argon2 bench: a side failed");
		for (let i = 0; i < pure.value.length; i++) {
			if (pure.value[i] != vendor.value[i]) throw new Error("argon2 bench: outputs differ");
		}
		pureMs.push(b - a);
		vendorMs.push(c - b);
	}
	const p = median(pureMs);
	const v = median(vendorMs);
	console.log(`${row.label}: pure ${p.toFixed(2)} ms, vendor ${v.toFixed(2)} ms, pure/vendor ${(p / v).toFixed(2)}`);
}
