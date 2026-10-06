import {
	Account,
	Program,
	ProgramError,
	System,
	Writable,
	WritableSigner,
	accounts,
	args,
	asAccount,
	bump,
	failWith,
	instruction,
	seeds,
	transfer,
} from "std/solana";

export enum VaultOp {
	Deposit,
	Withdraw,
}

export struct AmountArgs {
	amount: uint64;
}

export struct DepositAccounts {
	user: WritableSigner;
	@seeds("vault", user) @bump vault: Writable;
	systemProgram: Program<System>;
}

export struct WithdrawAccounts {
	user: WritableSigner;
	@seeds("vault", user) @bump vault: Writable;
}

function deposit(): Result<uint64, ProgramError> {
	const given = try args<AmountArgs>();
	const x = try accounts<DepositAccounts>();
	return transfer(x.user.asAccount(), x.vault.asAccount(), given.amount);
}

function withdraw(): Result<uint64, ProgramError> {
	const given = try args<AmountArgs>();
	const x = try accounts<WithdrawAccounts>();
	const vault = x.vault.asAccount();
	const user = x.user.asAccount();
	vault.setLamports(vault.lamports() - given.amount);
	user.setLamports(user.lamports() + given.amount);
	return Result.ok(given.amount);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<VaultOp>()) {
		VaultOp.Deposit => deposit(),
		VaultOp.Withdraw => withdraw(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (!testBuild) {
	entry();
}
