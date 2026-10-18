import {
	msSolDataRoom,
	msSolFill,
	msSolHostRaise,
	msSolLoadU8,
	msSolLoadU32,
	msSolLoadU64,
	msSolStoreU64,
} from "./memory";

const REFUSED: uint64 = 0xffffffffffffffff;
const NOT_SIMULATED: uint64 = 0xfffffffffffffffe;
const INVALID_ARGUMENT: uint64 = 0x200000000;
const INVALID_INSTRUCTION_DATA: uint64 = 0x300000000;
const MISSING_REQUIRED_SIGNATURE: uint64 = 0x800000000;
const ACCOUNT_DATA_TOO_SMALL: uint64 = 0x1400000000;
const ARITHMETIC_OVERFLOW: uint64 = 0x1800000000;
const SYSTEM_ALREADY_IN_USE: uint64 = 0x100000000;
const SYSTEM_TOO_FEW_LAMPORTS: uint64 = 1;
const SYSTEM_INVALID_DATA_LENGTH: uint64 = 3;
const SYSTEM_MAX_SPACE: uint64 = 10485760;
const LAMPORTS_PER_BYTE_YEAR: uint64 = 3480;
const RENT_EXEMPTION_YEARS: uint64 = 2;
const ACCOUNT_STORAGE_OVERHEAD: uint64 = 128;

const OWNER_AT: uint64 = 40;
const LAMPORTS_AT: uint64 = 72;
const LENGTH_AT: uint64 = 80;
const DATA_AT: uint64 = 88;
const META_SIZE: uint64 = 16;
const META_WRITABLE_AT: uint64 = 8;
const META_SIGNER_AT: uint64 = 9;

interface SystemAccount {
	record: uint64;
	lamports: uint64;
	space: uint64;
	owner: uint64;
	signer: boolean;
	writable: boolean;
}

function fault(result: uint64, text: string): void {
	msSolHostRaise(result, text);
}

function refuses(text: string): uint64 {
	fault(REFUSED, text);
	return REFUSED;
}

function notSimulated(program: string, instruction: uint32, status: uint64): uint64 {
	fault(NOT_SIMULATED, `sol_invoke_signed: ${program} program instruction ${instruction} is not simulated`);
	return status;
}

// host.c msSolHostRecordOf
@exportName("msSolHostRecordAddress")
export function recordAddress(header: uint64, index: uint64): uint64 {
	if (index >= msSolLoadU64(header + 16)) { return 0; }
	return msSolLoadU64(msSolLoadU64(header + 8) + index * META_SIZE) - 8;
}

// host.c msSolHostLamports
@exportName("msSolHostLamportsOf")
export function lamportsOf(record: uint64): uint64 {
	return msSolLoadU64(record + LAMPORTS_AT);
}

// host.c msSolHostSetLamports
@exportName("msSolHostSetLamportsOf")
export function setLamportsOf(record: uint64, value: uint64): void {
	msSolStoreU64(record + LAMPORTS_AT, value);
}

// host.c msSolHostRentExempt
@exportName("msSolHostRentExemptFor")
export function rentExemptFor(length: uint64): uint64 {
	return (length + ACCOUNT_STORAGE_OVERHEAD) * LAMPORTS_PER_BYTE_YEAR * RENT_EXEMPTION_YEARS;
}

// host.c msSolHostResize
@exportName("msSolHostResizeRecord")
export function resizeRecord(record: uint64, space: uint64): uint64 {
	const length = msSolLoadU64(record + LENGTH_AT);
	if (space > length) {
		if (space > msSolDataRoom(record)) { return ACCOUNT_DATA_TOO_SMALL; }
		msSolFill(record + DATA_AT + length, 0, space - length);
	}
	msSolStoreU64(record + LENGTH_AT, space);
	return 0;
}

// host.c msSolHostAnyByte
@exportName("msSolHostAnyByteIn")
export function anyByteIn(bytes: uint64, from: uint64, to: uint64): boolean {
	for (let index = from; index < to; index++) {
		if (msSolLoadU8(bytes + index) != 0) { return true; }
	}
	return false;
}

function isZeroKey(key: uint64): boolean {
	return msSolLoadU64(key) == 0 && msSolLoadU64(key + 8) == 0 && msSolLoadU64(key + 16) == 0 && msSolLoadU64(key + 24) == 0;
}

function sameKey(left: uint64, right: uint64): boolean {
	return msSolLoadU64(left) == msSolLoadU64(right) && msSolLoadU64(left + 8) == msSolLoadU64(right + 8)
		&& msSolLoadU64(left + 16) == msSolLoadU64(right + 16) && msSolLoadU64(left + 24) == msSolLoadU64(right + 24);
}

function copyKey(destination: uint64, source: uint64): void {
	for (let at: uint64 = 0; at < 32; at += 8) { msSolStoreU64(destination + at, msSolLoadU64(source + at)); }
}

// host.c msSolHostSystemOwns
function systemOwns(account: SystemAccount): boolean {
	return isZeroKey(account.owner);
}

// host.c msSolHostSystemAllocate
function systemAllocate(account: SystemAccount, space: uint64): uint64 {
	if (!account.signer) { return MISSING_REQUIRED_SIGNATURE; }
	if (account.space != 0 || !systemOwns(account)) { return SYSTEM_ALREADY_IN_USE; }
	if (space > SYSTEM_MAX_SPACE) { return SYSTEM_INVALID_DATA_LENGTH; }
	if (!account.writable) {
		return refuses("ReadonlyDataModified: sol_invoke_signed: the System program sized an account the instruction does not pass writable");
	}
	account.space = space;
	return 0;
}

// host.c msSolHostSystemAssign
function systemAssign(account: SystemAccount, owner: uint64): uint64 {
	if (sameKey(account.owner, owner)) { return 0; }
	if (!account.signer) { return MISSING_REQUIRED_SIGNATURE; }
	if (!systemOwns(account) || !account.writable || anyByteIn(account.record + DATA_AT, 0, msSolLoadU64(account.record + LENGTH_AT))) {
		return refuses("ModifiedProgramId: sol_invoke_signed: the System program may not change the owner of this account");
	}
	account.owner = owner;
	return 0;
}

// host.c msSolHostSystemTransfer
function systemTransfer(from: SystemAccount, to: SystemAccount, amount: uint64): uint64 {
	if (!from.signer) { return MISSING_REQUIRED_SIGNATURE; }
	if (from.space != 0) { return INVALID_ARGUMENT; }
	if (amount > from.lamports) { return SYSTEM_TOO_FEW_LAMPORTS; }
	if (amount != 0 && !systemOwns(from)) {
		return refuses("ExternalAccountLamportSpend: sol_invoke_signed: the System program spent the lamports of an account it does not own");
	}
	if (!from.writable) {
		return refuses("ReadonlyLamportChange: sol_invoke_signed: the System program debits an account the instruction does not pass writable");
	}
	from.lamports -= amount;
	if (amount > REFUSED - to.lamports) { return ARITHMETIC_OVERFLOW; }
	if (!to.writable) {
		return refuses("ReadonlyLamportChange: sol_invoke_signed: the System program credits an account the instruction does not pass writable");
	}
	to.lamports += amount;
	return 0;
}

function accountAt(header: uint64, index: uint64): SystemAccount {
	const record = recordAddress(header, index);
	const meta = msSolLoadU64(header + 8) + index * META_SIZE;
	return {
		record: record,
		lamports: lamportsOf(record),
		space: msSolLoadU64(record + LENGTH_AT),
		owner: record + OWNER_AT,
		signer: msSolLoadU8(meta + META_SIGNER_AT) != 0,
		writable: msSolLoadU8(meta + META_WRITABLE_AT) != 0,
	};
}

function systemDataLength(tag: uint32): uint64 {
	if (tag == 0 || tag == 13) { return 52; }
	if (tag == 1) { return 36; }
	if (tag == 2 || tag == 8) { return 12; }
	return 0;
}

// host.c msSolHostSystem
@exportName("msSolHostSystemInvoke")
export function systemInvoke(header: uint64): uint64 {
	const dataLength = msSolLoadU64(header + 32);
	if (dataLength < 4) { return INVALID_INSTRUCTION_DATA; }
	const data = msSolLoadU64(header + 24);
	const tag = msSolLoadU32(data);
	const needed = tag > 13 ? 0 : systemDataLength(tag);
	if (needed == 0) { return notSimulated("System", tag, INVALID_INSTRUCTION_DATA); }
	if (dataLength < needed) { return INVALID_INSTRUCTION_DATA; }
	const amount: uint64 = tag == 1 ? 0 : msSolLoadU64(data + 4);
	let count: uint64 = 0;
	while (count < 2 && recordAddress(header, count) != 0) { count++; }
	const reads: uint64 = tag == 0 || tag == 2 || (tag == 13 && amount != 0) ? 2 : 1;
	if (count < reads) {
		return refuses("MissingAccount: sol_invoke_signed: the System program instruction names fewer accounts than it reads");
	}
	const first = accountAt(header, 0);
	const second = count == 2 && recordAddress(header, 1) != first.record ? accountAt(header, 1) : first;
	let status: uint64 = 0;
	if (tag == 0) {
		if (second.lamports != 0) { return SYSTEM_ALREADY_IN_USE; }
		status = systemAllocate(second, msSolLoadU64(data + 12));
		if (status == 0) { status = systemAssign(second, data + 20); }
		if (status == 0) { status = systemTransfer(first, second, amount); }
	} else if (tag == 13) {
		status = systemAllocate(first, msSolLoadU64(data + 12));
		if (status == 0) { status = systemAssign(first, data + 20); }
		if (status == 0 && amount != 0) { status = systemTransfer(second, first, amount); }
	} else if (tag == 1) {
		status = systemAssign(first, data + 4);
	} else if (tag == 2) {
		status = systemTransfer(first, second, amount);
	} else {
		status = systemAllocate(first, amount);
	}
	if (status == 0) { status = resizeRecord(first.record, first.space); }
	if (status == 0) { status = resizeRecord(second.record, second.space); }
	if (status != 0) { return status; }
	setLamportsOf(first.record, first.lamports);
	copyKey(first.record + OWNER_AT, first.owner);
	setLamportsOf(second.record, second.lamports);
	copyKey(second.record + OWNER_AT, second.owner);
	return 0;
}
