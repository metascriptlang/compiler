// GUARD-OS solana
// Scalar module consts, chained across modules and signed at the int64 edge,
// fold into their uses under --os=solana; none leaves a writable global for
// the SBF link to discard, so the program links.
import { DAMAGE, WIDE } from "./fixtures/solanaKnobs";
import { instructionData, logU64 } from "std/solana";
const LIMIT: uint64 = DAMAGE * 3;
function main(): void {
	logU64(instructionData().length * DAMAGE + LIMIT);
	if (WIDE < -9007199254740991) logU64(LIMIT);
}
main();
