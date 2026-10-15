// GUARD-OS solana
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:41:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:42:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:44:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:45:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:46:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:47:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:48:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:50:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:51:
// GUARD-CHECK-FAIL solanaPdaForgeRefused.ms:53:
// GUARD-CHECK-FAIL 'account' is a private field of 'Pda'
// GUARD-CHECK-FAIL 'bump' is a private field of 'Pda'
// GUARD-CHECK-FAIL cannot convert Mutable<Pet> to Pda<Pet>
// GUARD-CHECK-FAIL type 'Pda<Pet>' has a private field and can only be built by the module that declares it
// GUARD-CHECK-FAIL 'h' may be read before it is assigned: type 'Pda<Pet>' has a private field
// GUARD-CHECK-FAIL 's' may be read before it is assigned: type 'Signer' has a private field
// GUARD-CHECK-FAIL 2 of 2 slots are left without a value
// A Pda<T> comes only from pda, pdaWithBump and createPda<T>, which check the account's address
// against the seeds: outside std/solana a literal, `as`, `{}`, an unassigned local and a short
// array build none (nor a Signer from an unassigned local), and the bump and the account
// of one that was verified are read through foundBump() and asMutable(), never written.
// RED MEANS: a program pairs any Mutable<T> with any bump as a Pda<T>, or changes the bump of a
// verified one, and code that takes a Pda<T> signs or stores a bump nothing derived.
import { Discriminator, Mutable, Pda, ProgramError, Signer, accountDiscriminator, failWith, mutable, pda } from "std/solana";

export struct Pet {
	hearts: uint64;
}

export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Pet"); };
}

function allowed(found: Pda<Pet>): uint64 {
	const pet: Mutable<Pet> = found.asMutable();
	return pet.data().hearts + (found.foundBump() as uint64);
}

function forged(pet: Mutable<Pet>, found: Pda<Pet>): void {
	const a: Pda<Pet> = { account: pet, bump: 9 };
	const b = pet as Pda<Pet>;
	let c = found;
	c.bump = 9;
	const d = found.bump;
	const e = found.account;
	const f = {} as Pda<Pet>;
	const g: Pda<Pet> = {};
	let h: Pda<Pet>;
	const i = h.foundBump();
	const j: Pda<Pet>[2] = [];
	let s: Signer;
	const k = s.lamports();
}

function run(): Result<uint64, ProgramError> {
	const pet = try mutable<Pet>(0);
	const found = try pda(pet, ["pet"]);
	forged(pet, found);
	return Result.ok(allowed(found));
}

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
}

main();
