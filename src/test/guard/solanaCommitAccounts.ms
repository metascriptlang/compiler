// GUARD-OS solana
import {
	Account,
	ProgramError,
	account,
	failWith,
	instructionData,
	signerAccount,
} from "std/solana";
import { commit, commitAndUndelegate } from "std/solana/magicblock";

function committed(): Result<Account[3], ProgramError> {
	const accounts: Account[3] = [try account(3), try account(4), try account(5)];
	return Result.ok(accounts);
}

function dispatch(): Result<uint64, ProgramError> {
	const op = try instructionData().readU8(0);
	const payer = try signerAccount(0);
	const context = try account(1);
	const vault = try account(2);
	const accounts = try committed();
	if (op == 0) { return commit(payer, try account(3), context); }
	if (op == 1) { return commit(payer, accounts, context); }
	if (op == 2) { return commit(payer, accounts, context, vault); }
	if (op == 3) { return commitAndUndelegate(payer, try account(3), context); }
	if (op == 4) { return commitAndUndelegate(payer, accounts, context); }
	return commitAndUndelegate(payer, accounts, context, vault);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
