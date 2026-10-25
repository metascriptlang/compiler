// GUARD-OS solana
// GUARD-CHECK-FAIL emit<Paid>(value): 'refund' is a Refunded, not a Paid
// GUARD-CHECK-FAIL emit<Paid>(value): 'twin' is a PaidTwin, not a Paid
// GUARD-CHECK-FAIL emit<Paid>(value): 'tipped' is a PaidWithTip, not a Paid
// GUARD-CHECK-FAIL emit<Paid>(value): 'amount' is a uint64, not a Paid
// GUARD-CHECK-FAIL emit<Paid>(value): 'stored' is a Refunded, not a Paid
// emit<E>(value) writes E's discriminator and reads E's fields off the value, so the value is an E
// or a pointer to one: a wider struct, one with the same fields under another name, a struct that
// extends E, a number and a pointer to another struct are each refused.
// RED MEANS: emit<E>() logged a value of another type under E's discriminator and layout.
import { Discriminator, ProgramError, Pubkey, accountDiscriminator, emit, failWith, owned } from "std/solana";

export struct Paid { amount: uint64; }
export struct Refunded { amount: uint64; receiver: Pubkey; }
export struct PaidTwin { amount: uint64; }
export struct PaidWithTip extends Paid { tip: uint64; }

export function discriminator(this typeof Paid): Discriminator {
	return @comptime { return accountDiscriminator("Paid"); };
}

export function discriminator(this typeof Refunded): Discriminator {
	return @comptime { return accountDiscriminator("Refunded"); };
}

function run(): Result<uint64, ProgramError> {
	const paid: Paid = { amount: 1 };
	const refund: Refunded = { amount: 2, receiver: Pubkey.zero() };
	const twin: PaidTwin = { amount: 3 };
	const tipped: PaidWithTip = { amount: 4, tip: 5 };
	const amount: uint64 = 6;
	emit<Paid>(paid);
	emit<Paid>(refund); // GUARD-REFUSED
	emit<Paid>(twin); // GUARD-REFUSED
	emit<Paid>(tipped); // GUARD-REFUSED
	emit<Paid>(amount); // GUARD-REFUSED
	const held = try owned<Paid>(0);
	const kept = held.data();
	emit<Paid>(kept);
	const other = try owned<Refunded>(1);
	const stored = other.data();
	emit<Paid>(stored); // GUARD-REFUSED
	return Result.ok(0);
}

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
}

main();
