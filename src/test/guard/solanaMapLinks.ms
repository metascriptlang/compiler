// GUARD-OS solana
// A Map's concurrent-access guard calls msMapFatal, which a freestanding target maps to its
// trap (the SBF abort) like every other runtime fatal. RED MEANS msMapFatal has no
// freestanding declaration and clang stops at an implicit declaration.
import { instructionData, logU64 } from "std/solana";
function main(): void {
	const m = new Map<int32, int32>();
	m.set(1, instructionData().length as int32);
	m.set(2, 7);
	logU64((m.size + (m.get(2) ?? 0)) as uint64);
}
main();
