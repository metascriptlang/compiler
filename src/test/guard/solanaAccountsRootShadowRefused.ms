// GUARD-OS solana
// GUARD-CHECK-FAIL accounts<PinnedEarly>(): accounts<T>() reads the declaration of 'PinnedEarly' by its name, and where it is called that name means another struct, 'PinnedEarly' of
// GUARD-CHECK-FAIL accounts<PinnedLate>(): accounts<T>() reads the declaration of 'PinnedLate' by its name, and where it is called that name means another struct, 'PinnedLate' of
// GUARD-CHECK-FAIL accounts<PinnedTwin>(): accounts<T>() reads the declaration of 'PinnedTwin' by its name, and where it is called that name means another struct, 'PinnedTwin' of
// GUARD-CHECK-FAIL accounts<OpenRoot>(): accounts<T>() reads the declaration of 'OpenRoot' by its name, and where it is called that name means another struct, 'OpenRoot' of
// GUARD-CHECK-FAIL accounts<PinnedLone>(): accounts<T>() reads the declaration of 'PinnedLone' by its name, and where it is called that name means another struct, 'PinnedLone' of
// GUARD-CHECK-FAIL accounts<PinnedAway>(): accounts<T>() reads the declaration of 'PinnedAway' by its name, and where it is called no struct has that name
// GUARD-CHECK-FAIL accounts<PinnedRenamed>(): accounts<T>() reads the declaration of 'PinnedRenamed' by its name, and where it is called that name is not a struct
// GUARD-CHECK-FAIL import the struct under its own name, or call accounts<T>() in the module that declares it
// accounts<T>() reads the decorators of T's fields from T's declaration, which it finds by T's
// name where it is called. It reads that declaration only when the name means T there. Each call
// below is given a struct imported under another name while its own name means something else:
// a struct this module declares (ahead of the import, after the call, with the same fields and
// decorators, with a decorator T lacks, with the one field that takes the short path), nothing,
// and a type alias, whose declaration is not the struct's.
// RED MEANS: accounts<T>() read the fields of a struct it was not given, dropped the @address,
// @seeds, @hasOne or @constraint T declares, and returned the other struct.
struct PinnedEarly { authority: Signer; target: Writable; }

import { ProgramError, Pubkey, Signer, Writable, accounts, address, failWith } from "std/solana";
import {
	OpenRoot as Open, PinnedAway as Away, PinnedEarly as Early, PinnedLate as Late, PinnedLone as Lone,
	PinnedRenamed as Renamed, PinnedTwin as Twin,
} from "./fixtures/solanaShadowedRoot";

struct PinnedTwin { @address(Pubkey.zero()) authority: Signer; target: Writable; }
struct OpenRoot { @address(Pubkey.zero()) authority: Signer; target: Writable; }
struct PinnedLone { authority: Signer; }
type PinnedRenamed = Renamed;

function run(): Result<uint64, ProgramError> {
	const early = try accounts<Early>();
	const late = try accounts<Late>();
	const twin = try accounts<Twin>();
	const open = try accounts<Open>();
	const lone = try accounts<Lone>();
	const away = try accounts<Away>();
	const renamed = try accounts<Renamed>();
	return Result.ok(early.authority.lamports() + late.authority.lamports() + twin.authority.lamports() +
		open.authority.lamports() + lone.authority.lamports() + away.authority.lamports() +
		renamed.authority.lamports());
}

struct PinnedLate { authority: Signer; target: Writable; }

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
}

main();
