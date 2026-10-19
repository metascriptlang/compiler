import {
	msSolCompare,
	msSolCopy,
	msSolFill,
	msSolHostFaultCodeOf,
	msSolLoadU8,
	msSolLoadU64,
	msSolProgramId,
	msSolSpanAddress,
	msSolStoreU64,
	msSolWordsAddress,
} from "./memory";
import { clearReturnData } from "./simulatorLog";
import { msSolHostDeriveAddress } from "./simulatorCrypto";
import {
	DATA_AT,
	LENGTH_AT,
	META_SIGNER_AT,
	META_SIZE,
	META_WRITABLE_AT,
	MISSING_REQUIRED_SIGNATURE,
	OWNER_AT,
	REFUSED,
	anyByteIn,
	fault,
	isZeroKey,
	lamportsOf,
	recordAddress,
	rentExemptFor,
	systemInvoke,
} from "./simulatorPrograms";
import {
	ASSOCIATED_PROGRAM,
	INCINERATOR,
	TOKEN_2022_PROGRAM,
	TOKEN_PROGRAM,
	associatedInvoke,
	isKey,
	tokenInvoke,
} from "./simulatorToken";

const MAX_SEEDS: uint64 = 16;
const MAX_SIGNERS: uint64 = 16;
const MAX_SEED_LEN: uint64 = 32;
const SIGNER_SEEDS_TOO_MANY: uint64 = 0xd00000000;
const SIGNER_SIZE: uint64 = 16;
const SEED_TOO_LONG = "Length of the seed is too long for address generation";
const SIGNER_ACCOUNT_AT: uint64 = 1;
const WRITABLE_AT: uint64 = 2;
const KEY_AT: uint64 = 8;
const META_RECORD_SIZE: uint64 = 34;
const INVOCATION_SIZE: uint64 = 80;
const UINT64_MAX: uint64 = 0xffffffffffffffff;

interface Held {
	record: uint64;
	index: uint64;
	startLamports: uint64;
	startLength: uint64;
	lamports: uint64;
	length: uint64;
	owner: uint64[];
	data: uint8[];
}

let holds: Held[] = [];
let invocationHeaders: uint8[][] = [];
let invocationBuffers: uint8[][] = [];
let derived: uint64[] = [0, 0, 0, 0];
let signerBytes: uint64 = 0;

function zeroed(size: uint64): uint8[] {
	const bytes: uint8[] = [];
	for (let at: uint64 = 0; at < size; at++) { bytes.push(0); }
	return bytes;
}

// Called by host.c msSolHostForget
@exportName("msSolHostResetDispatcher")
export function resetDispatcher(): void {
	holds = [];
	invocationHeaders = [];
	invocationBuffers = [];
}

// host.c msSolHostInvocationTotal
@exportName("msSolHostInvocationTotal")
export function invocationTotal(): uint64 {
	return invocationHeaders.length as uint64;
}

// host.c msSolHostInvocationAt
@exportName("msSolHostInvocationAt")
export function invocationAt(index: uint64): uint64 {
	if (index >= (invocationHeaders.length as uint64)) { return 0; }
	const record = invocationHeaders[index as int32];
	return msSolSpanAddress(record);
}

// host.c msSolHostAdopt
function adopt(held: Held): void {
	held.lamports = lamportsOf(held.record);
	held.length = msSolLoadU64(held.record + LENGTH_AT);
	held.owner = [];
	for (let at: uint64 = 0; at < 32; at += 8) { held.owner.push(msSolLoadU64(held.record + OWNER_AT + at)); }
	held.data = [];
	for (let at: uint64 = 0; at < held.length; at++) { held.data.push(msSolLoadU8(held.record + DATA_AT + at)); }
}

// host.c msSolHostHoldAccounts, called by msSolHostEnter with the parsed account table
@exportName("msSolHostHoldAccounts")
export function holdAccounts(table: uint64, count: uint64): void {
	for (let index: uint64 = 0; index < count; index++) {
		const record = msSolLoadU64(table + index * 8);
		let earlier: uint64 = 0;
		while (earlier < index && msSolLoadU64(table + earlier * 8) != record) { earlier++; }
		if (earlier < index) { continue; }
		const held: Held = {
			record: record,
			index: index,
			startLamports: 0,
			startLength: 0,
			lamports: 0,
			length: 0,
			owner: [],
			data: [],
		};
		adopt(held);
		held.startLamports = held.lamports;
		held.startLength = held.length;
		holds.push(held);
	}
}

// host.c msSolHostHeldAt
function heldAt(record: uint64): int32 {
	for (let index = 0; index < holds.length; index++) {
		if (holds[index].record == record) { return index; }
	}
	return -1;
}

function ownerIs(owner: uint64[], address: uint64): boolean {
	return msSolLoadU64(address) == owner[0] && msSolLoadU64(address + 8) == owner[1]
		&& msSolLoadU64(address + 16) == owner[2] && msSolLoadU64(address + 24) == owner[3];
}

function dataDiffers(held: Held, length: uint64): boolean {
	if (length != held.length) { return true; }
	for (let at: uint64 = 0; at < length; at++) {
		if (msSolLoadU8(held.record + DATA_AT + at) != held.data[at as int32]) { return true; }
	}
	return false;
}

// host.c msSolHostTakes
function takes(held: Held): boolean {
	const record = held.record;
	const writable = msSolLoadU8(record + WRITABLE_AT) != 0;
	const owned = ownerIs(held.owner, msSolProgramId());
	const lamports = lamportsOf(record);
	const length = msSolLoadU64(record + LENGTH_AT);
	let refusal = "";
	if (lamports < held.lamports && !owned) {
		refusal = "ExternalAccountLamportSpend: the program spent lamports of an account it does not own";
	} else if (lamports != held.lamports && !writable) {
		refusal = "ReadonlyLamportChange: the program changed the lamports of an account the instruction does not pass writable";
	} else if (dataDiffers(held, length)) {
		if (!writable) { refusal = "ReadonlyDataModified: the program changed the data of an account the instruction does not pass writable"; }
		else if (!owned) { refusal = "ExternalAccountDataModified: the program changed the data of an account it does not own"; }
	}
	if (refusal == "" && !ownerIs(held.owner, record + OWNER_AT)
		&& (!owned || !writable || anyByteIn(record + DATA_AT, 0, length))) {
		refusal = "ModifiedProgramId: the program may give away only a writable account it owns whose bytes are all zero";
	}
	if (refusal == "") {
		adopt(held);
		return true;
	}
	fault(REFUSED, `${refusal} (account ${held.index})`);
	return false;
}

// host.c msSolHostBalanced: the sums run to 128 bits, kept as a high and a low word
function balanced(): boolean {
	let beforeHigh: uint64 = 0;
	let beforeLow: uint64 = 0;
	let nowHigh: uint64 = 0;
	let nowLow: uint64 = 0;
	for (let index = 0; index < holds.length; index++) {
		const start = holds[index].startLamports;
		if (start > UINT64_MAX - beforeLow) { beforeHigh++; beforeLow = start - (UINT64_MAX - beforeLow) - 1; } else { beforeLow += start; }
		const end = holds[index].lamports;
		if (end > UINT64_MAX - nowLow) { nowHigh++; nowLow = end - (UINT64_MAX - nowLow) - 1; } else { nowLow += end; }
	}
	if (beforeHigh == nowHigh && beforeLow == nowLow) { return true; }
	fault(REFUSED, "UnbalancedInstruction: the lamports of the instruction's accounts do not sum to what they summed to before it");
	return false;
}

function deriveFor(seeds: uint64, count: uint64, programId: uint64): boolean {
	return msSolHostDeriveAddress(seeds, count, 0, programId, msSolWordsAddress(derived)) != 0;
}

// host.c msSolHostSignersRefused: the bytes the invocation record keeps for the seeds are left in signerBytes
function signersRefused(signers: uint64, signerCount: uint64): uint64 {
	const programId = msSolProgramId();
	signerBytes = 0;
	if (signerCount > MAX_SIGNERS) {
		fault(REFUSED, "ProgramFailedToComplete: sol_invoke_signed: Too many signers");
		return REFUSED;
	}
	for (let signer: uint64 = 0; signer < signerCount; signer++) {
		const entry = signers + signer * SIGNER_SIZE;
		const seeds = msSolLoadU64(entry);
		const seedCount = msSolLoadU64(entry + 8);
		if (seedCount > MAX_SEEDS) { return SIGNER_SEEDS_TOO_MANY; }
		signerBytes += 8;
		for (let seed: uint64 = 0; seed < seedCount; seed++) {
			const length = msSolLoadU64(seeds + seed * 16 + 8);
			if (length > MAX_SEED_LEN) {
				fault(REFUSED, `ProgramFailedToComplete: sol_invoke_signed: Could not create program address with signer seeds: ${SEED_TOO_LONG}`);
				return REFUSED;
			}
			signerBytes += 8 + length;
		}
		if (!deriveFor(seeds, seedCount, programId)) {
			fault(REFUSED, "ProgramFailedToComplete: sol_invoke_signed: Could not create program address with signer seeds: Provided seeds do not result in a valid address");
			return REFUSED;
		}
	}
	return 0;
}

// host.c msSolHostSignsFor
function signsFor(key: uint64, signers: uint64, signerCount: uint64): boolean {
	const programId = msSolProgramId();
	for (let signer: uint64 = 0; signer < signerCount; signer++) {
		const entry = signers + signer * SIGNER_SIZE;
		if (deriveFor(msSolLoadU64(entry), msSolLoadU64(entry + 8), programId)
			&& msSolCompare(msSolWordsAddress(derived), key, 32) == 0) { return true; }
	}
	return false;
}

// host.c msSolHostPrivilegesHeld
function privilegesHeld(header: uint64, signers: uint64, signerCount: uint64): boolean {
	const metas = msSolLoadU64(header + 8);
	for (let index: uint64 = 0; index < msSolLoadU64(header + 16); index++) {
		const meta = metas + index * META_SIZE;
		const record = msSolLoadU64(meta) - 8;
		if (msSolLoadU8(meta + META_WRITABLE_AT) != 0 && msSolLoadU8(record + WRITABLE_AT) == 0) {
			fault(REFUSED, "PrivilegeEscalation: sol_invoke_signed: an account's writable privilege escalated: the instruction did not pass it writable");
			return false;
		}
		if (msSolLoadU8(meta + META_SIGNER_AT) != 0 && msSolLoadU8(record + SIGNER_ACCOUNT_AT) == 0
			&& !signsFor(record + KEY_AT, signers, signerCount)) {
			fault(REFUSED, "PrivilegeEscalation: sol_invoke_signed: an account's signer privilege escalated: it did not sign and no signer seeds derive it");
			return false;
		}
	}
	return true;
}

// host.c msSolHostRecordSigners
function recordSigners(out: uint64, signers: uint64, signerCount: uint64): void {
	let at = out;
	for (let signer: uint64 = 0; signer < signerCount; signer++) {
		const entry = signers + signer * SIGNER_SIZE;
		const seeds = msSolLoadU64(entry);
		const seedCount = msSolLoadU64(entry + 8);
		msSolStoreU64(at, seedCount);
		at += 8;
		for (let seed: uint64 = 0; seed < seedCount; seed++) {
			const length = msSolLoadU64(seeds + seed * 16 + 8);
			msSolStoreU64(at, length);
			at += 8;
			if (length > 0) { msSolCopy(at, msSolLoadU64(seeds + seed * 16), length); }
			at += length;
		}
	}
}

// host.c msSolHostInvoked: the record is laid out as host.ms reads it (program, metas, data, signer seeds)
function recordInvocation(header: uint64, signers: uint64, signerCount: uint64): void {
	const metaCount = msSolLoadU64(header + 16);
	const dataLength = msSolLoadU64(header + 32);
	const record = zeroed(INVOCATION_SIZE);
	const metas = zeroed(metaCount * META_RECORD_SIZE);
	const data = zeroed(dataLength);
	const seeds = zeroed(signerBytes);
	const at = msSolSpanAddress(record);
	msSolCopy(at, msSolLoadU64(header), 32);
	msSolStoreU64(at + 32, metaCount);
	for (let index: uint64 = 0; index < metaCount; index++) {
		const meta = msSolLoadU64(header + 8) + index * META_SIZE;
		const entry = msSolSpanAddress(metas) + index * META_RECORD_SIZE;
		msSolCopy(entry, msSolLoadU64(meta), 32);
		msSolCopy(entry + 32, meta + META_WRITABLE_AT, 2);
	}
	msSolStoreU64(at + 40, msSolSpanAddress(metas));
	msSolStoreU64(at + 48, dataLength);
	if (dataLength > 0) { msSolCopy(msSolSpanAddress(data), msSolLoadU64(header + 24), dataLength); }
	msSolStoreU64(at + 56, msSolSpanAddress(data));
	msSolStoreU64(at + 64, signerCount);
	recordSigners(msSolSpanAddress(seeds), signers, signerCount);
	msSolStoreU64(at + 72, msSolSpanAddress(seeds));
	invocationBuffers.push(metas);
	invocationBuffers.push(data);
	invocationBuffers.push(seeds);
	invocationHeaders.push(record);
}

// host.c msSolHostInvoked
function invoked(header: uint64, signers: uint64, signerCount: uint64): uint64 {
	const refused = signersRefused(signers, signerCount);
	if (refused != 0) { return refused; }
	if (!privilegesHeld(header, signers, signerCount)) { return MISSING_REQUIRED_SIGNATURE; }
	const count = msSolLoadU64(header + 16);
	for (let index: uint64 = 0; index < count; index++) {
		const held = heldAt(recordAddress(header, index));
		if (held >= 0 && !takes(holds[held])) { return REFUSED; }
	}
	if (!balanced()) { return REFUSED; }
	recordInvocation(header, signers, signerCount);
	clearReturnData();
	const callee = msSolLoadU64(header);
	let status: uint64 = 0;
	if (isZeroKey(callee)) { status = systemInvoke(header); }
	else if (isKey(callee, TOKEN_PROGRAM) || isKey(callee, TOKEN_2022_PROGRAM)) { status = tokenInvoke(header); }
	else if (isKey(callee, ASSOCIATED_PROGRAM)) { status = associatedInvoke(header); }
	for (let index: uint64 = 0; status == 0 && index < count; index++) {
		const held = heldAt(recordAddress(header, index));
		if (held >= 0) { adopt(holds[held]); }
	}
	return status;
}

// host.c msSolHostInvokeSigned
@exportName("msSolHostInvokeSigned")
export function invokeSigned(instruction: uint64, accountInfos: uint64, accountInfoCount: uint64, signers: uint64, signerCount: uint64): uint64 {
	if (msSolHostFaultCodeOf() != 0) { return msSolHostFaultCodeOf(); }
	const status = invoked(instruction, signers, signerCount);
	if (status != 0) { fault(status, ""); }
	return status;
}

// host.c msSolHostPaysRent
function paysRent(lamports: uint64, length: uint64): boolean {
	return lamports != 0 && lamports < rentExemptFor(length);
}

// host.c msSolHostLeave, after the shell has seen the program return no error
@exportName("msSolHostSettle")
export function settle(): void {
	if (msSolHostFaultCodeOf() != 0) { return; }
	for (let index = 0; index < holds.length; index++) {
		if (!takes(holds[index])) { return; }
	}
	if (!balanced()) { return; }
	for (let index = 0; index < holds.length; index++) {
		const held = holds[index];
		const record = held.record;
		if (msSolLoadU8(record + WRITABLE_AT) == 0 || isKey(record + KEY_AT, INCINERATOR)) { continue; }
		if (held.lamports == 0) {
			msSolStoreU64(record + LENGTH_AT, 0);
			msSolFill(record + OWNER_AT, 0, 32);
			continue;
		}
		if (!paysRent(held.lamports, held.length)) { continue; }
		if (paysRent(held.startLamports, held.startLength) && held.length == held.startLength
			&& held.lamports <= held.startLamports) { continue; }
		fault(REFUSED, `InsufficientFundsForRent: account ${held.index} ends the transaction with ${held.lamports} lamports, its ${held.length} bytes are rent exempt from ${rentExemptFor(held.length)}`);
		return;
	}
}
