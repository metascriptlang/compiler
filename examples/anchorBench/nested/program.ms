import {
	Discriminator,
	Mutable,
	Owned,
	Program,
	ProgramError,
	Pubkey,
	Signer,
	System,
	Writable,
	WritableSigner,
	accountDiscriminator,
	accounts,
	bump,
	createPda,
	failWith,
	hasOne,
	instruction,
	seeds,
} from "std/solana";

export enum NestedOp {
	Initialize,
	Increment,
	Reset,
}

export struct Config {
	admin: Pubkey;
	bump: uint8;
	pad: uint8[7];
}

export struct Counter {
	value: uint64;
	bump: uint8;
	pad: uint8[7];
}

export function discriminator(this typeof Config): Discriminator {
	return @comptime { return accountDiscriminator("Config"); };
}

export function discriminator(this typeof Counter): Discriminator {
	return @comptime { return accountDiscriminator("Counter"); };
}

export struct InitializeAccounts {
	admin: WritableSigner;
	config: Writable;
	counter: Writable;
	systemProgram: Program<System>;
}

export struct AdminCounterAccounts {
	admin: Signer;
	@hasOne(admin) @seeds("config") @bump(config.bump) config: Owned<Config>;
	@seeds("counter") @bump(counter.bump) counter: Mutable<Counter>;
}

function initialize(): Result<uint64, ProgramError> {
	const x = try accounts<InitializeAccounts>();
	const config = try createPda<Config>(x.admin, x.config, ["config"]);
	const counter = try createPda<Counter>(x.admin, x.counter, ["counter"]);
	const settings = config.asMutable().data();
	settings.admin = x.admin.key();
	settings.bump = config.foundBump();
	const value = counter.asMutable().data();
	value.value = 0;
	value.bump = counter.foundBump();
	return Result.ok(0);
}

function update(reset: boolean): Result<uint64, ProgramError> {
	const x = try accounts<AdminCounterAccounts>();
	const counter = x.counter.data();
	counter.value = reset ? 0 : counter.value + 1;
	return Result.ok(0);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<NestedOp>()) {
		NestedOp.Initialize => initialize(),
		NestedOp.Increment => update(false),
		NestedOp.Reset => update(true),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (!testBuild) { entry(); }
