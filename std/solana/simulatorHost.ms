import { msSolHostFaultCodeOf, msSolLoadU64, msSolMemoryClearFault, msSolMemoryFaultText, msSolStoreU64 } from "./memory";
import {
	CONTEXT_SIZE,
	EMPTY_INPUT_SIZE,
	HEAP_SIZE,
	MAX_ACCOUNTS,
	heapExhausted,
	heapHolds,
	parseInput,
	roundedSize,
} from "./simulatorContext";
import { COMPUTE_BUDGET, resetSimulator } from "./simulatorLog";
import { holdAccounts, resetDispatcher, settle } from "./simulatorInvoke";

when (c) {
	import { msSolFill, msSolSpanAddress, msSolWordsAddress } from "./memory";

	extern function abort(): void;

	let heapWords: uint64[HEAP_SIZE / 8 + 2] = [];
	let tableWords: uint64[MAX_ACCOUNTS] = [];
	let emptyWords: uint64[EMPTY_INPUT_SIZE / 8] = [];
	let inputBytes: uint8[] = [];
} else {
	import {
		msSolMemoryAllocate,
		msSolMemoryKeepOnly,
		msSolMemoryMap,
		msSolMemorySetAccounts,
		msSolMemoryUnmap,
	} from "./memory";
	import { HEAP_START, INPUT_START } from "./simulatorContext";
}

const ALIGN_DOWN_16: uint64 = 0xfffffffffffffff0;
const INPUT_AT: uint64 = 0;
const RESULT_AT: uint64 = 8;
const ARENA_AT: uint64 = 16;
const ACCOUNT_COUNT_AT: uint64 = 24;
const ACCOUNT_TABLE_AT: uint64 = 32;
const INSTRUCTION_DATA_AT: uint64 = 40;
const PROGRAM_ID_AT: uint64 = 48;

let heap: uint64 = 0;

function stop(message: string): void {
	when (c) {
		console.error(message);
		abort();
	} else {
		throw new Error(message);
	}
}

function freshHeap(): uint64 {
	when (c) {
		const start = (msSolWordsAddress(heapWords) + 15) & ALIGN_DOWN_16;
		msSolFill(start, 0, HEAP_SIZE);
		return start;
	} else {
		msSolMemoryUnmap(HEAP_START);
		msSolMemoryMap(HEAP_START, HEAP_SIZE);
		return HEAP_START;
	}
}

function emptyInput(): uint64 {
	when (c) {
		return msSolWordsAddress(emptyWords);
	} else {
		return msSolMemoryAllocate(EMPTY_INPUT_SIZE);
	}
}

function accountSlots(): uint64 {
	when (c) {
		return msSolWordsAddress(tableWords);
	} else {
		return msSolMemoryAllocate(MAX_ACCOUNTS * 8);
	}
}

function prepare(input: uint64): void {
	heap = freshHeap();
	const start = input == 0 ? emptyInput() : input;
	const table = accountSlots();
	msSolStoreU64(heap + INPUT_AT, start);
	msSolStoreU64(heap + ARENA_AT, CONTEXT_SIZE);
	const parsed = parseInput(start, table);
	msSolStoreU64(heap + ACCOUNT_COUNT_AT, parsed.count);
	msSolStoreU64(heap + ACCOUNT_TABLE_AT, table);
	msSolStoreU64(heap + INSTRUCTION_DATA_AT, parsed.instructionData);
	msSolStoreU64(heap + PROGRAM_ID_AT, parsed.programId);
	when (js) {
		msSolMemorySetAccounts(table, parsed.count, parsed.instructionData, start, parsed.programId);
	}
}

@exportName("msSolHostContext")
export function context(): uint64 {
	if (heap == 0) { prepare(0); }
	return heap;
}

@exportName("msSolHostEnter")
export function msSolHostEnter(input: uint64): void {
	resetSimulator();
	resetDispatcher();
	when (js) {
		msSolMemoryKeepOnly(input);
	}
	msSolMemoryClearFault();
	prepare(input);
	if (msSolHostFaultCodeOf() != 0) { stop("solana kernel: " + msSolMemoryFaultText()); }
	holdAccounts(accountTable(), accountCount());
}

@exportName("msSolHostInput")
export function msSolHostInput(size: uint64): uint64 {
	when (c) {
		const bytes: uint8[] = [];
		for (let at: uint64 = 0; at < size; at++) { bytes.push(0); }
		inputBytes = bytes;
		return msSolSpanAddress(inputBytes);
	} else {
		msSolMemoryUnmap(INPUT_START);
		msSolMemoryMap(INPUT_START, size);
		return INPUT_START;
	}
}

@exportName("msSolHostAlloc")
export function msSolHostAlloc(size: uint64): uint64 {
	const at = context();
	const position = msSolLoadU64(at + ARENA_AT);
	const rounded = roundedSize(size);
	if (!heapHolds(position, rounded)) { stop(heapExhausted(rounded, position)); }
	msSolStoreU64(at + ARENA_AT, position + rounded);
	return at + position;
}

@exportName("msSolHostScratch")
export function msSolHostScratch(size: uint64): uint64 {
	if (!heapHolds(msSolLoadU64(context() + ARENA_AT), size)) { return 0; }
	return msSolHostAlloc(size);
}

@exportName("msSolHostLeave")
export function msSolHostLeave(): void {
	if (msSolHostResult() != 0) { return; }
	settle();
}

@exportName("msSolHostResult")
export function msSolHostResult(): uint64 {
	return msSolLoadU64(context() + RESULT_AT);
}

@exportName("msSolHostRemainingComputeUnits")
export function msSolHostRemainingComputeUnits(): uint64 {
	return COMPUTE_BUDGET;
}

export function setResult(code: uint64): void {
	msSolStoreU64(context() + RESULT_AT, code);
}

export function accountCount(): uint64 {
	return msSolLoadU64(context() + ACCOUNT_COUNT_AT);
}

export function accountTable(): uint64 {
	return msSolLoadU64(context() + ACCOUNT_TABLE_AT);
}

export function instructionData(): uint64 {
	return msSolLoadU64(context() + INSTRUCTION_DATA_AT);
}
