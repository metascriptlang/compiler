import { argon2Raw } from "./argon2";

const password: uint8[] = [112, 97, 115, 115, 119, 111, 114, 100];
const salt: uint8[] = [115, 111, 109, 101, 115, 97, 108, 116, 115, 97, 108, 116];

function medianOf(values: float64[]): float64 {
	const sorted = values.slice();
	sorted.sort((a: float64, b: float64): float64 => a - b);
	return sorted[Math.floor(sorted.length / 2) as int32];
}

let probeChecksum: uint32 = 0;

function sample(memoryCost: int32): float64 {
	const start = performance.now();
	const result = argon2Raw(password, salt, 1, memoryCost, 1, 4);
	const elapsed = performance.now() - start;
	if (!result.ok || result.value.length != 4) {
		throw new Error(`argon2 probe failed at memoryCost ${memoryCost}`);
	}
	for (const byte of result.value) probeChecksum += byte;
	return elapsed;
}

when (!testBuild) {
	const small: float64[] = [];
	const large: float64[] = [];
	for (let round = 0; round < 11; round++) {
		small.push(sample(8));
		large.push(sample(1024));
	}
	const smallMs = medianOf(small);
	const largeMs = medianOf(large);
	const incrementalBlockUs = (largeMs - smallMs) * 1000 / 1020;
	console.log(
		`pure argon2: m=8 ${smallMs.toFixed(2)} ms, ` +
		`m=1024 ${largeMs.toFixed(2)} ms, ` +
		`estimated incremental block ${incrementalBlockUs.toFixed(2)} us, ` +
		`checksum ${probeChecksum}`,
	);

	when (c) {
		import { argon2HashRawSync } from "std/crypto/argon2";

		struct Row {
			label: string;
			timeCost: int32;
			memoryCost: int32;
			parallelism: int32;
		}

		const rows: Row[] = [
			{
				label: "argon2id m=1024 t=1 p=1",
				timeCost: 1,
				memoryCost: 1024,
				parallelism: 1,
			},
			{
				label: "argon2id m=19456 t=2 p=1 (OWASP)",
				timeCost: 2,
				memoryCost: 19456,
				parallelism: 1,
			},
		];

		for (const row of rows) {
			const pureMs: float64[] = [];
			const vendorMs: float64[] = [];
			for (let round = 0; round < 9; round++) {
				const start = performance.now();
				const pure = argon2Raw(
					password, salt, row.timeCost, row.memoryCost,
					row.parallelism, 32,
				);
				const middle = performance.now();
				const vendor = argon2HashRawSync(
					password, salt, row.timeCost, row.memoryCost,
					row.parallelism, 32,
				);
				const end = performance.now();
				if (!pure.ok || !vendor.ok ||
					pure.value.length != vendor.value.length) {
					throw new Error("argon2 bench: a side failed");
				}
				for (let index = 0; index < pure.value.length; index++) {
					if (pure.value[index] != vendor.value[index]) {
						throw new Error("argon2 bench: outputs differ");
					}
				}
				pureMs.push(middle - start);
				vendorMs.push(end - middle);
			}
			const pureMedian = medianOf(pureMs);
			const vendorMedian = medianOf(vendorMs);
			console.log(
				`${row.label}: pure ${pureMedian.toFixed(2)} ms, ` +
				`vendor ${vendorMedian.toFixed(2)} ms, ` +
				`pure/vendor ${(pureMedian / vendorMedian).toFixed(2)}`,
			);
		}
	}
}
