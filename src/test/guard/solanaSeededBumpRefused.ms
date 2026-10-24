// GUARD-OS solana
// GUARD-CHECK-FAIL solanaSeededBumpRefused.ms:16:
// GUARD-CHECK-FAIL solanaSeededBumpRefused.ms:17:
// GUARD-CHECK-FAIL solanaSeededBumpRefused.ms:18:
// GUARD-CHECK-FAIL Too many arguments: expected at most 5, got 6
// GUARD-CHECK-FAIL Type 'Result<uint8, ProgramError>' is not assignable to type 'Result<uint64, ProgramError>'
// An author-chosen bump cannot reach createProgramAccountSeeded: it derives the canonical bump of the
// seeds against the target's own key, refuses another address, and signs with that bump.
// RED MEANS: a program creates a program-owned account at a non-canonical bump address for the same seeds
// (measured: bump 253 where the canonical bump is 255, ok on LiteSVM), and pda() later refuses it with 2006.
import { Account, ProgramError, createProgramAccountSeeded, programId } from "std/solana";
import { seedText } from "std/solana/seed";
import { createProgramAccountSeeded as direct } from "std/solana/core";

function chosen(payer: Account, target: Account): Result<uint8, ProgramError> {
	const a = try createProgramAccountSeeded(payer, target, 16, programId(), [seedText("pet")], 253); // GUARD-REFUSED
	const b = try direct(payer, target, 16, programId(), [seedText("pet")], 253); // GUARD-REFUSED
	const c: Result<uint64, ProgramError> = createProgramAccountSeeded(payer, target, 16, programId(), [seedText("pet")]); // GUARD-REFUSED
	return Result.ok(a);
}
