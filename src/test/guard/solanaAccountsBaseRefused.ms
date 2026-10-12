// GUARD-OS solana
// GUARD-CHECK-FAIL 'Guarded' extends 'Gate<Signer>', whose fields accounts<T>() cannot read
// GUARD-CHECK-FAIL field 'vault' holds 'Owned<Boxed>', and 'Boxed' extends 'Box<Pubkey>', whose fields accounts<T>() cannot read
// GUARD-CHECK-FAIL 'FarDerived' extends 'FarBase', whose fields accounts<T>() cannot read
// GUARD-CHECK-FAIL field 'vault' holds 'Owned<FarKeptChild>', and 'FarKeptChild' extends 'FarKept', whose fields accounts<T>() cannot read
// GUARD-CHECK-FAIL imported where accounts<T>() is called
// accounts<T>() verifies the fields a struct inherits ahead of its own, from each base's
// declaration. A base whose declaration it cannot read is refused: one with type arguments, and
// one declared in another module that is not imported where accounts<T>() is called.
// RED MEANS: accounts<T>() built a struct whose inherited Signer no verifier checked, or skipped
// a decorator that names a field the account's data inherits.
import {
	Discriminator, Owned, ProgramError, Pubkey, Signer, Writable, accountDiscriminator, accounts, failWith, hasOne,
} from "std/solana";
import { FarDerived, FarKeptChild } from "./fixtures/solanaFarBase";

export struct Gate<T> { authority: T; }
export struct Guarded extends Gate<Signer> { target: Writable; }

export struct Box<T> { owner: T; }
export struct Boxed extends Box<Pubkey> { limit: uint64; }

export function discriminator(this typeof Boxed): Discriminator {
	return @comptime { return accountDiscriminator("Boxed"); };
}

export struct BoxedAccounts {
	owner: Signer;
	@hasOne(owner) vault: Owned<Boxed>;
}

export struct FarKeptAccounts {
	owner: Signer;
	@hasOne(owner) vault: Owned<FarKeptChild>;
}

function run(): Result<uint64, ProgramError> {
	const x = try accounts<Guarded>();
	const y = try accounts<FarDerived>();
	const z = try accounts<FarKeptAccounts>();
	const boxed = try accounts<BoxedAccounts>();
	return Result.ok(x.authority.lamports() + x.target.lamports() + y.owner.lamports() + z.vault.data().limit +
		boxed.vault.data().limit);
}

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
}

main();
