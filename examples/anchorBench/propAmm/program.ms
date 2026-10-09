import {
	Discriminator,
	Mutable,
	Program,
	ProgramError,
	Pubkey,
	Signer,
	System,
	WritableSigner,
	accountDiscriminator,
	accounts,
	address,
	args,
	asWritable,
	create,
	failWith,
	hasOne,
	instruction,
} from "std/solana";

export enum PropOp {
	Update,
	Initialize,
	RotateAuthority,
}

export struct Oracle {
	authority: Pubkey;
	price: uint64;
}

export function discriminator(this typeof Oracle): Discriminator {
	return @comptime { return accountDiscriminator("Oracle"); };
}

const UPDATE_AUTHORITY: Pubkey = @comptime { return {
	bytes: [234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249,
		149, 71, 118, 174, 190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44],
}; };

export struct UpdateArgs { newPrice: uint64; }
export struct RotateArgs { newAuthority: Pubkey; }

function updateAuthorityError(): ProgramError { return { code: 105 }; }

export struct UpdateAccounts {
	oracle: Mutable<Oracle>;
	@address(UPDATE_AUTHORITY, updateAuthorityError()) authority: Signer;
}

export struct InitializeAccounts {
	payer: WritableSigner;
	oracle: WritableSigner;
	systemProgram: Program<System>;
}

export struct RotateAccounts {
	@hasOne(authority, ProgramError.userError(0)) oracle: Mutable<Oracle>;
	authority: Signer;
}

function update(): Result<uint64, ProgramError> {
	const input = try args<UpdateArgs>();
	const x = try accounts<UpdateAccounts>();
	x.oracle.data().price = input.newPrice;
	return Result.ok(0);
}

function initialize(): Result<uint64, ProgramError> {
	const x = try accounts<InitializeAccounts>();
	const oracle = try create<Oracle>(x.payer, x.oracle.asWritable());
	const value = oracle.data();
	value.authority = x.payer.key();
	value.price = 0;
	return Result.ok(0);
}

function rotate(): Result<uint64, ProgramError> {
	const input = try args<RotateArgs>();
	const x = try accounts<RotateAccounts>();
	x.oracle.data().authority = input.newAuthority;
	return Result.ok(0);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<PropOp>()) {
		PropOp.Update => update(),
		PropOp.Initialize => initialize(),
		PropOp.RotateAuthority => rotate(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (!testBuild) { entry(); }
