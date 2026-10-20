import { msSolHostFaultCodeOf, msSolLoadU64, msSolLoadU8, msSolSpanAddress, msSolStoreU64, msSolWordsAddress } from "./memory";
import {
	CONTEXT_SIZE,
	HEAP_SIZE,
	instructionDataOf,
	parseAccounts,
	parseInput,
	roundedSize,
	heapExhausted,
	heapHolds,
} from "./simulatorContext";
import { recordSize, serializeInput } from "./simulatorContextFixture";

when (c) {
	import { msSolAccountAt, msSolAccountCount, msSolInstructionData, msSolInstructionDataLength, msSolScratch } from "./kernel";
	import { msSolProgramId } from "./memory";

	extern function msSolHostEnter(input: uint64): void;
}

function accountsOf(firsts: int32[]): int32[] {
	const lengths: int32[] = [];
	for (let index = 0; index < firsts.length; index++) { lengths.push((index * 5) % 11); }
	return lengths;
}

test "a record, a record and a repeat of the first parse to three slots, the repeat marking the first as duplicated" {
	const firsts: int32[] = [0, 1, 0];
	const lengths: int32[] = [5, 12, 5];
	const input = serializeInput(firsts, lengths, [9, 8, 7], 0x77);
	const base = msSolSpanAddress(input);
	let table: uint64[255] = [];
	const parsed = parseInput(base, msSolWordsAddress(table));
	const second = 8 + recordSize(5);
	const repeat = second + recordSize(12);
	assert parsed.count == 3;
	assert table[0] == base + 8 && table[1] == base + (second as uint64) && table[2] == base + 8;
	assert parsed.instructionData == base + (repeat as uint64) + 16;
	assert parsed.programId == parsed.instructionData + 3;
	assert msSolLoadU8(base + 8 + 4) == 2 && msSolLoadU8(base + (second as uint64) + 4) == 0;
	assert msSolLoadU64(parsed.instructionData - 8) == 3 && msSolLoadU8(parsed.programId) == 0x77;
	assert instructionDataOf(base) == parsed.instructionData;
}

test "an input with no accounts parses to an empty table and the data that follows its count" {
	const input = serializeInput([], [], [1, 2], 0x11);
	const base = msSolSpanAddress(input);
	let table: uint64[255] = [];
	assert parseAccounts(base, msSolWordsAddress(table), 255) == 0;
	assert table[0] == base + 8;
	const parsed = parseInput(base, msSolWordsAddress(table));
	assert parsed.count == 0 && parsed.instructionData == base + 16 && parsed.programId == base + 18;
}

test "repeats past the fourth slot and a lone first record resolve to the first record of their index" {
	const firsts: int32[] = [0, 1, 2, 3, 1, 0, 3, 7 - 5];
	const input = serializeInput(firsts, accountsOf(firsts), [], 0x22);
	const base = msSolSpanAddress(input);
	let table: uint64[255] = [];
	const parsed = parseInput(base, msSolWordsAddress(table));
	assert parsed.count == 8;
	assert table[4] == table[1] && table[5] == table[0] && table[6] == table[3] && table[7] == table[2];
	assert table[1] == table[0] + (recordSize(0) as uint64) && table[2] == table[1] + (recordSize(5) as uint64) && table[3] == table[2] + (recordSize(10) as uint64);
	assert msSolLoadU8(table[0] + 4) == 2 && msSolLoadU8(table[1] + 4) == 2 && msSolLoadU8(table[2] + 4) == 2 && msSolLoadU8(table[3] + 4) == 2;
	assert parsed.instructionData == base + 8 + (recordSize(0) + recordSize(5) + recordSize(10) + recordSize(4) + 4 * 8 + 8) as uint64;
}

test "a table smaller than the instruction keeps its first accounts and leaves the slots past it alone" {
	for (const firsts of [[0, 1, 2, 3, 4], [0, 1, 0, 2, 1], [0, 0, 0, 0, 0, 0, 0]]) {
		for (const limit of [1, 2, 5]) {
			const input = serializeInput(firsts, accountsOf(firsts), [6], 0x44);
			const base = msSolSpanAddress(input);
			let table: uint64[255] = [];
			let full: uint64[255] = [];
			const fullCount = parseAccounts(base, msSolWordsAddress(full), 255);
			const input2 = serializeInput(firsts, accountsOf(firsts), [6], 0x44);
			const base2 = msSolSpanAddress(input2);
			const kept = parseAccounts(base2, msSolWordsAddress(table), limit as uint64);
			const expected = limit < firsts.length ? limit : firsts.length;
			assert kept == (expected as uint64) && fullCount == (firsts.length as uint64);
			for (let index = 0; index < expected; index++) { assert table[index] - base2 == full[index] - base; }
			for (let index = expected; index < 255; index++) { assert table[index] == 0; }
			assert instructionDataOf(base2) - base2 == instructionDataOf(base) - base;
		}
	}
}

test "more than 255 accounts is refused with a fault and no table" {
	const input = serializeInput([], [], [], 0);
	const base = msSolSpanAddress(input);
	msSolStoreU64(base, 256);
	let table: uint64[255] = [];
	const parsed = parseInput(base, msSolWordsAddress(table));
	assert parsed.count == 0 && parsed.programId == 0 && msSolHostFaultCodeOf() != 0;
}

test "heap requests round up to eight bytes and are held while they fit what is left of 32 KiB" {
	assert roundedSize(0) == 0 && roundedSize(1) == 8 && roundedSize(8) == 8 && roundedSize(9) == 16;
	assert roundedSize(0xfffffffffffffff9) == 0xfffffffffffffff9;
	assert CONTEXT_SIZE == 96 && HEAP_SIZE == 32768;
	assert heapHolds(96, 32672) && !heapHolds(96, 32673) && heapHolds(HEAP_SIZE, 0) && !heapHolds(HEAP_SIZE, 1);
	assert heapExhausted(16, 32760) == "std/solana host: the 32 KiB program heap is exhausted (asked 16 more bytes at 32760)";
}

test "the C host parses the same bytes to the same slots and the same marked records" {
	when (c) {
		const firsts: int32[][] = [[0, 1, 0], [0], [0, 0, 0, 0, 0], [0, 1, 2, 3, 4], [0, 1, 2, 3, 1, 0, 3, 2], []];
		for (let at = 0; at < firsts.length; at++) {
			const lengths = accountsOf(firsts[at]);
			const mine = serializeInput(firsts[at], lengths, [4, 5, 6, 7], 0x33);
			const theirs = serializeInput(firsts[at], lengths, [4, 5, 6, 7], 0x33);
			const mineBase = msSolSpanAddress(mine);
			const theirBase = msSolSpanAddress(theirs);
			let table: uint64[255] = [];
			const parsed = parseInput(mineBase, msSolWordsAddress(table));
			msSolHostEnter(theirBase);
			assert msSolAccountCount() == parsed.count && parsed.count == (firsts[at].length as uint64);
			for (let index: uint64 = 0; index < parsed.count; index++) {
				assert msSolAccountAt(index) - theirBase == table[index as int32] - mineBase;
			}
			assert msSolInstructionData() - theirBase == parsed.instructionData - mineBase;
			assert msSolProgramId() - theirBase == parsed.programId - mineBase;
			assert msSolInstructionDataLength() == 4;
			for (let offset = 0; offset < mine.length; offset++) { assert mine[offset] == theirs[offset]; }
		}
	}
}

test "the C host's scratch heap bumps and refuses exactly where the shared geometry does" {
	when (c) {
		msSolHostEnter(0);
		const sizes: uint64[] = [1, 9, 0, 4000, 30000, 28000, 600, 49, 48, 0, 1];
		let position = CONTEXT_SIZE;
		let base: uint64 = 0;
		for (let at = 0; at < sizes.length; at++) {
			const got = msSolScratch(sizes[at]);
			if (heapHolds(position, sizes[at])) {
				if (base == 0) { base = got - position; }
				assert got == base + position;
				position += roundedSize(sizes[at]);
			} else {
				assert got == 0;
			}
		}
		assert position == HEAP_SIZE;
	}
}
