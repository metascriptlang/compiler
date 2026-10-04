// GUARD-OS solana
// A Set, a defer and a caught throw raise through the runtime error flag, which on Solana lives in
// the program context: the SBF link keeps no writable static. RED MEANS the flag is a static again
// and the link stops at "relocation refers to a symbol in a discarded section: msErr".
import { instructionData, logU64 } from "std/solana";
function pick(n: int32): int32 {
	if (n > 100) throw new Error("too big");
	return n * 2;
}
function remember(seen: Set<int32>, n: int32): void { seen.add(n); }
function main(): void {
	const seen = new Set<int32>();
	remember(seen, instructionData().length as int32);
	let picked: int32 = 0;
	try {
		defer { logU64(7); }
		picked = pick(instructionData().length as int32);
	} catch (e) {
		picked = -1;
	}
	logU64((seen.size as int32 + picked) as uint64);
}
main();
