import { SeedSlice } from "./addressTables";
import { msSolLoadU8, msSolSpanAddress, msSolTableAddress } from "./memory";
import {
	deriveAddress,
	findAddress,
	findCanonicalAddress,
	findCanonicalStaged,
	findExpectedAddress,
	findExpectedStaged,
	hashIsStaged,
	seedStageInPlace,
} from "./simulatorSeeds";
import { derivedDigest, findAddress as walkedAddress, isOffCurve } from "./simulatorCryptoCore";

when (c) {
	import {
		msSolDeriveAddress,
		msSolFindAddress,
		msSolFindCanonicalAddress,
		msSolFindCanonicalStaged,
		msSolFindExpectedAddress,
		msSolFindExpectedStaged,
		msSolHashIsStaged,
		msSolSeedStageInPlace,
	} from "./kernel";
}

const POOL_STRIDE = 40;

let failure = "";

function expect(held: boolean, what: string): void {
	if (!held && failure == "") { failure = what; }
}

function seedBytes(count: int32, length: int32): uint8[] {
	const bytes: uint8[] = [];
	for (let at = 0; at < count; at++) {
		for (let k = 0; k < length; k++) { bytes.push((at * 31 + k * 7 + 3) as uint8); }
	}
	return bytes;
}

function fillSeeds(pool: Span<uint8>, table: Span<SeedSlice>, count: int32, length: int32): void {
	const base = msSolSpanAddress(pool);
	for (let at = 0; at < count; at++) {
		for (let k = 0; k < length; k++) { pool[at * POOL_STRIDE + k] = (at * 31 + k * 7 + 3) as uint8; }
		table[at] = { address: base + ((at * POOL_STRIDE) as uint64), length: length as uint64 };
	}
}

function code(ok: boolean): uint64 {
	return ok ? 0 : 1;
}

function sameBytes(left: Readonly<Span<uint8>>, right: Readonly<Span<uint8>>): boolean {
	for (let at = 0; at < left.length; at++) { if (left[at] != right[at]) { return false; } }
	return left.length == right.length;
}

function agree(count: int32, length: int32): void {
	let pool: uint8[704] = [];
	let program: uint8[32] = [];
	for (let k = 0; k < 32; k++) { program[k] = (k + 1) as uint8; }
	let table: SeedSlice[19] = [];
	fillSeeds(pool, table, count, length);
	const at = msSolTableAddress(table);
	const programAt = msSolSpanAddress(program);
	const refused = count > 16 || length > 32;
	const joined = seedBytes(refused ? 0 : count, length);

	let found: uint8[32] = [];
	let bump: uint8[1] = [];
	const foundStatus = findAddress(at, count as uint64, programAt, msSolSpanAddress(found), msSolSpanAddress(bump));
	const walked = walkedAddress(joined, program);
	if (refused || count > 15) {
		expect(foundStatus == 2, `check 1 at ${count}/${length}`);
	} else {
		expect(foundStatus == code(walked.found), `check 2 at ${count}/${length}`);
		if (walked.found) { expect(bump[0] == walked.bump && sameBytes(found, walked.digest.bytes), `walk at ${count}/${length}`); }
	}
	const canonical = foundStatus == 0;

	let derived: uint8[32] = [];
	for (let withBump = 0; withBump < 2; withBump++) {
		const bumpValue: uint64 = withBump == 0 ? 256 : 200;
		const status = deriveAddress(at, count as uint64, bumpValue, programAt, msSolSpanAddress(derived));
		if (refused || (count + withBump > 16)) {
			expect(status == 2, `check 3 at ${count}/${length}`);
		} else {
			const digest = derivedDigest(joined, withBump == 0 ? -1 : 200, program);
			expect(status == code(isOffCurve(digest)) && sameBytes(derived, digest.bytes), `check 4 at ${count}/${length}`);
		}
	}

	let zeros: uint8[32] = [];
	let walkBump: uint8[1] = [];
	const wrongExpected = findExpectedAddress(at, count as uint64, programAt, msSolSpanAddress(zeros), msSolSpanAddress(walkBump));
	const wrongCanonical = findCanonicalAddress(at, count as uint64, programAt, msSolSpanAddress(zeros), msSolSpanAddress(walkBump));
	const rightExpected = findExpectedAddress(at, count as uint64, programAt, msSolSpanAddress(found), msSolSpanAddress(walkBump));
	const rightCanonical = findCanonicalAddress(at, count as uint64, programAt, msSolSpanAddress(found), msSolSpanAddress(walkBump));
	if (canonical) {
		expect(wrongExpected == 1 && wrongCanonical == 3 && rightExpected == 0 && rightCanonical == 0 && walkBump[0] == bump[0], `check 5 at ${count}/${length}`);
	} else if (refused || count > 15) {
		expect(wrongExpected == 2 && wrongCanonical == 2 && rightExpected == 2 && rightCanonical == 2, `check 6 at ${count}/${length}`);
	}

	let staged: SeedSlice[19] = [];
	fillSeeds(pool, staged, count, length);
	const stagedAt = msSolTableAddress(staged);
	let stagedBump: uint8[1] = [];
	const used = seedStageInPlace(stagedAt, (count + 3) as uint64, msSolSpanAddress(stagedBump), programAt);
	if (refused || count > 15) {
		expect(used == 16, `check 7 at ${count}/${length}`);
		expect(findExpectedStaged(stagedAt, used, msSolSpanAddress(found)) == 2, `check 8 at ${count}/${length}`);
		expect(findCanonicalStaged(stagedAt, used, msSolSpanAddress(found)) == 2, `check 9 at ${count}/${length}`);
		expect(hashIsStaged(stagedAt, used, 1, msSolSpanAddress(found)) == 2, `check 10 at ${count}/${length}`);
	} else {
		expect(used == (count as uint64) && staged[count].length == 1 && staged[count + 1].length == 32 && staged[count + 2].length == 21, `check 11 at ${count}/${length}`);
		expect(staged[count].address == msSolSpanAddress(stagedBump) && staged[count + 1].address == programAt, `check 12 at ${count}/${length}`);
		if (canonical) {
			expect(findExpectedStaged(stagedAt, used, msSolSpanAddress(found)) == 0 && stagedBump[0] == bump[0], `check 13 at ${count}/${length}`);
			expect(findCanonicalStaged(stagedAt, used, msSolSpanAddress(found)) == 0 && stagedBump[0] == bump[0], `check 14 at ${count}/${length}`);
			expect(findExpectedStaged(stagedAt, used, msSolSpanAddress(zeros)) == 1, `check 15 at ${count}/${length}`);
			expect(findCanonicalStaged(stagedAt, used, msSolSpanAddress(zeros)) == 3, `check 16 at ${count}/${length}`);
			expect(hashIsStaged(stagedAt, used, bump[0] as uint64, msSolSpanAddress(found)) == 0, `check 17 at ${count}/${length}`);
			expect(hashIsStaged(stagedAt, used, (bump[0] - 1) as uint64, msSolSpanAddress(found)) == 3, `check 18 at ${count}/${length}`);
			expect(msSolLoadU8(msSolSpanAddress(stagedBump)) == bump[0] - 1, `check 19 at ${count}/${length}`);
		}
	}
	expect(seedStageInPlace(stagedAt, 2, msSolSpanAddress(stagedBump), programAt) == 16, `check 20 at ${count}/${length}`);
}

test "the seed walks agree with the hashing and curve check they are built from, with no seeds and with one" {
	failure = "";
	agree(0, 0);
	agree(1, 5);
	agree(1, 32);
	assert failure == "";
}

test "the seed walks agree at the largest table and refuse the one past it and a seed over 32 bytes" {
	failure = "";
	agree(15, 1);
	agree(16, 1);
	agree(3, 33);
	agree(2, 0);
	assert failure == "";
}

function sameAsC(count: int32, length: int32, expectCanonical: int32): void {
	when (c) {
		let pool: uint8[704] = [];
		let program: uint8[32] = [];
		for (let k = 0; k < 32; k++) { program[k] = (k * 3 + 5) as uint8; }
		let table: SeedSlice[19] = [];
		fillSeeds(pool, table, count, length);
		const at = msSolTableAddress(table);
		const programAt = msSolSpanAddress(program);
		let mine: uint8[32] = [];
		let theirs: uint8[32] = [];
		let mineBump: uint8[1] = [];
		let theirBump: uint8[1] = [];
		const a = findAddress(at, count as uint64, programAt, msSolSpanAddress(mine), msSolSpanAddress(mineBump));
		const b = msSolFindAddress(at, count as uint64, programAt, msSolSpanAddress(theirs), msSolSpanAddress(theirBump));
		expect(a == b && sameBytes(mine, theirs) && mineBump[0] == theirBump[0], `check 21 at ${count}/${length}`);
		expect((a == 0 ? 1 : 0) == expectCanonical, `check 22 at ${count}/${length}`);
		for (let bumpValue: uint64 = 254; bumpValue <= 256; bumpValue++) {
			const x = deriveAddress(at, count as uint64, bumpValue, programAt, msSolSpanAddress(mine));
			const y = msSolDeriveAddress(at, count as uint64, bumpValue, programAt, msSolSpanAddress(theirs));
			expect(x == y && sameBytes(mine, theirs), `check 23 at ${count}/${length}`);
		}
		let zeros: uint8[32] = [];
		const expecteds: uint64[] = [msSolSpanAddress(mine), msSolSpanAddress(zeros)];
		for (let pick = 0; pick < 2; pick++) {
			const expected = expecteds[pick];
			expect(findExpectedAddress(at, count as uint64, programAt, expected, msSolSpanAddress(mineBump)) == msSolFindExpectedAddress(at, count as uint64, programAt, expected, msSolSpanAddress(theirBump)), `check 24 at ${count}/${length}`);
			expect(mineBump[0] == theirBump[0], `check 25 at ${count}/${length}`);
			expect(findCanonicalAddress(at, count as uint64, programAt, expected, msSolSpanAddress(mineBump)) == msSolFindCanonicalAddress(at, count as uint64, programAt, expected, msSolSpanAddress(theirBump)), `check 26 at ${count}/${length}`);
			expect(mineBump[0] == theirBump[0], `check 27 at ${count}/${length}`);
		}
		let first: SeedSlice[19] = [];
		let second: SeedSlice[19] = [];
		fillSeeds(pool, first, count, length);
		fillSeeds(pool, second, count, length);
		const firstAt = msSolTableAddress(first);
		const secondAt = msSolTableAddress(second);
		let firstBump: uint8[1] = [];
		let secondBump: uint8[1] = [];
		const used = seedStageInPlace(firstAt, (count + 3) as uint64, msSolSpanAddress(firstBump), programAt);
		expect(used == msSolSeedStageInPlace(secondAt, (count + 3) as uint64, msSolSpanAddress(secondBump), programAt), `check 28 at ${count}/${length}`);
		for (let pick = 0; pick < 2; pick++) {
			const expected = expecteds[pick];
			expect(findExpectedStaged(firstAt, used, expected) == msSolFindExpectedStaged(secondAt, used, expected), `check 29 at ${count}/${length}`);
			expect(firstBump[0] == secondBump[0], `check 30 at ${count}/${length}`);
			expect(findCanonicalStaged(firstAt, used, expected) == msSolFindCanonicalStaged(secondAt, used, expected), `check 31 at ${count}/${length}`);
			expect(firstBump[0] == secondBump[0], `check 32 at ${count}/${length}`);
			for (let tried: uint64 = 0; tried < 3; tried++) {
				expect(hashIsStaged(firstAt, used, tried * 100, expected) == msSolHashIsStaged(secondAt, used, tried * 100, expected), `check 33 at ${count}/${length}`);
			}
		}
	}
}

test "the C kernel's inline walks and the shared walks answer alike on the same tables" {
	failure = "";
	sameAsC(0, 0, 1);
	sameAsC(1, 5, 1);
	sameAsC(4, 32, 1);
	sameAsC(15, 2, 1);
	sameAsC(16, 1, 0);
	sameAsC(2, 33, 0);
	assert failure == "";
}
