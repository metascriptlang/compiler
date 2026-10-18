import { msSolHostRaise, msSolLoadU8, msSolStoreU8, msSolStoreU64 } from "./memory";
import {
	LogBook,
	OPENING_LINE_BYTES,
	base58,
	base64,
	isUtf8,
	newLogBook,
	recordLine,
	words,
} from "./simulatorLogCore";

@include("runtime/solana/solana.h");
extern function msSolProgramId(): uint64;
extern function msSolHostFaultCodeOf(): uint64;

const REFUSED: uint64 = 0xffffffffffffffff;
const COMPUTE_BUDGET: uint64 = 200000;
const MAX_RETURN_DATA: uint64 = 1024;
const LAMPORTS_PER_BYTE_YEAR: uint64 = 3480;
const EXEMPTION_THRESHOLD_BITS: uint64 = 0x4000000000000000;
const BURN_PERCENT: uint8 = 50;

let book: LogBook = newLogBook();
let returnData: uint8[] = [];
let returnProgram: uint8[] = [];
let rentReads: uint64 = 0;
let clock: uint64[] = [0, 0, 0, 0, 0];
let sysvarStatus: uint64 = 0;

function readBytes(address: uint64, length: uint64): uint8[] {
	const bytes: uint8[] = [];
	for (let at: uint64 = 0; at < length; at++) { bytes.push(msSolLoadU8(address + at)); }
	return bytes;
}

function writeBytes(address: uint64, bytes: Readonly<Span<uint8>>): void {
	for (let at = 0; at < bytes.length; at++) { msSolStoreU8(address + (at as uint64), bytes[at]); }
}

function asciiBytes(text: string): uint8[] {
	const bytes: uint8[] = [];
	for (let at = 0; at < text.length; at++) { bytes.push(text.charCodeAt(at) as uint8); }
	return bytes;
}

function record(line: string, size: uint64): void {
	if (msSolHostFaultCodeOf() != 0) { return; }
	if (book.bytes == 0) { book.bytes = OPENING_LINE_BYTES + (base58(readBytes(msSolProgramId(), 32)).length as uint64); }
	recordLine(book, line, size);
}

function recordText(line: string): void {
	record(line, line.byteLength as uint64);
}

// Called by host.c msSolHostForget
@exportName("msSolHostResetSimulator")
export function resetSimulator(): void {
	book = newLogBook();
	rentReads = 0;
	clearReturnData();
}

// Called by host.c msSolHostEnter and msSolHostInvoked, where the return data is dropped
@exportName("msSolHostClearReturnData")
export function clearReturnData(): void {
	returnData = [];
	returnProgram = [];
	for (let at = 0; at < 32; at++) { returnProgram.push(0); }
}

// host.c msSolHostLogTotal
@exportName("msSolHostLogTotal")
export function logTotal(): uint64 {
	return book.lines.length as uint64;
}

// host.c msSolHostLogAt
@exportName("msSolHostLogAt")
export function logAt(index: uint64): string {
	if (index >= (book.lines.length as uint64)) { return ""; }
	return book.lines[index as int32];
}

// host.c msSolHostLog
@exportName("msSolHostLog")
export function log(address: uint64, length: uint64): void {
	const bytes = readBytes(address, length);
	if (!isUtf8(bytes)) {
		msSolHostRaise(REFUSED, "ProgramFailedToComplete: sol_log_: the line is not valid UTF-8");
		return;
	}
	record("Program log: " + bytes.asString(), length + 13);
}

// host.c msSolHostLog64
@exportName("msSolHostLog64")
export function log64(a: uint64, b: uint64, c: uint64, d: uint64, e: uint64): void {
	recordText(words(a, b, c, d, e));
}

// host.c msSolHostLogPubkey
@exportName("msSolHostLogPubkey")
export function logPubkey(address: uint64): void {
	recordText("Program log: " + base58(readBytes(address, 32)));
}

// host.c msSolHostLogData
@exportName("msSolHostLogData")
export function logData(address: uint64, length: uint64): void {
	recordText("Program data: " + base64(readBytes(address, length)));
}

// host.c msSolHostLogComputeUnits
@exportName("msSolHostLogComputeUnits")
export function logComputeUnits(): void {
	recordText(`Program consumption: ${COMPUTE_BUDGET} units remaining`);
}

// host.c msSolHostRentReadTotal
@exportName("msSolHostRentReadTotal")
export function rentReadTotal(): uint64 {
	return rentReads;
}

// host.c msSolHostSetClock
@exportName("msSolHostSetClock")
export function setClock(slot: uint64, epochStart: uint64, epoch: uint64, leaderEpoch: uint64, unixTime: uint64): void {
	clock = [slot, epochStart, epoch, leaderEpoch, unixTime];
}

// host.c msSolHostSetSysvarStatus
@exportName("msSolHostSetSysvarStatus")
export function setSysvarStatus(status: uint64): void {
	sysvarStatus = status;
}

// host.c msSolHostGetClock
@exportName("msSolHostGetClock")
export function getClock(out: uint64): uint64 {
	if (sysvarStatus != 0) { return sysvarStatus; }
	for (let word = 0; word < 5; word++) { msSolStoreU64(out + (word as uint64) * 8, clock[word]); }
	return 0;
}

// host.c msSolHostGetRent
@exportName("msSolHostGetRent")
export function getRent(out: uint64): uint64 {
	rentReads++;
	if (sysvarStatus != 0) { return sysvarStatus; }
	msSolStoreU64(out, LAMPORTS_PER_BYTE_YEAR);
	msSolStoreU64(out + 8, EXEMPTION_THRESHOLD_BITS);
	msSolStoreU8(out + 16, BURN_PERCENT);
	return 0;
}

// host.c msSolHostSetReturnData; the C shim msSolHostSetReturnData passes the pointer and the length as words
@exportName("msSolHostSetReturnDataAt")
export function setReturnData(data: uint64, length: uint64): void {
	if (msSolHostFaultCodeOf() != 0) { return; }
	if (length > MAX_RETURN_DATA) {
		msSolHostRaise(REFUSED, "ProgramFailedToComplete: sol_set_return_data: Return data too large, more than 1024 bytes");
		return;
	}
	returnData = readBytes(data, length);
	returnProgram = readBytes(msSolProgramId(), 32);
}

// host.c msSolHostGetReturnData
@exportName("msSolHostGetReturnData")
export function getReturnData(data: uint64, length: uint64, programId: uint64): uint64 {
	const stored = returnData.length as uint64;
	const copied = length < stored ? length : stored;
	if (copied != 0) {
		writeBytes(data, returnData.slice(0, copied as int32));
		writeBytes(programId, returnProgram);
	}
	return stored;
}
