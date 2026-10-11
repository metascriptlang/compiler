// GUARD-OS solana
// The Hydra crank helpers link for SBF, signed by a sponsor PDA and unsigned, inside the 4 KB frame.
// RED MEANS: createCrank or cancelCrank no longer builds for --os=solana.
import {
	AccountMeta,
	ProgramError,
	account,
	failWith,
	findProgramAddress,
	instructionData,
	signed,
} from "std/solana";
import {
	CrankAccounts,
	CrankSchedule,
	cancelCrank,
	crankAddress,
	createCrank,
	crankSpent,
	legacyCrankAddress,
} from "std/solana/hydra";

function held(): Result<CrankAccounts, ProgramError> {
	const accounts: CrankAccounts = {
		sponsor: try account(0),
		crank: try account(1),
		magicVault: try account(2),
		magicProgram: try account(3),
	};
	return Result.ok(accounts);
}

function dispatch(): Result<uint64, ProgramError> {
	const op = try instructionData().readU8(0);
	const accounts = try held();
	const sponsor = accounts.sponsor.key();
	const seed = try instructionData().readPubkey(1);
	const metas: AccountMeta[2] = [AccountMeta.writable(accounts.crank.key()), AccountMeta.readonly(sponsor)];
	let data: uint8[16] = [];
	if (op == 0) { return createCrank(accounts, seed, CrankSchedule.once(10), sponsor, metas, data); }
	if (op == 1) { return cancelCrank(accounts); }
	const found = try findProgramAddress(["sponsor"]);
	const bump = found.bump;
	if (op == 2) {
		return signed(createCrank(accounts, seed, CrankSchedule.once(10), sponsor, metas, data), ["sponsor", [bump]]);
	}
	if (op == 3) { return signed(cancelCrank(accounts), ["sponsor", [bump]]); }
	const bound = try crankAddress(sponsor, seed);
	const legacy = try legacyCrankAddress(seed);
	const spent = try crankSpent(accounts.crank, sponsor);
	if (bound == legacy || spent) { return Result.err(ProgramError.invalidArgument()); }
	return Result.ok(0);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
