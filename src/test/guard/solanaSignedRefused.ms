// GUARD-OS solana
// GUARD-CHECK-FAIL solanaSignedRefused.ms:27:
// GUARD-CHECK-FAIL solanaSignedRefused.ms:28:
// GUARD-CHECK-FAIL solanaSignedRefused.ms:29:
// GUARD-CHECK-FAIL solanaSignedRefused.ms:30:
// GUARD-CHECK-FAIL solanaSignedRefused.ms:31:
// GUARD-CHECK-FAIL solanaSignedRefused.ms:32:
// GUARD-CHECK-FAIL solanaSignedRefused.ms:33:
// GUARD-CHECK-FAIL logU64 takes no signers
// GUARD-CHECK-FAIL isZero takes no signers
// GUARD-CHECK-FAIL seeds must be written as a list at the call: ["pet", mint, [bump]]
// GUARD-CHECK-FAIL the first argument is the call that signs
// GUARD-CHECK-FAIL a list of signers holds only lists of seeds
// GUARD-CHECK-FAIL a signer needs at least one seed
// GUARD-CHECK-FAIL seed 2 has type uint64
// A signed call names its callee when the callee has no `signers` parameter, takes its
// seeds as a list written at the call, and refuses what a signer table cannot hold.
// RED MEANS: signed accepted a call that cannot sign, or a seed list that is not a list of seeds.
import { Pubkey, ProgramError, account, failWith, logU64, signed, transfer } from "std/solana";

function main(): void {
	const first = account(0);
	const second = account(1);
	if (!first.ok || !second.ok) { return; }
	const seeds = ["vault", [7]];
	const amount: uint64 = 7;
	const refusedCallee = signed(logU64(1), ["vault"]);
	const refusedMember = signed(Pubkey.zero().isZero(), ["vault"]);
	const refusedName = signed(transfer(first.value, second.value, 1), seeds);
	const refusedCall = signed(first, ["vault"]);
	const refusedMix = signed(transfer(first.value, second.value, 1), [["vault", [1]], "pet"]);
	const refusedEmpty = signed(transfer(first.value, second.value, 1), []);
	const refusedInteger = signed(transfer(first.value, second.value, 1), ["vault", amount]);
	failWith(ProgramError.invalidArgument());
}

main();
