// GUARD-OS solana
// GUARD-CHECK-FAIL discriminator(this typeof Pet) does not hash its own name: write accountDiscriminator("Pet")
// GUARD-CHECK-FAIL discriminator(this typeof Hen) does not hash its own name: write accountDiscriminator("Hen")
// A discriminator(this typeof Y) that returns accountDiscriminator("X") with X not Y gives Y the
// discriminator of another account type, so one type's bytes would pass as the other's. It is
// refused where a proof, a create or a createPda first uses Y, for each of those sites.
// RED MEANS: owned<Y>, mutable<Y>, delegated<Y>, create<Y> or createPda<Y> accepted a
// discriminator copied from another type.
import {
	Discriminator,
	ProgramError,
	Writable,
	WritableSigner,
	accountDiscriminator,
	accounts,
	create,
	failWith,
	owned,
} from "std/solana";

export struct Pet { value: uint64; }
export struct Cat { value: uint64; }
export struct Hen { value: uint64; }

export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Cat"); };
}

export function discriminator(this typeof Cat): Discriminator {
	return @comptime { return accountDiscriminator("Cat"); };
}

export function discriminator(this typeof Hen): Discriminator {
	return @comptime { return accountDiscriminator("Cat"); };
}

export struct Fresh {
	payer: WritableSigner;
	target: Writable;
}

function run(): Result<uint64, ProgramError> {
	const control = try owned<Cat>(0);
	const pet = try owned<Pet>(1); // GUARD-REFUSED
	const x = try accounts<Fresh>();
	const made = try create<Hen>(x.payer, x.target); // GUARD-REFUSED
	return Result.ok(control.data().value + pet.data().value + made.data().value);
}

const result = run();
if (!result.ok) { failWith(result.error); }
