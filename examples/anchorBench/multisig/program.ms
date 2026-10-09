import { seedTable } from "std/solana/accountSeeds";
import {
	Account,
	Discriminator,
	Mutable,
	Owned,
	Program,
	ProgramError,
	Pubkey,
	System,
	Writable,
	WritableSigner,
	account,
	accountCount,
	accountDiscriminator,
	accounts,
	args,
	asAccount,
	bump,
	canonicalBump,
	createPda,
	failWith,
	hasOne,
	instruction,
	isSigner,
	isUtf8,
	key,
	seeds,
	signed,
	transfer,
	transferLamports,
} from "std/solana";

export enum MultisigOp { Create, Deposit, SetLabel, ExecuteTransfer, }

export struct MultisigConfig {
	creator: Pubkey;
	threshold: uint8;
	bump: uint8;
	labelLength: uint16;
	label: uint8[32];
	signersLength: uint16;
	signers: Pubkey[10];
}

export function discriminator(this typeof MultisigConfig): Discriminator {
	return @comptime { return accountDiscriminator("MultisigConfig"); };
}

export struct CreateArgs { threshold: uint8; }
export struct AmountArgs { amount: uint64; }
export struct LabelArgs { labelLength: uint8; label: uint8[32]; }

export struct CreateAccounts {
	creator: WritableSigner;
	config: Writable;
	systemProgram: Program<System>;
}

export struct DepositAccounts {
	depositor: WritableSigner;
	config: Owned<MultisigConfig>;
	vault: Writable;
	systemProgram: Program<System>;
}

export struct LabelAccounts {
	creator: WritableSigner;
	@hasOne(creator) @seeds("multisig", creator) @bump(config.bump) config: Mutable<MultisigConfig>;
}

export struct TransferAccounts {
	@hasOne(creator) @seeds("multisig", creator) @bump(config.bump) config: Owned<MultisigConfig>;
	creator: Account;
	vault: Writable;
	recipient: Writable;
	systemProgram: Program<System>;
}

function createMultisig(): Result<uint64, ProgramError> {
	const input = try args<CreateArgs>();
	const x = try accounts<CreateAccounts>();
	const made = try createPda<MultisigConfig>(x.creator, x.config, ["multisig", x.creator.key()]);
	const count = accountCount() - 3;
	if (count > 10) { return Result.err(ProgramError.userError(1)); }
	if (input.threshold == 0 || (input.threshold as int32) > count) {
		return Result.err(ProgramError.userError(0));
	}
	let signers: Pubkey[10] = [];
	for (let i = 0; i < count; i++) {
		const remaining = try account(3 + i);
		if (!remaining.isSigner()) { return Result.err(ProgramError.userError(2)); }
		signers[i] = remaining.key();
	}
	const config = made.account.data();
	config.creator = x.creator.key();
	config.threshold = input.threshold;
	config.bump = made.bump;
	config.labelLength = 0;
	config.signersLength = count as uint16;
	config.signers = signers;
	return Result.ok(0);
}

function deposit(): Result<uint64, ProgramError> {
	const input = try args<AmountArgs>();
	const x = try accounts<DepositAccounts>();
	try canonicalBump(x.vault.asAccount(), seedTable(["vault", x.config.key()]));
	return transferLamports(x.depositor, x.vault, input.amount);
}

function setLabel(): Result<uint64, ProgramError> {
	const input = try args<LabelArgs>();
	const x = try accounts<LabelAccounts>();
	if (input.labelLength > 32) { return Result.err(ProgramError.userError(3)); }
	if (!isUtf8(input.label, input.labelLength as int32)) { return Result.err(ProgramError.userError(3)); }
	const config = x.config.data();
	config.labelLength = input.labelLength as uint16;
	for (let i = 0; i < (input.labelLength as int32); i++) { config.label[i] = input.label[i]; }
	return Result.ok(0);
}

function executeTransfer(): Result<uint64, ProgramError> {
	const input = try args<AmountArgs>();
	const x = try accounts<TransferAccounts>();
	const vaultBump = try canonicalBump(x.vault.asAccount(), seedTable(["vault", x.config.key()]));
	const config = x.config.data();
	if (config.signersLength > 10) { return Result.err(ProgramError.invalidAccountData()); }
	let approvals: uint32 = 0;
	for (let i = 5; i < accountCount(); i++) {
		const remaining = try account(i);
		if (!remaining.isSigner()) { continue; }
		for (let stored = 0; stored < (config.signersLength as int32); stored++) {
			if (remaining.key() == config.signers[stored]) { approvals = approvals + 1; break; }
		}
	}
	if (approvals < (config.threshold as uint32)) { return Result.err(ProgramError.userError(2)); }
	return signed(transfer(x.vault.asAccount(), x.recipient.asAccount(), input.amount),
		["vault", x.config.key(), [vaultBump]]);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<MultisigOp>()) {
		MultisigOp.Create => createMultisig(),
		MultisigOp.Deposit => deposit(),
		MultisigOp.SetLabel => setLabel(),
		MultisigOp.ExecuteTransfer => executeTransfer(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (!testBuild) { entry(); }
