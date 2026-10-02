// GUARD-OS solana
// GUARD-CHECK-FAIL overflows the maximum allowed frame space
// GUARD-CHECK-FAIL compile failed for
import { instructionData, logU64 } from "std/solana";

struct Big {
	words: uint64[640];
}

function spread(seed: uint64, at: uint64): uint64 {
	let big: Big = { words: [] };
	for (let index: uint64 = 0; index < 640; index++) {
		big.words[index] = seed * index;
	}
	return big.words[at % 640];
}

function main(): void {
	const length = instructionData().length;
	logU64(spread(length, length * 7));
}

main();
