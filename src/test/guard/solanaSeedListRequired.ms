// GUARD-OS solana
// GUARD-CHECK-FAIL solanaSeedListRequired.ms:15:
// GUARD-CHECK-FAIL solanaSeedListRequired.ms:16:
// GUARD-CHECK-FAIL solanaSeedListRequired.ms:17:
// GUARD-CHECK-FAIL solanaSeedListRequired.ms:18:
// GUARD-CHECK-FAIL seeds must be written as a list at the call: ["pet", mint, [bump]]
// A seed list is written at the call. A name that holds a list is not one: nothing an
// author can keep points at the memory the seeds are read from.
// RED MEANS: a seed macro accepted something other than an array literal.
import {
	failWith,
	findProgramAddress,
	findProgramAddressOf,
	programAddress,
	pubkeyOf,
} from "std/solana";

function main(): void {
	const seeds = ["pet", "dog"];
	const program = pubkeyOf("9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu");
	const byName = findProgramAddress(seeds);
	const byProgram = findProgramAddressOf(program, seeds);
	const byCreate = programAddress(seeds);
	const byText = findProgramAddress("pet");
	if (!byName.ok) { failWith(byName.error); }
	if (!byProgram.ok) { failWith(byProgram.error); }
	if (!byCreate.ok) { failWith(byCreate.error); }
	if (!byText.ok) { failWith(byText.error); }
}

main();
