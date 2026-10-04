// GUARD-OS solana
// A module const initialized by a call to a @comptime function is evaluated while
// compiling (Nim `evalAtCompileTime` on an `sfCompileTime` callee, NIM-REF CT-32),
// imported and in the entry, with a literal and a const-name argument; no writable
// global reaches the SBF link.
import { PROGRAM, SEED_TEXT, digitSum } from "./fixtures/solanaComptimeIds";
import { instructionData, logU64 } from "std/solana";
const LOCAL: uint64 = digitSum("22");
const FROM_NAME: uint64 = digitSum(SEED_TEXT);
function main(): void {
	logU64(instructionData().length + PROGRAM + LOCAL + FROM_NAME);
}
main();
