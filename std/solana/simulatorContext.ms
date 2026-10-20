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

@inline function pastRecord(record: uint64): uint64 {
	return (record + msSolLoadU64(record + 80) + (RECORD_HEADER + MAX_DATA_INCREASE + 15)) & ALIGN_DOWN;
}

@inline function nextRecord(cursor: uint64): uint64 {
	if (msSolLoadU8(cursor) != DUPLICATE_MARKER) { return cursor + 8; }
	const past = (cursor + RECORD_HEADER + msSolLoadU64(cursor + 80) + MAX_DATA_INCREASE + 7) & ALIGN_DOWN;
	return past + 8;
}

export function tooManyAccounts(input: uint64): boolean {
	return msSolLoadU64(input) > MAX_ACCOUNTS;
}

// The slot table gets one record address per account up to `limit`, a duplicate's slot is its first record's, and
// that first record's borrow byte is marked duplicated. Answers the number of accounts kept.
@inline export function parseAccounts(input: uint64, table: uint64, limit: uint64): uint64 {
	const count = msSolLoadU64(input);
	if (count > MAX_ACCOUNTS) {
		msSolHostRaise(REFUSED, "solana input: the loader refuses more than 255 accounts");
		return 0;
	}
	const kept = count < limit ? count : limit;
	let cursor = input + 8;
	msSolStoreU64(table, cursor);
	if (kept <= 1) { return kept; }
	let slot = table + PEELED_ACCOUNTS * 8;
	cursor = pastRecord(cursor);
	for (let index: uint64 = 1; index < PEELED_ACCOUNTS; index++) {
		if (msSolLoadU8(cursor) != DUPLICATE_MARKER) {
			slot = table + index * 8;
			break;
		}
		msSolStoreU64(table + index * 8, cursor);
		if (kept == index + 1) { return kept; }
		cursor = pastRecord(cursor);
	}
	const end = table + kept * 8;
	while (true) {
		const marker = msSolLoadU8(cursor);
		if (marker == DUPLICATE_MARKER) {
			msSolStoreU64(slot, cursor);
			slot += 8;
			if (slot == end) { break; }
			cursor = pastRecord(cursor);
		} else {
			const first = msSolLoadU64(table + (marker as uint64) * 8);
			msSolStoreU64(slot, first);
			slot += 8;
			msSolStoreU8(first + BORROW_OFFSET, DUPLICATED_RECORD);
			if (slot == end) { break; }
			cursor += 8;
		}
	}
	return kept;
}

@noinline export function instructionDataOf(input: uint64): uint64 {
	let cursor = input + 8;
	for (let left = msSolLoadU64(input); left > 0; left--) { cursor = nextRecord(cursor); }
	return cursor + 8;
}

export function parseInput(input: uint64, table: uint64): ParsedInput {
	if (tooManyAccounts(input)) {
		parseAccounts(input, table, MAX_ACCOUNTS);
		return { count: 0, instructionData: 0, programId: 0 };
	}
	const count = parseAccounts(input, table, MAX_ACCOUNTS);
	const instructionData = instructionDataOf(input);
	return { count: count, instructionData: instructionData, programId: instructionData + msSolLoadU64(instructionData - 8) };
}

// A request too large to round up to 8 bytes is kept as is, so the heap check refuses it
export function roundedSize(size: uint64): uint64 {
	if (size <= 0xfffffffffffffff8) { return (size + 7) & ALIGN_DOWN; }
	return size;
}

export function heapHolds(position: uint64, size: uint64): boolean {
	return size <= HEAP_SIZE - position;
}

export function heapExhausted(size: uint64, position: uint64): string {
	return `std/solana host: the 32 KiB program heap is exhausted (asked ${size} more bytes at ${position})`;
}
