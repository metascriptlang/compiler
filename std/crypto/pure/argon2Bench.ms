// Pure argon2 bench: cross-backend probe timing (all backends) and C/vendor comparison.
//
// Cross-backend probe:
//   msc build std/crypto/pure/argon2Bench.ms --target=js --danger --output=out/bench.js && node out/bench.js
// C vendor comparison:
//   msc build std/crypto/pure/argon2Bench.ms --danger --output=out/argon2Bench && out/argon2Bench

import { argon2Raw } from "./argon2";

const password: uint8[] = [112, 97, 115, 115, 119, 111, 114, 100];
const salt: uint8[] = [115, 111, 109, 101, 115, 97, 108, 116, 115, 97, 108, 116];

function medianOf(values: number[]): number {
	const sorted = values.slice();
	sorted.sort((a: number, b: number): number => a - b);
	return sorted[Math.floor(sorted.length / 2) as int32];
}

// Cross-backend: interleaved m=8 and m=1024 runs to infer per-compress-block cost.
// m=8  t=1 p=1 → ~10 compressBlock calls (mostly setup + blake2b).
// m=1024 t=1 p=1 → ~1030 compressBlock calls (compress-dominated).
{
	const PROBE_ROUNDS = 11;
	const small: number[] = [];
	const large: number[] = [];
	for (let pr = 0; pr < PROBE_ROUNDS; pr++) {
		{
			const t0 = performance.now();
			argon2Raw(password, salt, 1, 8, 1, 4);
			small.push(performance.now() - t0);
		}
		{
			const t0 = performance.now();
			argon2Raw(password, salt, 1, 1024, 1, 4);
			large.push(performance.now() - t0);
		}
	}
	const msSmall = medianOf(small);
	const msLarge = medianOf(large);
	const perBlock = (msLarge - msSmall) / 1020.0;
	console.log(`pure argon2: m=8 ${msSmall.toFixed(1)}ms · m=1024 ${msLarge.toFixed(1)}ms · per-compress-block ${(perBlock * 1000.0).toFixed(2)}µs`);
}

when (c) {
	import { argon2HashRawSync } from "std/crypto/argon2";

	const ROUNDS = 9;

	class Row {
		label: string;
		timeCost: int32;
		memoryCost: int32;
		parallelism: int32;
	}

	const rows: Row[] = [
		{ label: "argon2id m=1024 t=1 p=1", timeCost: 1, memoryCost: 1024, parallelism: 1 },
		{ label: "argon2id m=19456 t=2 p=1 (OWASP)", timeCost: 2, memoryCost: 19456, parallelism: 1 },
	];

	for (const row of rows) {
		const pureMs: number[] = [];
		const vendorMs: number[] = [];
		for (let r = 0; r < ROUNDS; r++) {
			const t1 = performance.now();
			const pureResult = argon2Raw(password, salt, row.timeCost, row.memoryCost, row.parallelism, 32);
			const t2 = performance.now();
			const vendorResult = argon2HashRawSync(password, salt, row.timeCost, row.memoryCost, row.parallelism, 32);
			const t3 = performance.now();
			if (!pureResult.ok || !vendorResult.ok || pureResult.value.length != vendorResult.value.length) throw new Error("argon2 bench: a side failed");
			for (let i = 0; i < pureResult.value.length; i++) {
				if (pureResult.value[i] != vendorResult.value[i]) throw new Error("argon2 bench: outputs differ");
			}
			pureMs.push(t2 - t1);
			vendorMs.push(t3 - t2);
		}
		const p = medianOf(pureMs);
		const v = medianOf(vendorMs);
		console.log(`${row.label}: pure ${p.toFixed(2)} ms, vendor ${v.toFixed(2)} ms, pure/vendor ${(p / v).toFixed(2)}`);
	}
}
