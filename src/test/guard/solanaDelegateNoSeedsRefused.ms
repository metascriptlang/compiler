// GUARD-CHECK-FAIL delegate(): the delegation program takes 1 to 8 seeds, and this list has 0
import { ProgramError, account } from "std/solana";
import { DelegationAccounts, DelegationConfig, delegate } from "std/solana/magicblock";

function step(): Result<uint64, ProgramError> {
	const one = try account(0);
	const accounts: DelegationAccounts = {
		payer: one, delegated: one, ownerProgram: one, buffer: one,
		delegationRecord: one, delegationMetadata: one, systemProgram: one,
	};
	return delegate(accounts, [], 255, DelegationConfig.anyValidator());
}

console.log(step().ok);
