// GUARD-OS solana
// GUARD-CHECK-FAIL accounts<Own>(): field 'target' is a WritablePda with no @seeds
// GUARD-CHECK-FAIL accounts<Inherits>(): field 'target' is a WritablePda with no @seeds
// GUARD-CHECK-FAIL accounts<Deep>(): field 'target' is a WritablePda with no @seeds
// GUARD-CHECK-FAIL accounts<Renamed>(): field 'target' is a WritablePda with no @seeds
// createPda<T>() signs a WritablePda with the bump its declared @seeds found and derives nothing.
// RED MEANS: accounts<T>() built a WritablePda no derivation checked, whose bump is 0, and
// createPda<T>() created the account at the bump-0 address the caller passed.
import {
	Discriminator, Program, ProgramError, System, WritablePda, WritablePda as Slot, WritableSigner,
	accountDiscriminator, accounts, createPda, failWith,
} from "std/solana";

export struct Pet { points: uint64; }
export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Pet"); };
}

export struct Own { payer: WritableSigner; target: WritablePda; system: Program<System>; }

export struct Base { payer: WritableSigner; target: WritablePda; }
export struct Inherits extends Base { system: Program<System>; }

export struct Middle extends Base { system: Program<System>; }
export struct Deep extends Middle { extra: WritableSigner; }

export struct Renamed { payer: WritableSigner; target: Slot; }

function own(): Result<uint64, ProgramError> {
	const x = try accounts<Own>(); // GUARD-REFUSED
	const made = try createPda<Pet>(x.payer, x.target, ["pet"]);
	return Result.ok(made.foundBump() as uint64);
}

function inherits(): Result<uint64, ProgramError> {
	const x = try accounts<Inherits>(); // GUARD-REFUSED
	const made = try createPda<Pet>(x.payer, x.target, ["pet"]);
	return Result.ok(made.foundBump() as uint64);
}

function deep(): Result<uint64, ProgramError> {
	const x = try accounts<Deep>(); // GUARD-REFUSED
	const made = try createPda<Pet>(x.payer, x.target, ["pet"]);
	return Result.ok(made.foundBump() as uint64);
}

function renamed(): Result<uint64, ProgramError> {
	const x = try accounts<Renamed>(); // GUARD-REFUSED
	const made = try createPda<Pet>(x.payer, x.target, ["pet"]);
	return Result.ok(made.foundBump() as uint64);
}

function main(): void {
	const first = own();
	if (!first.ok) { failWith(first.error); }
	const second = inherits();
	if (!second.ok) { failWith(second.error); }
	const third = deep();
	if (!third.ok) { failWith(third.error); }
	const fourth = renamed();
	if (!fourth.ok) { failWith(fourth.error); }
}

main();
