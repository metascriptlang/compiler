import { msSolLoadU64, msSolSpanAddress, msSolStoreU64, msSolStoreU8, msSolStringAddress, msSolStringLength, msSolWordsAddress } from "./memory";
import { msSolHostCurveValidatePoint, msSolHostSha256 } from "./simulatorCrypto";

const MAX_SEEDS: uint64 = 16;
const MAX_SEED_LENGTH: uint64 = 32;
const TAG: string = "ProgramDerivedAddress";

function putSlice(table: uint64, at: uint64, address: uint64, length: uint64): void {
	msSolStoreU64(table + at * 16, address);
	msSolStoreU64(table + at * 16 + 8, length);
}

// solana.h msSolSeedStage
function stage(input: uint64, table: uint64, count: uint64, limit: uint64): boolean {
	if (count > limit) { return false; }
	for (let index: uint64 = 0; index < count; index++) {
		const length = msSolLoadU64(table + index * 16 + 8);
		if (length > MAX_SEED_LENGTH) { return false; }
		putSlice(input, index, msSolLoadU64(table + index * 16), length);
	}
	return true;
}

// solana.h msSolSeedTail
function tail(input: uint64, at: uint64, program: uint64): uint64 {
	putSlice(input, at, program, 32);
	putSlice(input, at + 1, msSolStringAddress(TAG), msSolStringLength(TAG));
	return at + 2;
}

// solana.h msSolSeedSlot
function slot(input: uint64, at: uint64, bump: uint64, program: uint64): void {
	putSlice(input, at, bump, 1);
	tail(input, at + 1, program);
}

// solana.h msSolKeyIs
function keyIs(key: uint64, expected: uint64): boolean {
	return msSolLoadU64(key) == msSolLoadU64(expected) && msSolLoadU64(key + 8) == msSolLoadU64(expected + 8) &&
		msSolLoadU64(key + 16) == msSolLoadU64(expected + 16) && msSolLoadU64(key + 24) == msSolLoadU64(expected + 24);
}

function offCurve(point: uint64): boolean {
	return msSolHostCurveValidatePoint(0, point, 0) != 0;
}

// solana.h msSolWalkAny
function walkAny(input: uint64, at: uint64, out: uint64, bumpOut: uint64): uint64 {
	for (let counter: uint64 = 255; counter > 0; counter--) {
		msSolStoreU8(bumpOut, counter as uint8);
		msSolHostSha256(input, at + 3, out);
		if (offCurve(out)) { return 0; }
	}
	return 1;
}

// solana.h msSolWalkExpected
function walkExpected(input: uint64, at: uint64, expected: uint64, bumpOut: uint64): uint64 {
	let hash: uint8[32] = [];
	const out = msSolSpanAddress(hash);
	for (let counter: uint64 = 255; counter > 0; counter--) {
		msSolStoreU8(bumpOut, counter as uint8);
		msSolHostSha256(input, at + 3, out);
		if (keyIs(out, expected)) { return 0; }
		if (offCurve(out)) { return 1; }
	}
	return 1;
}

// solana.h msSolWalkCanonical
function walkCanonical(input: uint64, at: uint64, expected: uint64, bumpOut: uint64): uint64 {
	let hash: uint8[32] = [];
	const out = msSolSpanAddress(hash);
	for (let counter: uint64 = 255; counter > 0; counter--) {
		msSolStoreU8(bumpOut, counter as uint8);
		msSolHostSha256(input, at + 3, out);
		if (offCurve(out)) { return keyIs(out, expected) ? 0 : 3; }
	}
	return 1;
}

// solana.h msSolSeedStageInPlace
export function seedStageInPlace(table: uint64, count: uint64, bump: uint64, program: uint64): uint64 {
	const used = count - 3;
	if (count < 3 || !stage(table, table, used, MAX_SEEDS - 1)) { return MAX_SEEDS; }
	slot(table, used, bump, program);
	return used;
}

// solana.h msSolHashAddress
function hashAddress(table: uint64, count: uint64, bump: uint64, program: uint64, out: uint64): uint64 {
	let words: uint64[36] = [];
	let last: uint8[1] = [];
	const input = msSolWordsAddress(words);
	last[0] = bump as uint8;
	const withBump: uint64 = bump <= 255 ? 1 : 0;
	if (!stage(input, table, count, MAX_SEEDS - withBump)) { return 2; }
	if (withBump != 0) { putSlice(input, count, msSolSpanAddress(last), 1); }
	msSolHostSha256(input, tail(input, count + withBump, program), out);
	return 0;
}

// solana.h msSolDeriveAddress
export function deriveAddress(table: uint64, count: uint64, bump: uint64, program: uint64, out: uint64): uint64 {
	if (hashAddress(table, count, bump, program, out) != 0) { return 2; }
	return offCurve(out) ? 0 : 1;
}

// solana.h msSolFindAddress
export function findAddress(table: uint64, count: uint64, program: uint64, out: uint64, bumpOut: uint64): uint64 {
	let words: uint64[36] = [];
	const input = msSolWordsAddress(words);
	if (!stage(input, table, count, MAX_SEEDS - 1)) { return 2; }
	slot(input, count, bumpOut, program);
	return walkAny(input, count, out, bumpOut);
}

// solana.h msSolFindExpectedAddress
export function findExpectedAddress(table: uint64, count: uint64, program: uint64, expected: uint64, bumpOut: uint64): uint64 {
	let words: uint64[36] = [];
	const input = msSolWordsAddress(words);
	if (!stage(input, table, count, MAX_SEEDS - 1)) { return 2; }
	slot(input, count, bumpOut, program);
	return walkExpected(input, count, expected, bumpOut);
}

// solana.h msSolFindCanonicalAddress
export function findCanonicalAddress(table: uint64, count: uint64, program: uint64, expected: uint64, bumpOut: uint64): uint64 {
	let words: uint64[36] = [];
	const input = msSolWordsAddress(words);
	if (!stage(input, table, count, MAX_SEEDS - 1)) { return 2; }
	slot(input, count, bumpOut, program);
	return walkCanonical(input, count, expected, bumpOut);
}

// solana.h msSolFindExpectedStaged
export function findExpectedStaged(table: uint64, used: uint64, expected: uint64): uint64 {
	if (used >= MAX_SEEDS) { return 2; }
	return walkExpected(table, used, expected, msSolLoadU64(table + used * 16));
}

// solana.h msSolFindCanonicalStaged
export function findCanonicalStaged(table: uint64, used: uint64, expected: uint64): uint64 {
	if (used >= MAX_SEEDS) { return 2; }
	return walkCanonical(table, used, expected, msSolLoadU64(table + used * 16));
}

// solana.h msSolHashIsStaged
export function hashIsStaged(table: uint64, used: uint64, bump: uint64, expected: uint64): uint64 {
	let hash: uint8[32] = [];
	if (used >= MAX_SEEDS) { return 2; }
	msSolStoreU8(msSolLoadU64(table + used * 16), bump as uint8);
	const out = msSolSpanAddress(hash);
	msSolHostSha256(table, used + 3, out);
	return keyIs(out, expected) ? 0 : 3;
}
