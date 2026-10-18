import { msSolHostRaise, msSolLoadU64, msSolLoadU8, msSolStoreU64, msSolStoreU8 } from "./memory";

const REFUSED: uint64 = 0xffffffffffffffff;
const DUPLICATE_MARKER: uint8 = 0xff;
const DUPLICATED_RECORD: uint8 = 2;
const BORROW_OFFSET: uint64 = 4;
const PEELED_ACCOUNTS: uint64 = 4;
const RECORD_HEADER: uint64 = 88;
const MAX_DATA_INCREASE: uint64 = 10240;
const ALIGN_DOWN: uint64 = 0xfffffffffffffff8;

export const MAX_ACCOUNTS: uint64 = 255;
export const HEAP_START: uint64 = 0x300000000;
export const INPUT_START: uint64 = 0x400000000;
export const HEAP_SIZE: uint64 = 32768;
export const CONTEXT_SIZE: uint64 = 96;
export const RENT_AT: uint64 = 72;
export const EMPTY_INPUT_SIZE: uint64 = 48;

export struct ParsedInput {
	count: uint64;
	instructionData: uint64;
	programId: uint64;
}

// solana.h msSolPastRecord
function pastRecord(record: uint64): uint64 {
	return (record + msSolLoadU64(record + 80) + (RECORD_HEADER + MAX_DATA_INCREASE + 15)) & ALIGN_DOWN;
}

// solana.h msSolNextRecord
function nextRecord(cursor: uint64): uint64 {
	if (msSolLoadU8(cursor) != DUPLICATE_MARKER) { return cursor + 8; }
	const past = (cursor + RECORD_HEADER + msSolLoadU64(cursor + 80) + MAX_DATA_INCREASE + 7) & ALIGN_DOWN;
	return past + 8;
}

export function tooManyAccounts(input: uint64): boolean {
	return msSolLoadU64(input) > MAX_ACCOUNTS;
}

// solana.h msSolParseAccounts: the slot table gets one record address per account, a duplicate's slot is its first
// record's, and that first record's borrow byte is marked duplicated. Answers the number of accounts.
export function parseAccounts(input: uint64, table: uint64): uint64 {
	const kept = msSolLoadU64(input);
	if (kept > MAX_ACCOUNTS) {
		msSolHostRaise(REFUSED, "solana input: the loader refuses more than 255 accounts");
		return 0;
	}
	let cursor = input + 8;
	msSolStoreU64(table, cursor);
	if (kept <= 1) { return kept; }
	let slot = PEELED_ACCOUNTS;
	cursor = pastRecord(cursor);
	for (let index: uint64 = 1; index < PEELED_ACCOUNTS; index++) {
		if (msSolLoadU8(cursor) != DUPLICATE_MARKER) {
			slot = index;
			break;
		}
		msSolStoreU64(table + index * 8, cursor);
		if (kept == index + 1) { return kept; }
		cursor = pastRecord(cursor);
	}
	while (true) {
		const marker = msSolLoadU8(cursor);
		if (marker == DUPLICATE_MARKER) {
			msSolStoreU64(table + slot * 8, cursor);
			slot++;
			if (slot == kept) { break; }
			cursor = pastRecord(cursor);
		} else {
			const first = msSolLoadU64(table + (marker as uint64) * 8);
			msSolStoreU64(table + slot * 8, first);
			slot++;
			msSolStoreU8(first + BORROW_OFFSET, DUPLICATED_RECORD);
			if (slot == kept) { break; }
			cursor += 8;
		}
	}
	return kept;
}

// solana.h msSolInstructionDataOf
export function instructionDataOf(input: uint64): uint64 {
	let cursor = input + 8;
	for (let left = msSolLoadU64(input); left > 0; left--) { cursor = nextRecord(cursor); }
	return cursor + 8;
}

// solana.h msSolParse
export function parseInput(input: uint64, table: uint64): ParsedInput {
	if (tooManyAccounts(input)) {
		parseAccounts(input, table);
		return { count: 0, instructionData: 0, programId: 0 };
	}
	const count = parseAccounts(input, table);
	const instructionData = instructionDataOf(input);
	return { count: count, instructionData: instructionData, programId: instructionData + msSolLoadU64(instructionData - 8) };
}

// host.c msSolHostAlloc rounds a request up to 8 bytes; a request too large to round is kept and then refused
export function roundedSize(size: uint64): uint64 {
	if (size <= 0xfffffffffffffff8) { return (size + 7) & ALIGN_DOWN; }
	return size;
}

// host.c msSolHostScratch and msSolHostAlloc compare against what is left of the heap after `position`
export function heapHolds(position: uint64, size: uint64): boolean {
	return size <= HEAP_SIZE - position;
}

// host.c msSolHostAlloc
export function heapExhausted(size: uint64, position: uint64): string {
	return `std/solana host: the 32 KiB program heap is exhausted (asked ${size} more bytes at ${position})`;
}
