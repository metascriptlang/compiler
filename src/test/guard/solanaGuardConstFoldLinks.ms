// GUARD-OS solana
// Scalar module consts inside match GUARDS (imported and same-module, expression
// and statement match) fold before the SBF link, which keeps only .text and
// .rodata (`getConstExpr`, NIM-REF CK-120 "folded at every read"); pre-fix, the
// link died with "relocation refers to a symbol in a discarded section".
// RED MEANS: mapChildren/forEachChild stopped traversing MatchCaseData.caseGuard —
// run /trace-nim on the guard fold.
import { DAMAGE } from "./fixtures/solanaKnobs";
import { instructionData, logU64 } from "std/solana";

const CAP: uint64 = DAMAGE * 2;

function capped(value: uint64): uint64 {
	return match (value) {
		_ when value > CAP => CAP,
		_ when value > DAMAGE => DAMAGE,
		_ => value,
	};
}

function main(): void {
	let picked: uint64 = 0;
	match (capped(instructionData().length + 5)) {
		_ when CAP > DAMAGE * 3 => { picked = CAP; },
		_ => { picked = DAMAGE; },
	}
	logU64(capped(instructionData().length + 5) + picked);
}
main();
