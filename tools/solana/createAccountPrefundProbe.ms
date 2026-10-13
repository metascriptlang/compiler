import { ProgramError, account, createAccount, failWith, minimumBalance, programId } from "std/solana";

function dispatch(): Result<uint64, ProgramError> {
	const payer = try account(0);
	const target = try account(1);
	return createAccount(payer, target, minimumBalance(16), 16, programId());
}

function main(): void {
	const outcome = dispatch();
	if (!outcome.ok) { failWith(outcome.error); }
}
main();
