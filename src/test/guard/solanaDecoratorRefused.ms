// GUARD-OS solana
// GUARD-CHECK-FAIL accounts<TwoSeeds>(): @seeds on field 'safe': @seeds is written twice
// GUARD-CHECK-FAIL accounts<NoBump>(): @seeds on field 'safe' needs @bump
// GUARD-CHECK-FAIL accounts<NoSeeds>(): @bump on field 'safe' needs @seeds before it
// GUARD-CHECK-FAIL accounts<Ghost>(): @hasOne on field 'safe': 'ghost' is not a field of Ghost
// GUARD-CHECK-FAIL accounts<Plain>(): @hasOne on field 'wallet': 'wallet' must be Owned<T>, Mutable<T> or Delegated<T> of a struct with a field 'wallet'
// GUARD-CHECK-FAIL accounts<Unknown>(): @label on field 'safe': accounts<T>() reads @seeds, @bump, @hasOne, @address, @associated, @constraint, @tokenMint and @tokenAuthority
// GUARD-CHECK-FAIL accounts<Third>(): @associated on field 'token': the token program is the mint's owner, so a third argument
// GUARD-CHECK-FAIL a mint here must be an account
// GUARD-CHECK-FAIL accounts<Unpinned>(): field 'pet' is a Delegated<T> with no @seeds/@bump or @address
// GUARD-CHECK-FAIL accounts<NotToken>(): @tokenMint on field 'wallet': the field must be External or ExternalMutable of TokenAccount or InterfaceTokenAccount
// GUARD-CHECK-FAIL accounts<Closure>(): a decorator argument of this form is not supported
// GUARD-CHECK-FAIL a key is an account or a Pubkey, and this has type
// A decorator of a struct that accounts<T>() reads is refused where the struct is declared, by
// the form it was written in: an unknown name, a pair of seeds and bump that is not a pair, a
// target that is not a field, a field without data, a token decorator on a field that is not a
// token account, a token program argument, and an argument that is not an expression of
// accounts, fields of their data, calls, operators, casts and literals.
// RED MEANS: accounts<T>() accepted a decorator it does not enforce, so a constraint written on
// the field would be silently skipped.
import {
	Account,
	Delegated,
	Discriminator,
	External,
	ExternalMutable,
	Mutable,
	ProgramError,
	Pubkey,
	Signer,
	accountDiscriminator,
	accounts,
	address,
	associated,
	bump,
	failWith,
	hasOne,
	seeds,
	tokenMint,
} from "std/solana";
import { Mint, TokenAccount } from "std/solana/token";

function label(): void {}

export struct Safe {
	owner: Pubkey;
	bump: uint8;
}

export function discriminator(this typeof Safe): Discriminator {
	return @comptime { return accountDiscriminator("Safe"); };
}

export struct TwoSeeds {
	@seeds("a") @seeds("b") @bump(safe.bump) safe: Mutable<Safe>; // GUARD-REFUSED
}

export struct NoBump {
	@seeds("a") safe: Mutable<Safe>; // GUARD-REFUSED
}

export struct NoSeeds {
	@bump(safe.bump) safe: Mutable<Safe>; // GUARD-REFUSED
}

export struct Ghost {
	@hasOne(ghost) safe: Mutable<Safe>; // GUARD-REFUSED
}

export struct Plain {
	@hasOne(wallet) wallet: Signer; // GUARD-REFUSED
}

export struct Unknown {
	@label safe: Mutable<Safe>; // GUARD-REFUSED
}

export struct Third {
	mint: External<Mint>;
	@associated(mint, mint, mint) token: ExternalMutable<TokenAccount>; // GUARD-REFUSED
}

export struct PubkeyMint {
	safe: Mutable<Safe>;
	@associated(safe.owner, safe) token: ExternalMutable<TokenAccount>; // GUARD-REFUSED
}

export struct Unpinned {
	pet: Delegated<Safe>;
}

export struct NotToken {
	@tokenMint(wallet) wallet: Signer; // GUARD-REFUSED
}

export struct NotAKey {
	@address(7) safe: Mutable<Safe>; // GUARD-REFUSED
}

export struct Closure {
	@address(() => 1) safe: Mutable<Safe>; // GUARD-REFUSED
}

function run(): Result<uint64, ProgramError> {
	const a = try accounts<TwoSeeds>();
	const b = try accounts<NoBump>();
	const c = try accounts<NoSeeds>();
	const d = try accounts<Ghost>();
	const e = try accounts<Plain>();
	const f = try accounts<Unknown>();
	const g = try accounts<Third>();
	const h = try accounts<NotToken>();
	const i = try accounts<Closure>();
	const j = try accounts<NotAKey>();
	const k = try accounts<PubkeyMint>();
	const l = try accounts<Unpinned>(); // GUARD-REFUSED
	return Result.ok(0);
}

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
}

main();
