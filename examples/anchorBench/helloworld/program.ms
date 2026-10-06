import {
	Discriminator,
	Program,
	ProgramError,
	System,
	Writable,
	WritableSigner,
	accountDiscriminator,
	accounts,
	createPda,
	failWith,
	instruction,
} from "std/solana";

export enum HelloOp {
	Init,
}

export struct Counter {
	value: uint64;
	bump: uint8;
	pad: uint8[7];
}

export function discriminator(this typeof Counter): Discriminator {
	return @comptime { return accountDiscriminator("Counter"); };
}

export struct InitAccounts {
	payer: WritableSigner;
	counter: Writable;
	systemProgram: Program<System>;
}

function init(): Result<uint64, ProgramError> {
	const x = try accounts<InitAccounts>();
	const made = try createPda<Counter>(x.payer, x.counter, ["counter"]);
	const counter = made.account.data();
	counter.value = 42;
	counter.bump = made.bump;
	return Result.ok(0);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<HelloOp>()) {
		HelloOp.Init => init(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (!testBuild) {
	entry();
}
