import { msSolLoadU64, msSolSeedRowAddress, msSolSeedRowLength, msSolSeedRowSet, msSolSpanAddress, msSolStoreU8, msSolStringAddress, msSolStringLength, msSolWordsAddress } from "./memory";

when (solana) {
	@include("runtime/solana/solana.h");

	extern function msSolSha256(slices: uint64, count: uint64, out: uint64): uint64;
	extern function msSolCurveValidatePoint(curve: uint64, point: uint64, result: uint64): uint64;
}

when (!solana) {
	import { msSolHostCurveValidatePoint as msSolCurveValidatePoint, msSolHostSha256 as msSolSha256 } from "./simulatorCrypto";
}

const MAX_SEEDS: uint64 = 16;
const MAX_SEED_LENGTH: uint64 = 32;

@inline function putSlice(table: uint64, at: uint64, address: uint64, length: uint64): void {
	msSolSeedRowSet(table, at, address, length);
}

// solana.h msSolSeedStage
@inline function stage(input: uint64, table: uint64, count: uint64, limit: uint64): boolean {
	if (count > limit) { return false; }
	for (let index: uint64 = 0; index < count; index++) {
		const length = msSolSeedRowLength(table, index);
		if (length > MAX_SEED_LENGTH) { return false; }
		putSlice(input, index, msSolSeedRowAddress(table, index), length);
	}
	return true;
}

@inline function lengthsFit(table: uint64, count: uint64, limit: uint64): boolean {
	if (count > limit) { return false; }
	let longest: uint64 = 0;
	for (let index: uint64 = 0; index < count; index++) {
		const length = msSolSeedRowLength(table, index);
		if (length > longest) { longest = length; }
	}
	return longest <= MAX_SEED_LENGTH;
}

// solana.h msSolSeedTail
@inline function tail(input: uint64, at: uint64, program: uint64): uint64 {
	putSlice(input, at, program, 32);
	const tag = "ProgramDerivedAddress";
	putSlice(input, at + 1, msSolStringAddress(tag), msSolStringLength(tag));
	return at + 2;
}

// solana.h msSolSeedSlot
@inline function slot(input: uint64, at: uint64, bump: uint64, program: uint64): void {
	putSlice(input, at, bump, 1);
	tail(input, at + 1, program);
}

// solana.h msSolKeyIs
@inline function keyIs(key: uint64, expected: uint64): boolean {
	return msSolLoadU64(key) == msSolLoadU64(expected) && msSolLoadU64(key + 8) == msSolLoadU64(expected + 8) &&
		msSolLoadU64(key + 16) == msSolLoadU64(expected + 16) && msSolLoadU64(key + 24) == msSolLoadU64(expected + 24);
}

@inline function offCurve(point: uint64): boolean {
	return msSolCurveValidatePoint(0, point, 0) != 0;
}

// solana.h msSolWalkAny
@noinline function walkAny(input: uint64, at: uint64, out: uint64, bumpOut: uint64): uint64 {
	for (let counter: uint64 = 255; counter > 0; counter--) {
		msSolStoreU8(bumpOut, counter as uint8);
		msSolSha256(input, at + 3, out);
		if (offCurve(out)) { return 0; }
	}
	return 1;
}

// solana.h msSolWalkExpected
@inline function walkExpected(input: uint64, at: uint64, expected: uint64, bumpOut: uint64, out: uint64): uint64 {
	for (let counter: uint64 = 255; counter > 0; counter--) {
		msSolStoreU8(bumpOut, counter as uint8);
		msSolSha256(input, at + 3, out);
		if (keyIs(out, expected)) { return 0; }
		if (offCurve(out)) { return 1; }
	}
	return 1;
}

// solana.h msSolWalkCanonical
@inline function walkCanonical(input: uint64, at: uint64, expected: uint64, bumpOut: uint64, out: uint64): uint64 {
	for (let counter: uint64 = 255; counter > 0; counter--) {
		msSolStoreU8(bumpOut, counter as uint8);
		msSolSha256(input, at + 3, out);
		if (offCurve(out)) { return keyIs(out, expected) ? 0 : 3; }
	}
	return 1;
}

// solana.h msSolSeedStageInPlace
@exportName("msSolSeedStageInPlaceAt")
export function seedStageInPlace(table: uint64, count: uint64, bump: uint64, program: uint64): uint64 {
	const used = count - 3;
	if (count < 3 || !lengthsFit(table, used, MAX_SEEDS - 1)) { return MAX_SEEDS; }
	slot(table, used, bump, program);
	return used;
}

// solana.h msSolHashAddress; `input` is a frame of 36 words
@inline function hashAddress(input: uint64, last: uint64, table: uint64, count: uint64, bump: uint64, program: uint64, out: uint64): uint64 {
	msSolStoreU8(last, bump as uint8);
	const withBump: uint64 = bump <= 255 ? 1 : 0;
	if (!stage(input, table, count, MAX_SEEDS - withBump)) { return 2; }
	if (withBump != 0) { putSlice(input, count, last, 1); }
	msSolSha256(input, tail(input, count + withBump, program), out);
	return 0;
}

// solana.h msSolDeriveAddress over the caller's frame
@exportName("msSolDeriveAddressAt")
export function deriveAddressAt(input: uint64, last: uint64, table: uint64, count: uint64, bump: uint64, program: uint64, out: uint64): uint64 {
	if (hashAddress(input, last, table, count, bump, program, out) != 0) { return 2; }
	return offCurve(out) ? 0 : 1;
}

@inline export function deriveAddress(table: uint64, count: uint64, bump: uint64, program: uint64, out: uint64): uint64 {
	let words: uint64[36] = [];
	let last: uint8[1] = [];
	return deriveAddressAt(msSolWordsAddress(words), msSolSpanAddress(last), table, count, bump, program, out);
}

// solana.h msSolFindAddress over the caller's frame
@exportName("msSolFindAddressAt")
export function findAddressAt(input: uint64, table: uint64, count: uint64, program: uint64, out: uint64, bumpOut: uint64): uint64 {
	if (!stage(input, table, count, MAX_SEEDS - 1)) { return 2; }
	slot(input, count, bumpOut, program);
	return walkAny(input, count, out, bumpOut);
}

@inline export function findAddress(table: uint64, count: uint64, program: uint64, out: uint64, bumpOut: uint64): uint64 {
	let words: uint64[36] = [];
	return findAddressAt(msSolWordsAddress(words), table, count, program, out, bumpOut);
}

// solana.h msSolFindExpectedAddress over the caller's frame
@exportName("msSolFindExpectedAddressAt")
export function findExpectedAddressAt(input: uint64, hash: uint64, table: uint64, count: uint64, program: uint64, expected: uint64, bumpOut: uint64): uint64 {
	if (!stage(input, table, count, MAX_SEEDS - 1)) { return 2; }
	slot(input, count, bumpOut, program);
	return walkExpected(input, count, expected, bumpOut, hash);
}

@inline export function findExpectedAddress(table: uint64, count: uint64, program: uint64, expected: uint64, bumpOut: uint64): uint64 {
	let words: uint64[36] = [];
	let hash: uint8[32] = [];
	return findExpectedAddressAt(msSolWordsAddress(words), msSolSpanAddress(hash), table, count, program, expected, bumpOut);
}

// solana.h msSolFindCanonicalAddress over the caller's frame
@exportName("msSolFindCanonicalAddressAt")
export function findCanonicalAddressAt(input: uint64, hash: uint64, table: uint64, count: uint64, program: uint64, expected: uint64, bumpOut: uint64): uint64 {
	if (!stage(input, table, count, MAX_SEEDS - 1)) { return 2; }
	slot(input, count, bumpOut, program);
	return walkCanonical(input, count, expected, bumpOut, hash);
}

@inline export function findCanonicalAddress(table: uint64, count: uint64, program: uint64, expected: uint64, bumpOut: uint64): uint64 {
	let words: uint64[36] = [];
	let hash: uint8[32] = [];
	return findCanonicalAddressAt(msSolWordsAddress(words), msSolSpanAddress(hash), table, count, program, expected, bumpOut);
}

// solana.h msSolFindExpectedStaged
@exportName("msSolFindExpectedStagedAt")
export function findExpectedStagedAt(hash: uint64, table: uint64, used: uint64, expected: uint64): uint64 {
	if (used >= MAX_SEEDS) { return 2; }
	return walkExpected(table, used, expected, msSolLoadU64(table + used * 16), hash);
}

@inline export function findExpectedStaged(table: uint64, used: uint64, expected: uint64): uint64 {
	let hash: uint8[32] = [];
	return findExpectedStagedAt(msSolSpanAddress(hash), table, used, expected);
}

// solana.h msSolFindCanonicalStaged
@exportName("msSolFindCanonicalStagedAt")
export function findCanonicalStagedAt(hash: uint64, table: uint64, used: uint64, expected: uint64): uint64 {
	if (used >= MAX_SEEDS) { return 2; }
	return walkCanonical(table, used, expected, msSolLoadU64(table + used * 16), hash);
}

@inline export function findCanonicalStaged(table: uint64, used: uint64, expected: uint64): uint64 {
	let hash: uint8[32] = [];
	return findCanonicalStagedAt(msSolSpanAddress(hash), table, used, expected);
}

// solana.h msSolHashIsStaged
@exportName("msSolHashIsStagedAt")
export function hashIsStagedAt(out: uint64, table: uint64, used: uint64, bump: uint64, expected: uint64): uint64 {
	if (used >= MAX_SEEDS) { return 2; }
	msSolStoreU8(msSolLoadU64(table + used * 16), bump as uint8);
	msSolSha256(table, used + 3, out);
	return keyIs(out, expected) ? 0 : 3;
}

@inline export function hashIsStaged(table: uint64, used: uint64, bump: uint64, expected: uint64): uint64 {
	let hash: uint8[32] = [];
	return hashIsStagedAt(msSolSpanAddress(hash), table, used, bump, expected);
}
