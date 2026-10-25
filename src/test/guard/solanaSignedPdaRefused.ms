// GUARD-OS solana
// GUARD-CHECK-FAIL solanaSignedPdaRefused.ms:20:
// GUARD-CHECK-FAIL solanaSignedPdaRefused.ms:21:
// GUARD-CHECK-FAIL solanaSignedPdaRefused.ms:22:
// GUARD-CHECK-FAIL solanaSignedPdaRefused.ms:23:
// GUARD-CHECK-FAIL logU64 takes no signers
// GUARD-CHECK-FAIL one PDA signs
// GUARD-CHECK-FAIL seeds must be written as a list at the call: ["pet", mint, [bump]]
// GUARD-CHECK-FAIL a signer needs at least one seed
// signedPda finds the bump of one PDA for the call that signs with it: the call must take signers,
// and the seeds are one list written at the call without the bump.
// RED MEANS: signedPda accepted a call that cannot sign, or seeds the found bump cannot be appended to.
import { ProgramError, account, failWith, logU64, signedPda, transfer } from "std/solana";

function main(): void {
	const first = account(0);
	const second = account(1);
	if (!first.ok || !second.ok) { return; }
	const seeds = ["vault"];
	const refusedCallee = signedPda(logU64(1), first.value, ["vault"]); // GUARD-REFUSED
	const refusedSigners = signedPda(transfer(first.value, second.value, 1), first.value, [["vault", [1]], ["pet"]]); // GUARD-REFUSED
	const refusedName = signedPda(transfer(first.value, second.value, 1), first.value, seeds); // GUARD-REFUSED
	const refusedEmpty = signedPda(transfer(first.value, second.value, 1), first.value, []); // GUARD-REFUSED
	failWith(ProgramError.invalidArgument());
}

main();
