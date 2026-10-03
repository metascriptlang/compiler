// The host simulator parses an instruction the way the SBF entry does: the account table is not
// taken from the program heap, and it holds at most MS_SOL_MAX_ACCOUNTS (255) accounts, the
// reference entry's default, with the accounts past it skipped (instruction data and program id are
// still found behind them).
// RED MEANS: reading the accounts moved the heap position (the table was allocated again), the
// 256th account of an instruction was kept, or a skipped account shifted the instruction data.
@include("runtime/solana/solana.h");

import { ProgramError, Pubkey, account, accountCount, instructionData, programId } from "std/solana";
import { HostAccount, run } from "std/solana/host";
import { exit } from "std/process";

extern function msSolAlloc(size: uint64): uint64;

let failed = 0;
let heapBefore: uint64 = 0;
let heapAfter: uint64 = 0;
let counted: int32 = 0;
let lastKept = false;
let pastTheLast = false;
let dataLength: uint64 = 0;
let program = false;

function report(what: string): void {
	console.log(`GUARD-FAIL ${what}`);
	failed = failed + 1;
}

function keyOf(index: int32): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = (index & 0xff) as uint8;
	key.bytes[1] = ((index >> 8) & 0xff) as uint8;
	key.bytes[2] = 1;
	return key;
}

function programKey(): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = 200;
	key.bytes[31] = 7;
	return key;
}

function accountsOf(count: int32): HostAccount[] {
	const held: HostAccount[] = [];
	for (let index = 0; index < count; index++) {
		held.push({
			key: keyOf(index),
			owner: keyOf(1000),
			lamports: 1,
			data: [],
			signer: false,
			writable: false,
			executable: false,
		});
	}
	return held;
}

function sees(index: int32): boolean {
	const found = account(index);
	if (!found.ok) { return false; }
	return found.value.key().equals(keyOf(index));
}

function reads(): void {
	heapBefore = msSolAlloc(0);
	counted = accountCount();
	lastKept = counted > 0 && sees(counted - 1);
	pastTheLast = account(counted).ok;
	heapAfter = msSolAlloc(0);
	dataLength = instructionData().length;
	program = programId().equals(programKey());
}

function probe(count: int32): void {
	const result = run(programKey(), accountsOf(count), [1, 2, 3], reads);
	if (result.result != 0) { report(`${count} accounts: the entry failed with ${result.result}`); }
}

probe(3);
if (counted != 3) { report(`3 accounts: the program sees ${counted}`); }
if (heapAfter != heapBefore) { report(`3 accounts: reading them moved the heap by ${heapAfter - heapBefore} bytes`); }
if (!lastKept || pastTheLast) { report("3 accounts: the last account is missing or one is made up past it"); }

probe(255);
if (counted != 255) { report(`255 accounts: the program sees ${counted}`); }
if (!lastKept || pastTheLast) { report("255 accounts: the last account is missing or one is made up past it"); }
if (heapAfter != heapBefore) { report(`255 accounts: reading them moved the heap by ${heapAfter - heapBefore} bytes`); }
if (dataLength != 3 || !program) { report(`255 accounts: instruction data ${dataLength} bytes, program id ${program}`); }

probe(256);
if (counted != 255) { report(`256 accounts: the program sees ${counted}, the limit is 255`); }
if (!lastKept || pastTheLast) { report("256 accounts: the 255th account is missing or the 256th is kept"); }
if (dataLength != 3 || !program) { report(`256 accounts: instruction data ${dataLength} bytes, program id ${program} behind the skipped account`); }

if (failed != 0) { exit(1); }
console.log("GUARD-OK");
