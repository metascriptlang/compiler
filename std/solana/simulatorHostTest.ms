import {
	msSolAccountAt,
	msSolAccountCount,
	msSolAccountSlot,
	msSolHostEnter,
	msSolHostInput,
	msSolHostResult,
	msSolInstructionData,
	msSolInstructionDataLength,
	msSolRemainingComputeUnits,
	msSolRentAddress,
	msSolResult,
	msSolScratch,
	msSolSetResult,
} from "./kernel";
import {
	msSolHostFaultCodeOf,
	msSolHostRaise,
	msSolLoadU64,
	msSolLoadU8,
	msSolProgramId,
	msSolSpanAddress,
	msSolStoreU64,
	msSolStoreU8,
	msSolWordsAddress,
} from "./memory";
import { CONTEXT_SIZE, HEAP_SIZE, RENT_AT, parseInput } from "./simulatorContext";
import { serializeInput } from "./simulatorContextFixture";
import { accountCount, accountTable, context, instructionData, msSolHostAlloc } from "./simulatorHost";

function entered(firsts: int32[], lengths: int32[], program: uint8): uint64 {
	const bytes = serializeInput(firsts, lengths, [4, 5, 6], program);
	const input = msSolHostInput(bytes.length as uint64);
	for (let at = 0; at < bytes.length; at++) { msSolStoreU8(input + (at as uint64), bytes[at]); }
	msSolHostEnter(input);
	return input;
}

when (js) {
	function stopOf(run: () => void): string {
		@emit(`try { ${run}(); } catch (error) { return error.message; }
	return "";`);
		unreachable;
	}
}

test "the kernel reads an entered input where the shared parse lays it out" {
	const firsts: int32[] = [0, 1, 0, 3, 1];
	const lengths: int32[] = [5, 12, 5, 0, 12];
	const input = entered(firsts, lengths, 0x5a);
	const copy = serializeInput(firsts, lengths, [4, 5, 6], 0x5a);
	const base = msSolSpanAddress(copy);
	let table: uint64[255] = [];
	const parsed = parseInput(base, msSolWordsAddress(table));
	assert msSolAccountCount() == 5 && accountCount() == 5;
	for (let index: uint64 = 0; index < 5; index++) {
		assert msSolAccountAt(index) - input == table[index as int32] - base;
		assert msSolAccountSlot(index) == msSolLoadU64(accountTable() + index * 8);
	}
	assert msSolAccountAt(5) == 0;
	assert msSolInstructionData() == instructionData();
	assert msSolInstructionData() - input == parsed.instructionData - base;
	assert msSolInstructionDataLength() == 3 && msSolProgramId() - input == parsed.programId - base;
	assert msSolLoadU8(msSolProgramId()) == 0x5a && msSolLoadU8(msSolAccountAt(0) + 4) == 2;
}

test "the context opens the heap: scratch starts past it and the result and the rent live in it" {
	msSolHostEnter(0);
	const at = context();
	assert msSolAccountCount() == 0 && msSolInstructionDataLength() == 0;
	assert msSolScratch(1) == at + CONTEXT_SIZE && msSolScratch(16) == at + CONTEXT_SIZE + 8;
	msSolSetResult(7);
	assert msSolResult() == 7 && msSolHostResult() == 7 && msSolLoadU64(at + 8) == 7;
	assert msSolRentAddress() == at + RENT_AT && msSolLoadU64(at + RENT_AT) == 3480;
	assert msSolRemainingComputeUnits() == 200000;
	when (c) {
		assert at % 16 == 0;
	}
}

test "entering again zeroes the heap, the result and the fault and keeps the heap where it was" {
	entered([0], [3], 0x11);
	const first = msSolScratch(8);
	msSolStoreU64(first, 0x0102030405060708);
	msSolSetResult(9);
	msSolHostRaise(5, "a fault of the earlier run");
	assert msSolHostFaultCodeOf() == 5;
	const at = context();
	entered([0, 1], [3, 4], 0x22);
	assert context() == at && msSolScratch(8) == first && msSolLoadU64(first) == 0;
	assert msSolHostResult() == 0 && msSolHostFaultCodeOf() == 0 && msSolAccountCount() == 2;
	assert msSolLoadU8(msSolProgramId()) == 0x22;
}

test "a fresh input is zeroed bytes of the asked size" {
	const input = msSolHostInput(64);
	msSolStoreU64(input + 56, 0xffffffffffffffff);
	const again = msSolHostInput(72);
	for (let at: uint64 = 0; at < 72; at += 8) { assert msSolLoadU64(again + at) == 0; }
}

test "scratch answers zero past the heap's last byte and an allocation past it stops by name" {
	msSolHostEnter(0);
	const left = HEAP_SIZE - CONTEXT_SIZE - 8;
	assert msSolScratch(left) == context() + CONTEXT_SIZE && msSolScratch(9) == 0;
	assert msSolHostAlloc(5) == context() + HEAP_SIZE - 8;
	when (js) {
		assert stopOf(() => { msSolHostAlloc(1); }) ==
			"std/solana host: the 32 KiB program heap is exhausted (asked 8 more bytes at 32768)";
	}
}
