import { Pubkey } from "./pubkey";
import { ProgramError } from "./error";
import { ProgramAddress } from "./pda";
import { msSolDeriveAddress, msSolFindAddress, msSolFindCanonicalAddress, msSolFindCanonicalStaged, msSolFindExpectedAddress, msSolFindExpectedStaged, msSolHashIsStaged, msSolSeedStageInPlace } from "./kernel";
import { SeedSlice, SignerSeeds } from "./addressTables";
import { msSolCopy, msSolLoadU64, msSolProgramId, msSolSeedRowSet, msSolSeedsAddress, msSolSignersAddress, msSolSpanAddress, msSolStringAddress, msSolStringLength, msSolTableAddress } from "./memory";

export { SeedSlice, SignerSeeds } from "./addressTables";

const MAX_SEEDS: uint64 = 16;
const MAX_SEED_LENGTH: uint64 = 32;
const NO_BUMP: uint64 = 256;

export struct Signing {
	table: uint64;
	count: uint64;
}

export struct SeedTable {
	slices: SeedSlice[16];
	bump: uint8[1];
	count: uint64;
}

export function seedText(text: string): SeedSlice {
	return { address: msSolStringAddress(text), length: msSolStringLength(text) };
}

export function seedBytes(bytes: Readonly<Span<uint8>>): SeedSlice {
	return { address: msSolSpanAddress(bytes), length: bytes.length as uint64 };
}

export function seedKey(address: uint64): SeedSlice {
	return { address: address, length: 32 };
}

@inline export function seedFree(): SeedSlice {
	return { address: 0, length: 0 };
}

export function signerOf(seeds: Readonly<Span<SeedSlice>>): SignerSeeds {
	return { address: msSolSeedsAddress(seeds), length: seeds.length as uint64 };
}

function unsigned(): Signing {
	return { table: 0, count: 0 };
}

export function tableAddress(table: Readonly<Span<SeedSlice>>): uint64 {
	return msSolSeedsAddress(table);
}

export function bytesAddress(bytes: Readonly<Span<uint8>>): uint64 {
	return msSolSpanAddress(bytes);
}

export function ownProgram(): uint64 {
	return msSolProgramId();
}

@inline export function stagedInPlace(seeds: Readonly<Span<SeedSlice>>, bump: Readonly<Span<uint8>>): uint64 {
	return msSolSeedStageInPlace(msSolSeedsAddress(seeds), seeds.length as uint64, msSolSpanAddress(bump), msSolProgramId());
}

function fits(table: uint64, count: uint64, limit: uint64): boolean {
	if (count > limit) { return false; }
	for (let index: uint64 = 0; index < count; index++) {
		if (msSolLoadU64(table + index * 16 + 8) > MAX_SEED_LENGTH) { return false; }
	}
	return true;
}

export function signingOf(signers: Readonly<Span<SignerSeeds>>): Signing {
	if (signers.length == 0) { return unsigned(); }
	return { table: msSolSignersAddress(signers), count: signers.length as uint64 };
}

function derivedKey(code: uint64, key: Pubkey): Result<Pubkey, ProgramError> {
	if (code == 2) { return Result.err(ProgramError.maxSeedLengthExceeded()); }
	if (code != 0) { return Result.err(ProgramError.invalidSeeds()); }
	return Result.ok(key);
}

export function createAt(
	table: uint64,
	count: uint64,
	program: uint64,
): Result<Pubkey, ProgramError> {
	let key = Pubkey.zero();
	return derivedKey(msSolDeriveAddress(table, count, NO_BUMP, program, msSolSpanAddress(key.bytes)), key);
}

export function findAt(
	table: uint64,
	count: uint64,
	program: uint64,
): Result<ProgramAddress, ProgramError> {
	let found: ProgramAddress = { key: Pubkey.zero(), bump: 0 };
	const keyAddress = msSolSpanAddress(found.key.bytes);
	when (js) {
		let bump: uint8[1] = [];
		const code = msSolFindAddress(table, count, program, keyAddress, msSolSpanAddress(bump));
		found.bump = bump[0];
	} else {
		const code = msSolFindAddress(table, count, program, keyAddress, keyAddress + 32);
	}
	if (code == 2) { return Result.err(ProgramError.maxSeedLengthExceeded()); }
	if (code != 0) { return Result.err(ProgramError.invalidSeeds()); }
	return Result.ok(found);
}

// The failures below return a ProgramError code without a Result, so a check that only compares the key
// afterwards pays for no second wrapper. Those named Staged take the table and the count of a `SlottedSeeds`.
@inline export function hashStagedFailure(table: uint64, used: uint64, bump: uint64, expected: uint64): uint64 {
	return msSolHashIsStaged(table, used, bump, expected) == 0 ? 0 : ProgramError.constraintSeeds().code;
}

@inline function canonicalFailure(code: uint64): uint64 {
	if (code == 0) { return 0; }
	if (code == 2) { return ProgramError.maxSeedLengthExceeded().code; }
	if (code == 1) { return ProgramError.invalidSeeds().code; }
	return ProgramError.constraintSeeds().code;
}

@inline export function findCanonicalFailureAt(table: uint64, count: uint64, program: uint64, expected: uint64, bumpOut: uint64): uint64 {
	return canonicalFailure(msSolFindCanonicalAddress(table, count, program, expected, bumpOut));
}

@inline export function findCanonicalStagedFailure(table: uint64, used: uint64, expected: uint64): uint64 {
	return canonicalFailure(msSolFindCanonicalStaged(table, used, expected));
}

export function findExpected(
	seeds: Readonly<Span<SeedSlice>>,
	program: uint64,
	expected: uint64,
): Result<uint8, ProgramError> {
	let bump: uint8[1] = [0];
	const code = msSolFindExpectedAddress(tableAddress(seeds), seeds.length as uint64, program, expected, msSolSpanAddress(bump));
	if (code == 2) { return Result.err(ProgramError.maxSeedLengthExceeded()); }
	if (code != 0) { return Result.err(ProgramError.invalidSeeds()); }
	return Result.ok(bump[0]);
}

@inline export function findExpectedStagedFailure(table: uint64, used: uint64, expected: uint64): uint64 {
	const code = msSolFindExpectedStaged(table, used, expected);
	if (code == 2) { return ProgramError.maxSeedLengthExceeded().code; }
	return code == 0 ? 0 : ProgramError.constraintSeeds().code;
}

export function createAddress(
	seeds: Readonly<Span<SeedSlice>>,
	program: uint64,
): Result<Pubkey, ProgramError> {
	return createAt(tableAddress(seeds), seeds.length as uint64, program);
}

export function findAddress(
	seeds: Readonly<Span<SeedSlice>>,
	program: uint64,
): Result<ProgramAddress, ProgramError> {
	return findAt(tableAddress(seeds), seeds.length as uint64, program);
}

// `table` holds `used` seeds and one free slice after them, which takes the bump byte at `bump`.
export function bumpInPlace(table: uint64, used: uint64, bump: uint64): boolean {
	if (!fits(table, used, MAX_SEEDS - 1)) { return false; }
	msSolSeedRowSet(table, used, bump, 1);
	return true;
}

// The bump byte lives in the caller's table; returning the table by value would leave it dangling.
export function fillWithBump(
	ref into: SeedTable,
	table: uint64,
	count: uint64,
	bump: uint8,
): boolean {
	if (!fits(table, count, MAX_SEEDS - 1)) { return false; }
	if (count > 0) { msSolCopy(msSolTableAddress(into.slices), table, count * 16); }
	into.bump[0] = bump;
	into.slices[count] = { address: msSolSpanAddress(into.bump), length: 1 };
	into.count = count + 1;
	return true;
}

export function createAddressWithBump(
	seeds: Readonly<Span<SeedSlice>>,
	bump: uint8,
	program: uint64,
): Result<Pubkey, ProgramError> {
	let key = Pubkey.zero();
	return derivedKey(
		msSolDeriveAddress(tableAddress(seeds), seeds.length as uint64, bump as uint64, program, msSolSpanAddress(key.bytes)),
		key,
	);
}

export function signerOfBumped(ref signed: SeedTable, ref one: SignerSeeds[1]): void {
	one[0] = { address: msSolTableAddress(signed.slices), length: signed.count };
}
