// GUARD-OS solana
// GUARD-CHECK-FAIL solanaReadonlyDataRefused.ms:29:
// GUARD-CHECK-FAIL solanaReadonlyDataRefused.ms:30:
// GUARD-CHECK-FAIL solanaReadonlyDataRefused.ms:31:
// GUARD-CHECK-FAIL solanaReadonlyDataRefused.ms:32:
// GUARD-CHECK-FAIL solanaReadonlyDataRefused.ms:33:
// GUARD-CHECK-FAIL a read-only view never converts back to the mutable type
// The data() of an Owned<T> or a Delegated<T> is a Readonly<Ptr<T>>: a this ref method, a ref
// argument and a field write through it are refused (PARALOCK E24), where the same calls through
// a Mutable<T> compile.
// RED MEANS: the checker let a write through a read-only account view, so a program writes an
// account it did not claim writable.
import { Pubkey, ProgramError, Discriminator, Mutable, Owned, Delegated, accountDiscriminator, failWith, mutable, owned, delegated } from "std/solana";

export struct Pet {
	hearts: uint64;
	owner: Pubkey;
}

export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Pet"); };
}

function heal(this ref p: Pet): void { p.hearts = p.hearts + 1; }
function grow(ref p: Pet): void { p.hearts = 9; }
function look(this p: Readonly<Pet>): uint64 { return p.hearts; }

function refused(proof: Owned<Pet>, rolled: Delegated<Pet>): void {
	proof.data()[].heal();
	grow(proof.data()[]);
	rolled.data()[].heal();
	grow(rolled.data()[]);
	rolled.data()[].hearts = 3;
}

function allowed(mine: Mutable<Pet>, proof: Owned<Pet>): uint64 {
	mine.data()[].heal();
	grow(mine.data()[]);
	return proof.data()[].look() + proof.data()[].hearts;
}

function main(): void {
	const a = owned<Pet>(0);
	const b = delegated<Pet>(1);
	const c = mutable<Pet>(2);
	if (!a.ok || !b.ok || !c.ok) { failWith(ProgramError.invalidArgument()); return; }
	refused(a.value, b.value);
	allowed(c.value, a.value);
}

main();
