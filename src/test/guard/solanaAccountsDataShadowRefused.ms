// GUARD-OS solana
// GUARD-CHECK-FAIL accounts<EarlyTake>(): field 'vault' holds 'Owned<EarlyVault>', and where accounts<T>() is called 'EarlyVault' means another type, 'EarlyVault' of
// GUARD-CHECK-FAIL accounts<LateTake>(): field 'vault' holds 'Mutable<LateVault>', and where accounts<T>() is called 'LateVault' means another type, 'LateVault' of
// GUARD-CHECK-FAIL accounts<ThinTake>(): field 'vault' holds 'Owned<ThinVault>', and where accounts<T>() is called 'ThinVault' means another type, 'ThinVault' of
// GUARD-CHECK-FAIL accounts<PlainTake>(): field 'vault' holds 'Owned<PlainVault>', and where accounts<T>() is called 'PlainVault' means another type, 'PlainVault' of
// GUARD-CHECK-FAIL accounts<TwinTake>(): field 'vault' holds 'Owned<TwinVault>', and where accounts<T>() is called 'TwinVault' means another type, 'TwinVault' of
// GUARD-CHECK-FAIL accounts<HeldTake>(): field 'vault' holds 'Delegated<HeldVault>', and where accounts<T>() is called 'HeldVault' means another type, 'HeldVault' of
// GUARD-CHECK-FAIL accounts<HolderChild>(): field 'vault' holds 'Owned<BaseVault>', and where accounts<T>() is called 'BaseVault' means another type, 'BaseVault' of
// GUARD-CHECK-FAIL accounts<Feed>(): field 'oracle' holds 'Program<Oracle>', and where accounts<T>() is called 'Oracle' means another type, 'Oracle' of
// GUARD-CHECK-FAIL import the 'EarlyVault' the field was declared with under that name, or call accounts<T>() in the module that declares the field
// accounts<T>() names the type argument of a field (the data of Owned<T>, Mutable<T> and
// Delegated<T>, the program of Program<P>) where it is called: it reads the data struct's
// declaration for @hasOne and for a decorator that names a data field, and it writes the name in
// the code that verifies the account. It does so only when the name means there the type the
// field was declared with. Each call below is given a struct of another module while this module
// declares the argument's name: ahead of the import with the same fields at other offsets, after
// the call, with a field the real struct lacks and @hasOne names, under a field no decorator
// reads, with the same fields beside the real struct imported under another name, under
// Delegated<T>, under a field a base declares, and as a program.
// RED MEANS: accounts<T>() resolved a decorator against the fields of a struct the account does
// not hold, or verified the account as another type than the one its proof carries.
struct EarlyVault { limit: uint64; owner: Pubkey; }

import { ProgramError, Pubkey, accounts, failWith } from "std/solana";
import {
	EarlyTake, Feed, HeldTake, HolderBase, HolderChild, LateTake, PlainTake, ThinTake, TwinTake, TwinVault as RealTwin,
} from "./fixtures/solanaShadowedData";

struct ThinVault { owner: Pubkey; limit: uint64; }
struct PlainVault { small: uint8; }
struct TwinVault { owner: Pubkey; limit: uint64; }
struct HeldVault { owner: Pubkey; }
struct BaseVault { owner: uint64; }
struct Oracle {}

function twinSize(): uint64 { return sizeof(RealTwin) as uint64; }

function run(): Result<uint64, ProgramError> {
	const early = try accounts<EarlyTake>();
	const late = try accounts<LateTake>();
	const thin = try accounts<ThinTake>();
	const plain = try accounts<PlainTake>();
	const twin = try accounts<TwinTake>();
	const held = try accounts<HeldTake>();
	const child = try accounts<HolderChild>();
	const feed = try accounts<Feed>();
	return Result.ok(early.owner.lamports() + late.owner.lamports() + thin.owner.lamports() + plain.owner.lamports() +
		twinSize() + twin.owner.lamports() + held.owner.lamports() + child.owner.lamports() + feed.owner.lamports());
}

struct LateVault { limit: uint8; }

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
}

main();
