// GUARD-OS solana
// GUARD-CHECK-FAIL accounts<EarlyChild>(): 'EarlyChild' extends 'PinnedEarly', whose fields accounts<T>() cannot read: 'PinnedEarly' names the struct 'PinnedEarly' of
// GUARD-CHECK-FAIL accounts<LateChild>(): 'LateChild' extends 'PinnedLate', whose fields accounts<T>() cannot read: 'PinnedLate' names the struct 'PinnedLate' of
// GUARD-CHECK-FAIL accounts<OpenChild>(): 'OpenChild' extends 'OpenBase', whose fields accounts<T>() cannot read: 'OpenBase' names the struct 'OpenBase' of
// GUARD-CHECK-FAIL accounts<PinnedLeaf>(): 'PinnedMiddle' extends 'PinnedRoot', whose fields accounts<T>() cannot read: 'PinnedRoot' names the struct 'PinnedRoot' of
// GUARD-CHECK-FAIL accounts<NamedChild>(): 'NamedChild' extends 'PinnedNamed', whose fields accounts<T>() cannot read: 'PinnedNamed' names the struct 'Decoy' of
// GUARD-CHECK-FAIL accounts<Borrowed>(): 'Borrowed' extends 'FarBase', whose fields accounts<T>() cannot read: 'FarBase' names the struct 'FarBase' of
// GUARD-CHECK-FAIL field 'vault' holds 'Owned<KeptChild>', and 'KeptChild' extends 'KeptBase', whose fields accounts<T>() cannot read: 'KeptBase' names the struct 'KeptBase' of
// GUARD-CHECK-FAIL which may not be the base
// GUARD-CHECK-FAIL accounts<AliasChild>(): 'AliasChild' extends 'AliasBase', whose fields accounts<T>() cannot read: 'AliasBase' is not a struct where accounts<T>() is called
// GUARD-CHECK-FAIL local struct 'NearBase' is not supported yet
// accounts<T>() reads the decorators of an inherited field from the base's declaration, which it
// finds by the base's name where it is called. It reads that declaration only when the name can
// mean one struct: accounts<T>() is called in the module that declares the extending struct, or
// the struct the name finds is declared in that module under that name. Each call below finds
// another struct: one this module declares (ahead of the import, after the call, with a decorator
// the base lacks, two structs up, under the data struct of an account), another struct of the
// declaring module imported under the base's name, and the base itself when the declaring module
// imports it, which a struct of that name from anywhere else cannot be told from. The last two tags
// are what the first case stands on: within one module a base name means one struct, because a
// function cannot declare a struct under a name that is already visible, and what it can declare
// under that name, an alias, is not read as the base.
// RED MEANS: accounts<T>() read a base's fields from a struct the extending struct was not
// declared with, and dropped the @address, @seeds, @hasOne or @constraint its real base declares.
struct PinnedEarly { authority: Signer; }

import {
	Owned, ProgramError, Pubkey, Signer, Writable, accounts, address, failWith, hasOne,
} from "std/solana";
import { FarBase } from "./fixtures/solanaFarBase";
import {
	Borrowed, Decoy as PinnedNamed, EarlyChild, KeptChild, LateChild, NamedChild, OpenChild, PinnedLeaf, PinnedMiddle,
} from "./fixtures/solanaShadowedBase";

struct OpenBase { @address(Pubkey.zero()) authority: Signer; }
struct PinnedRoot { authority: Signer; }
struct KeptBase { owner: Pubkey; }

struct KeptAccounts {
	owner: Signer;
	@hasOne(owner) vault: Owned<KeptChild>; // GUARD-REFUSED
}

struct NearBase { @address(Pubkey.zero()) authority: Signer; }
struct NearChild extends NearBase { target: Writable; }

struct AliasBase { @address(Pubkey.zero()) authority: Signer; }
struct AliasChild extends AliasBase { target: Writable; }
struct Unpinned { authority: Signer; }

function aliased(): Result<uint64, ProgramError> {
	type AliasBase = Unpinned;
	const x = try accounts<AliasChild>(); // GUARD-REFUSED
	return Result.ok(x.authority.lamports());
}

function near(): Result<uint64, ProgramError> {
	struct NearBase { authority: Signer; }
	const x = try accounts<NearChild>();
	return Result.ok(x.authority.lamports());
}

function run(): Result<uint64, ProgramError> {
	const early = try accounts<EarlyChild>(); // GUARD-REFUSED
	const late = try accounts<LateChild>(); // GUARD-REFUSED
	const open = try accounts<OpenChild>(); // GUARD-REFUSED
	const leaf = try accounts<PinnedLeaf>(); // GUARD-REFUSED
	const named = try accounts<NamedChild>(); // GUARD-REFUSED
	const borrowed = try accounts<Borrowed>(); // GUARD-REFUSED
	const kept = try accounts<KeptAccounts>();
	return Result.ok(early.authority.lamports() + late.authority.lamports() + open.authority.lamports() +
		leaf.authority.lamports() + named.authority.lamports() + borrowed.owner.lamports() + kept.vault.data().limit);
}

struct PinnedLate { authority: Signer; }

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
	const local = near();
	if (!local.ok) { failWith(local.error); }
	const renamed = aliased();
	if (!renamed.ok) { failWith(renamed.error); }
}

main();
