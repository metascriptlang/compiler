import { msSolCopy, msSolFill, msSolLoadU8, msSolLoadU16, msSolLoadU32, msSolLoadU64, msSolStoreU8, msSolStoreU32, msSolStoreU64, msSolWordsAddress } from "./memory";
import { msSolHostTryFindProgramAddress } from "./simulatorCrypto";
import {
	DATA_AT,
	INVALID_ARGUMENT,
	INVALID_INSTRUCTION_DATA,
	LENGTH_AT,
	META_SIGNER_AT,
	META_SIZE,
	MISSING_REQUIRED_SIGNATURE,
	NOT_SIMULATED,
	REFUSED,
	OWNER_AT,
	fault,
	isZeroKey,
	lamportsOf,
	notSimulated,
	recordAddress,
	refuses,
	rentExemptFor,
	resizeRecord,
	sameKey,
	setLamportsOf,
} from "./simulatorPrograms";

const INCORRECT_PROGRAM_ID: uint64 = 0x700000000;
const INVALID_ACCOUNT_DATA: uint64 = 0x400000000;
const NOT_ENOUGH_ACCOUNT_KEYS: uint64 = 0xb00000000;
const INVALID_SEEDS: uint64 = 0xe00000000;
const ILLEGAL_OWNER: uint64 = 0x1200000000;
const UNINITIALIZED_ACCOUNT: uint64 = 0xa00000000;
const NOT_RENT_EXEMPT: uint64 = 0x100000000;
const INSUFFICIENT_FUNDS: uint64 = 1;
const INVALID_MINT: uint64 = 2;
const MINT_MISMATCH: uint64 = 3;
const OWNER_MISMATCH: uint64 = 4;
const FIXED_SUPPLY: uint64 = 5;
const ALREADY_IN_USE: uint64 = 6;
const NATIVE_NOT_SUPPORTED: uint64 = 10;
const NON_NATIVE_HAS_BALANCE: uint64 = 11;
const INVALID_INSTRUCTION: uint64 = 12;
const OVERFLOW: uint64 = 14;
const AUTHORITY_TYPE_NOT_SUPPORTED: uint64 = 15;
const MINT_CANNOT_FREEZE: uint64 = 16;
const ACCOUNT_FROZEN: uint64 = 17;
const MINT_DECIMALS_MISMATCH: uint64 = 18;
const MINT_REQUIRED_FOR_TRANSFER: uint64 = 31;
const IMMUTABLE_OWNER: uint64 = 34;
const NON_TRANSFERABLE: uint64 = 37;
const ACCOUNT_LENGTH: uint64 = 165;
const MINT_LENGTH: uint64 = 82;
const MULTISIG_LENGTH: uint64 = 355;
const UINT64_MAX: uint64 = 0xffffffffffffffff;

export const TOKEN_PROGRAM: uint64[] = [0x93a165d7e1f6dd06, 0xac79ebce46e1cbd9, 0x91375b5fed85b41c, 0xa900ff7e85f58c3a];
export const TOKEN_2022_PROGRAM: uint64[] = [0xde8f75eee1f6dd06, 0xdacd6ce4bc5d4218, 0x270db9834dfc1ab6, 0xfc8ba1d828f9bdfe];
export const ASSOCIATED_PROGRAM: uint64[] = [0xf189244e8f25978c, 0x830d8e1429103dbb, 0x8410ffda99135a0b, 0x59f8e9dbd87b8e04];
const NATIVE_MINT: uint64[] = [0x8481abfe57889b06, 0x35c01846637f68fb, 0x553beb1adc39c4da, 0x0100000000f0a098];
const NATIVE_MINT_2022: uint64[] = [0xb8e65fde9ffc0d83, 0x8a1ee976a4047caa, 0x19fa90ad4a26bbc6, 0x5e5b3e5cd849dfc9];
export const INCINERATOR: uint64[] = [0x6011348d72903300, 0xdb00ffbf11c9bd79, 0xa69cf7cccd2e4dd4, 0x00000000e13800e1];

interface Call {
	header: uint64;
	program: uint64;
	data: uint64;
	length: uint64;
}

interface Extensions {
	bytes: uint8[];
	state: uint8;
}

function callOf(header: uint64): Call {
	return {
		header: header,
		program: msSolLoadU64(header),
		data: msSolLoadU64(header + 24),
		length: msSolLoadU64(header + 32),
	};
}

export function isKey(address: uint64, words: uint64[]): boolean {
	return msSolLoadU64(address) == words[0] && msSolLoadU64(address + 8) == words[1]
		&& msSolLoadU64(address + 16) == words[2] && msSolLoadU64(address + 24) == words[3];
}

function isToken2022(call: Call): boolean {
	return isKey(call.program, TOKEN_2022_PROGRAM);
}

function ownedByCallee(call: Call, record: uint64): boolean {
	return sameKey(record + OWNER_AT, call.program);
}

function recordOf(call: Call, index: uint64): uint64 {
	return recordAddress(call.header, index);
}

function recordLength(record: uint64): uint64 {
	return msSolLoadU64(record + LENGTH_AT);
}

function fields(record: uint64): uint64 {
	return record + DATA_AT;
}

// host.c msSolHostForeignAccount
function foreignAccount(call: Call): uint64 {
	if (!isToken2022(call)) {
		fault(REFUSED, "ExternalAccountDataModified: sol_invoke_signed: the Token program wrote an account it does not own");
	}
	return INCORRECT_PROGRAM_ID;
}

// host.c msSolHostHasTokenLayout
function hasTokenLayout(call: Call, record: uint64, base: uint64, accountType: uint8): boolean {
	const length = recordLength(record);
	if (length == base) { return true; }
	return isToken2022(call) && length > ACCOUNT_LENGTH && length != MULTISIG_LENGTH
		&& msSolLoadU8(fields(record) + ACCOUNT_LENGTH) == accountType;
}

function putExtension(out: uint8[], kind: uint16, length: uint16): void {
	out.push((kind & 255) as uint8);
	out.push((kind >> 8) as uint8);
	out.push((length & 255) as uint8);
	out.push((length >> 8) as uint8);
	for (let at: uint16 = 0; at < length; at++) { out.push(0); }
}

// host.c msSolHostAccountExtensionsOf
function accountExtensionsOf(mint: uint64, immutableOwner: boolean): Extensions {
	const length = recordLength(mint);
	const data = fields(mint);
	const found: Extensions = { bytes: [], state: 1 };
	if (immutableOwner) { putExtension(found.bytes, 7, 0); }
	const seen: boolean[] = [];
	for (let kind = 0; kind < 32; kind++) { seen.push(false); }
	let offset: uint64 = ACCOUNT_LENGTH + 1;
	while (offset + 4 <= length) {
		const kind = msSolLoadU16(data + offset);
		const size = msSolLoadU16(data + offset + 2);
		if (kind == 0 || (size as uint64) > length - offset - 4) { break; }
		const first = kind < 32 && !seen[kind];
		if (kind < 32) { seen[kind] = true; }
		if (first) {
			if (kind == 1) {
				putExtension(found.bytes, 2, 8);
			} else if (kind == 6) {
				if (size >= 1) { found.state = msSolLoadU8(data + offset + 4); }
			} else if (kind == 9) {
				putExtension(found.bytes, 13, 0);
				if (!immutableOwner) { putExtension(found.bytes, 7, 0); }
			} else if (kind == 14) {
				putExtension(found.bytes, 15, 1);
			} else if (kind == 26) {
				putExtension(found.bytes, 27, 0);
			}
		}
		offset += 4 + (size as uint64);
	}
	return found;
}

// host.c msSolHostShortData
function shortData(call: Call): uint64 {
	return isToken2022(call) ? INVALID_INSTRUCTION_DATA : INVALID_INSTRUCTION;
}

// host.c msSolHostFixedDataRefused
function fixedDataRefused(call: Call, length: uint64): boolean {
	return call.length < length || (isToken2022(call) && call.length != length);
}

function snapshot(address: uint64, length: uint64): uint8[] {
	const before: uint8[] = [];
	for (let at: uint64 = 0; at < length; at++) { before.push(msSolLoadU8(address + at)); }
	return before;
}

function unchanged(address: uint64, before: uint8[]): boolean {
	for (let at = 0; at < before.length; at++) {
		if (msSolLoadU8(address + (at as uint64)) != before[at]) { return false; }
	}
	return true;
}

// host.c msSolHostWritten
function written(call: Call, record: uint64, region: uint64, before: uint8[]): uint64 {
	if (ownedByCallee(call, record) || unchanged(region, before)) { return 0; }
	for (let at = 0; at < before.length; at++) { msSolStoreU8(region + (at as uint64), before[at]); }
	return foreignAccount(call);
}

// host.c msSolHostInitializeAccount3, after the instruction-data length check
function initializeAccount3(call: Call, account: uint64, mint: uint64, owner: uint64, immutableOwner: boolean): uint64 {
	if (account == 0 || mint == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	const extended = isToken2022(call);
	if (extended && !ownedByCallee(call, account)) { return INCORRECT_PROGRAM_ID; }
	const length = recordLength(account);
	const body = fields(account);
	if (!hasTokenLayout(call, account, ACCOUNT_LENGTH, 0)) { return INVALID_ACCOUNT_DATA; }
	if (msSolLoadU8(body + 108) != 0) { return ALREADY_IN_USE; }
	const reserve = rentExemptFor(length);
	if (lamportsOf(account) < reserve) { return NOT_RENT_EXEMPT; }
	const native = isKey(mint + 8, extended ? NATIVE_MINT_2022 : NATIVE_MINT);
	if (!native) {
		if (!ownedByCallee(call, mint)) { return INCORRECT_PROGRAM_ID; }
		if (!hasTokenLayout(call, mint, MINT_LENGTH, 1) || msSolLoadU8(fields(mint) + 45) != 1) { return INVALID_MINT; }
	}
	const found: Extensions = extended ? accountExtensionsOf(mint, immutableOwner) : { bytes: [], state: 1 };
	const extensionBytes = found.bytes.length as uint64;
	if (extensionBytes != 0 && length < ACCOUNT_LENGTH + 1 + extensionBytes) { return INVALID_ACCOUNT_DATA; }
	if (!ownedByCallee(call, account)) { return foreignAccount(call); }
	msSolCopy(body, mint + 8, 32);
	msSolCopy(body + 32, owner, 32);
	msSolStoreU8(body + 108, found.state);
	if (native) {
		msSolStoreU8(body + 109, 1);
		msSolStoreU64(body + 113, reserve);
		msSolStoreU64(body + 64, lamportsOf(account) - reserve);
	}
	if (length > ACCOUNT_LENGTH) {
		msSolStoreU8(body + ACCOUNT_LENGTH, 2);
		for (let at = 0; at < found.bytes.length; at++) {
			msSolStoreU8(body + ACCOUNT_LENGTH + 1 + (at as uint64), found.bytes[at]);
		}
	}
	return 0;
}

// host.c msSolHostInitialized
function initialized(call: Call, record: uint64, base: uint64, accountType: uint8, initializedAt: uint64): uint64 {
	if (record == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	if (!hasTokenLayout(call, record, base, accountType)) { return INVALID_ACCOUNT_DATA; }
	if (msSolLoadU8(fields(record) + initializedAt) == 0) { return UNINITIALIZED_ACCOUNT; }
	return 0;
}

// host.c msSolHostTokenAccount
function tokenAccount(call: Call, record: uint64): uint64 {
	return initialized(call, record, ACCOUNT_LENGTH, 2, 108);
}

// host.c msSolHostMint
function mintAccount(call: Call, record: uint64): uint64 {
	return initialized(call, record, MINT_LENGTH, 1, 45);
}

// host.c msSolHostUnpacked
function unpacked(call: Call, record: uint64, base: uint64, accountType: uint8, initializedAt: uint64): uint64 {
	if (record == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	if (isToken2022(call) && !ownedByCallee(call, record)) { return INCORRECT_PROGRAM_ID; }
	return initialized(call, record, base, accountType, initializedAt);
}

// host.c msSolHostUnpackedAccount
function unpackedAccount(call: Call, record: uint64): uint64 {
	return unpacked(call, record, ACCOUNT_LENGTH, 2, 108);
}

// host.c msSolHostUnpackedMint
function unpackedMint(call: Call, record: uint64): uint64 {
	return unpacked(call, record, MINT_LENGTH, 1, 45);
}

// host.c msSolHostOptionIs
function optionIs(option: uint64, key: uint64): boolean {
	return msSolLoadU32(option) == 1 && sameKey(option + 4, key);
}

// host.c msSolHostStoreOption
function storeOption(call: Call, option: uint64, key: uint64): void {
	msSolStoreU32(option, key != 0 ? 1 : 0);
	if (key != 0) {
		msSolCopy(option + 4, key, 32);
	} else if (isToken2022(call)) {
		msSolFill(option + 4, 0, 32);
	}
}

// host.c msSolHostHasExtension
function hasExtension(record: uint64, wanted: uint16): boolean {
	const length = recordLength(record);
	const data = fields(record);
	let offset: uint64 = ACCOUNT_LENGTH + 1;
	while (offset + 4 <= length) {
		const kind = msSolLoadU16(data + offset);
		const size = msSolLoadU16(data + offset + 2);
		if (kind == 0 || (size as uint64) > length - offset - 4) { break; }
		if (kind == wanted) { return true; }
		offset += 4 + (size as uint64);
	}
	return false;
}

// host.c msSolHostAuthorized
function authorized(call: Call, index: uint64, expected: uint64): uint64 {
	const authority = recordOf(call, index);
	if (authority == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	if (!sameKey(expected, authority + 8)) { return OWNER_MISMATCH; }
	if (ownedByCallee(call, authority) && recordLength(authority) == MULTISIG_LENGTH) {
		fault(NOT_SIMULATED, "sol_invoke_signed: a multisignature token authority is not simulated");
		return MISSING_REQUIRED_SIGNATURE;
	}
	if (msSolLoadU8(msSolLoadU64(call.header + 8) + index * META_SIZE + META_SIGNER_AT) == 0) { return MISSING_REQUIRED_SIGNATURE; }
	return 0;
}

// host.c msSolHostBurn
function burn(call: Call, checked: boolean): uint64 {
	const source = recordOf(call, 0);
	const mint = recordOf(call, 1);
	const authority = recordOf(call, 2);
	if (fixedDataRefused(call, checked ? 10 : 9)) { return shortData(call); }
	if (source == 0 || mint == 0 || authority == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	const amount = msSolLoadU64(call.data + 1);
	let status = unpackedAccount(call, source);
	if (status == 0) { status = unpackedMint(call, mint); }
	if (status != 0) { return status; }
	const account = fields(source);
	const supply = fields(mint);
	if (msSolLoadU8(account + 108) == 2) { return ACCOUNT_FROZEN; }
	if (msSolLoadU8(account + 109) == 1) { return NATIVE_NOT_SUPPORTED; }
	if (msSolLoadU64(account + 64) < amount) { return INSUFFICIENT_FUNDS; }
	if (!sameKey(mint + 8, account)) { return MINT_MISMATCH; }
	if (checked && msSolLoadU8(call.data + 9) != msSolLoadU8(supply + 44)) { return MINT_DECIMALS_MISMATCH; }
	const anyoneBurns = isZeroKey(account + 32) || isKey(account + 32, INCINERATOR);
	const delegated = !anyoneBurns && optionIs(account + 72, authority + 8);
	if (!anyoneBurns) {
		status = authorized(call, 2, delegated ? account + 76 : account + 32);
		if (status != 0) { return status; }
	}
	const allowance = msSolLoadU64(account + 121);
	if (delegated && allowance < amount) { return INSUFFICIENT_FUNDS; }
	const foreign = !ownedByCallee(call, source) || !ownedByCallee(call, mint);
	if (amount == 0 && foreign) { return INCORRECT_PROGRAM_ID; }
	if (foreign) { return foreignAccount(call); }
	if (delegated) {
		msSolStoreU64(account + 121, allowance - amount);
		if (allowance == amount) { storeOption(call, account + 72, 0); }
	}
	msSolStoreU64(account + 64, msSolLoadU64(account + 64) - amount);
	msSolStoreU64(supply + 36, msSolLoadU64(supply + 36) - amount);
	return 0;
}

// host.c msSolHostApproveChecked
function approveChecked(call: Call): uint64 {
	const source = recordOf(call, 0);
	const mint = recordOf(call, 1);
	const delegate = recordOf(call, 2);
	if (fixedDataRefused(call, 10)) { return shortData(call); }
	if (source == 0 || mint == 0 || delegate == 0 || recordOf(call, 3) == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	let status = unpackedAccount(call, source);
	if (status != 0) { return status; }
	const body = fields(source);
	if (msSolLoadU8(body + 108) == 2) { return ACCOUNT_FROZEN; }
	if (!sameKey(body, mint + 8)) { return MINT_MISMATCH; }
	status = unpackedMint(call, mint);
	if (status != 0) { return status; }
	if (msSolLoadU8(call.data + 9) != msSolLoadU8(fields(mint) + 44)) { return MINT_DECIMALS_MISMATCH; }
	status = authorized(call, 3, body + 32);
	if (status != 0) { return status; }
	const before = snapshot(body, ACCOUNT_LENGTH);
	storeOption(call, body + 72, delegate + 8);
	msSolStoreU64(body + 121, msSolLoadU64(call.data + 1));
	return written(call, source, body, before);
}

// host.c msSolHostRevoke
function revoke(call: Call): uint64 {
	const source = recordOf(call, 0);
	const authority = recordOf(call, 1);
	if (isToken2022(call) && authority == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	let status = unpackedAccount(call, source);
	if (status != 0) { return status; }
	if (authority == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	const body = fields(source);
	if (msSolLoadU8(body + 108) == 2) { return ACCOUNT_FROZEN; }
	const byDelegate = optionIs(body + 72, authority + 8);
	status = authorized(call, 1, byDelegate ? body + 76 : body + 32);
	if (status != 0) { return status; }
	const before = snapshot(body, ACCOUNT_LENGTH);
	storeOption(call, body + 72, 0);
	msSolStoreU64(body + 121, 0);
	return written(call, source, body, before);
}

// host.c msSolHostMintTo
function mintTo(call: Call): uint64 {
	const mint = recordOf(call, 0);
	const destination = recordOf(call, 1);
	const extended = isToken2022(call);
	if (fixedDataRefused(call, 9)) { return shortData(call); }
	if (mint == 0 || destination == 0 || recordOf(call, 2) == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	const amount = msSolLoadU64(call.data + 1);
	let status = unpackedAccount(call, destination);
	if (status != 0) { return status; }
	const to = fields(destination);
	if (msSolLoadU8(to + 108) == 2) { return ACCOUNT_FROZEN; }
	if (msSolLoadU8(to + 109) == 1) { return NATIVE_NOT_SUPPORTED; }
	if (!sameKey(mint + 8, to)) { return MINT_MISMATCH; }
	status = unpackedMint(call, mint);
	if (status != 0) { return status; }
	const minted = fields(mint);
	if (msSolLoadU8(minted) == 0) { return FIXED_SUPPLY; }
	status = authorized(call, 2, minted + 4);
	if (status != 0) { return status; }
	const foreign = !ownedByCallee(call, mint) || !ownedByCallee(call, destination);
	if (amount == 0 && foreign) { return INCORRECT_PROGRAM_ID; }
	const held = msSolLoadU64(to + 64);
	const supply = msSolLoadU64(minted + 36);
	if ((extended && amount > UINT64_MAX - held) || amount > UINT64_MAX - supply) { return OVERFLOW; }
	if (foreign) { return foreignAccount(call); }
	msSolStoreU64(to + 64, held + amount);
	msSolStoreU64(minted + 36, supply + amount);
	return 0;
}

// host.c msSolHostTransfer
function transfer(call: Call, checked: boolean): uint64 {
	const authorityAt: uint64 = checked ? 3 : 2;
	const source = recordOf(call, 0);
	const mint = checked ? recordOf(call, 1) : 0;
	const destination = recordOf(call, authorityAt - 1);
	const authority = recordOf(call, authorityAt);
	const extended = isToken2022(call);
	if (fixedDataRefused(call, checked ? 10 : 9)) { return shortData(call); }
	if (source == 0 || destination == 0 || authority == 0 || (checked && mint == 0)) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	const amount = msSolLoadU64(call.data + 1);
	let status = unpackedAccount(call, source);
	if (status == 0 && !extended) { status = tokenAccount(call, destination); }
	if (status != 0) { return status; }
	const from = fields(source);
	const to = fields(destination);
	if (msSolLoadU8(from + 108) == 2 || (!extended && msSolLoadU8(to + 108) == 2)) { return ACCOUNT_FROZEN; }
	const held = msSolLoadU64(from + 64);
	if (held < amount) { return INSUFFICIENT_FUNDS; }
	if (extended && hasExtension(source, 13)) { return NON_TRANSFERABLE; }
	if (extended && !checked && (hasExtension(source, 2) || hasExtension(source, 15) || hasExtension(source, 27))) {
		return MINT_REQUIRED_FOR_TRANSFER;
	}
	if (!extended && !sameKey(from, to)) { return MINT_MISMATCH; }
	if (checked) {
		if (!sameKey(mint + 8, from)) { return MINT_MISMATCH; }
		status = extended ? unpackedMint(call, mint) : mintAccount(call, mint);
		if (status != 0) { return status; }
		if (msSolLoadU8(call.data + 9) != msSolLoadU8(fields(mint) + 44)) { return MINT_DECIMALS_MISMATCH; }
	}
	const delegated = optionIs(from + 72, authority + 8);
	status = authorized(call, authorityAt, delegated ? from + 76 : from + 32);
	if (status != 0) { return status; }
	const allowance = msSolLoadU64(from + 121);
	if (delegated && allowance < amount) { return INSUFFICIENT_FUNDS; }
	const toItself = sameKey(source + 8, destination + 8);
	const foreign = !ownedByCallee(call, source) || !ownedByCallee(call, destination);
	if ((toItself || amount == 0) && foreign) { return INCORRECT_PROGRAM_ID; }
	if (toItself) { return 0; }
	if (extended) {
		status = unpackedAccount(call, destination);
		if (status != 0) { return status; }
		if (msSolLoadU8(to + 108) == 2) { return ACCOUNT_FROZEN; }
		if (!sameKey(from, to)) { return MINT_MISMATCH; }
	}
	const received = msSolLoadU64(to + 64);
	const native = msSolLoadU8(from + 109) == 1;
	if (extended && (amount > UINT64_MAX - received || (native && lamportsOf(source) < amount))) { return OVERFLOW; }
	if (foreign) { return foreignAccount(call); }
	if (native && lamportsOf(source) < amount) {
		fault(REFUSED, "UnbalancedInstruction: sol_invoke_signed: the Token program moved more lamports than the native account holds");
		return OVERFLOW;
	}
	if (delegated) {
		msSolStoreU64(from + 121, allowance - amount);
		if (allowance == amount) { storeOption(call, from + 72, 0); }
	}
	msSolStoreU64(from + 64, held - amount);
	msSolStoreU64(to + 64, received + amount);
	if (native) {
		setLamportsOf(source, lamportsOf(source) - amount);
		setLamportsOf(destination, lamportsOf(destination) + amount);
	}
	return 0;
}

// host.c msSolHostCloseAccount
function closeAccount(call: Call): uint64 {
	const source = recordOf(call, 0);
	const destination = recordOf(call, 1);
	if (source == 0 || destination == 0 || recordOf(call, 2) == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	if (sameKey(source + 8, destination + 8)) { return INVALID_ACCOUNT_DATA; }
	if (isToken2022(call) && ownedByCallee(call, source) && hasTokenLayout(call, source, MINT_LENGTH, 1) && hasExtension(source, 3)) {
		fault(NOT_SIMULATED, "sol_invoke_signed: closing a Token-2022 mint that has a close authority is not simulated");
		return INVALID_ACCOUNT_DATA;
	}
	let status = unpackedAccount(call, source);
	if (status != 0) { return status; }
	const body = fields(source);
	if (msSolLoadU8(body + 109) != 1 && msSolLoadU64(body + 64) != 0) { return NON_NATIVE_HAS_BALANCE; }
	if (isZeroKey(body + 32) || isKey(body + 32, INCINERATOR)) {
		if (!isKey(destination + 8, INCINERATOR)) { return INVALID_ACCOUNT_DATA; }
	} else {
		status = authorized(call, 2, msSolLoadU8(body + 129) == 1 ? body + 133 : body + 32);
		if (status != 0) { return status; }
	}
	const lamports = lamportsOf(source);
	if (lamports > UINT64_MAX - lamportsOf(destination)) { return OVERFLOW; }
	if (!ownedByCallee(call, source)) {
		fault(REFUSED, "ExternalAccountLamportSpend: sol_invoke_signed: the Token program spent the lamports of an account it does not own");
		return INCORRECT_PROGRAM_ID;
	}
	setLamportsOf(destination, lamportsOf(destination) + lamports);
	setLamportsOf(source, 0);
	msSolFill(body, 0, recordLength(source));
	resizeRecord(source, 0);
	msSolFill(source + OWNER_AT, 0, 32);
	return 0;
}

// host.c msSolHostAuthorityOf
function authorityOf(call: Call, target: uint64, option: uint64, holder: uint64, next: uint64): uint64 {
	const status = authorized(call, 1, holder);
	if (status != 0) { return status; }
	const before = snapshot(option, 36);
	storeOption(call, option, next);
	return written(call, target, option, before);
}

// host.c msSolHostSetAuthority
function setAuthority(call: Call): uint64 {
	const target = recordOf(call, 0);
	if (call.length < 3) { return shortData(call); }
	const kind = msSolLoadU8(call.data + 1);
	const hasNext = msSolLoadU8(call.data + 2);
	const needed: uint64 = hasNext == 1 ? 35 : 3;
	if (hasNext > 1 || call.length < needed) { return shortData(call); }
	if (kind > 3) {
		if (isToken2022(call)) { fault(NOT_SIMULATED, "sol_invoke_signed: a Token-2022 extension authority is not simulated"); }
		return INVALID_INSTRUCTION;
	}
	const next: uint64 = hasNext == 1 ? call.data + 3 : 0;
	if (target == 0 || recordOf(call, 1) == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	if (isToken2022(call) && !ownedByCallee(call, target)) { return INCORRECT_PROGRAM_ID; }
	const body = fields(target);
	const blank = isToken2022(call) ? INVALID_ACCOUNT_DATA : UNINITIALIZED_ACCOUNT;
	if (hasTokenLayout(call, target, ACCOUNT_LENGTH, 2)) {
		const state = msSolLoadU8(body + 108);
		if (state == 0) { return blank; }
		if (state == 2) { return ACCOUNT_FROZEN; }
		if (kind == 3) {
			return authorityOf(call, target, body + 129, msSolLoadU8(body + 129) == 1 ? body + 133 : body + 32, next);
		}
		if (kind != 2) { return AUTHORITY_TYPE_NOT_SUPPORTED; }
		const status = authorized(call, 1, body + 32);
		if (status != 0) { return status; }
		if (hasExtension(target, 7)) { return IMMUTABLE_OWNER; }
		if (next == 0) { return INVALID_INSTRUCTION; }
		const before = snapshot(body, ACCOUNT_LENGTH);
		msSolCopy(body + 32, next, 32);
		storeOption(call, body + 72, 0);
		msSolStoreU64(body + 121, 0);
		if (msSolLoadU8(body + 109) == 1) { storeOption(call, body + 129, 0); }
		return written(call, target, body, before);
	}
	if (hasTokenLayout(call, target, MINT_LENGTH, 1)) {
		if (msSolLoadU8(body + 45) == 0) { return blank; }
		if (kind > 1) { return AUTHORITY_TYPE_NOT_SUPPORTED; }
		const option = kind == 0 ? body : body + 46;
		if (msSolLoadU8(option) == 0) { return kind == 0 ? FIXED_SUPPLY : MINT_CANNOT_FREEZE; }
		return authorityOf(call, target, option, option + 4, next);
	}
	return isToken2022(call) ? INVALID_ACCOUNT_DATA : INVALID_ARGUMENT;
}

// host.c msSolHostInitializeMint2
function initializeMint2(call: Call): uint64 {
	const mint = recordOf(call, 0);
	const extended = isToken2022(call);
	if (call.length < 35) { return shortData(call); }
	const hasFreeze = msSolLoadU8(call.data + 34);
	const needed: uint64 = hasFreeze == 1 ? 67 : 35;
	if (hasFreeze > 1 || call.length < needed) { return shortData(call); }
	if (mint == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	if (extended && !ownedByCallee(call, mint)) { return INCORRECT_PROGRAM_ID; }
	const length = recordLength(mint);
	if (length != MINT_LENGTH) {
		if (extended && length > ACCOUNT_LENGTH) {
			fault(NOT_SIMULATED, "sol_invoke_signed: InitializeMint2 of a Token-2022 mint with extensions is not simulated");
		}
		return INVALID_ACCOUNT_DATA;
	}
	const body = fields(mint);
	const belowRent = lamportsOf(mint) < rentExemptFor(MINT_LENGTH);
	if (extended && belowRent) { return NOT_RENT_EXEMPT; }
	if (msSolLoadU8(body + 45) != 0) { return ALREADY_IN_USE; }
	if (belowRent) { return NOT_RENT_EXEMPT; }
	if (!ownedByCallee(call, mint)) { return foreignAccount(call); }
	storeOption(call, body, call.data + 2);
	msSolStoreU8(body + 44, msSolLoadU8(call.data + 1));
	msSolStoreU8(body + 45, 1);
	storeOption(call, body + 46, hasFreeze == 1 ? call.data + 35 : 0);
	return 0;
}

// host.c msSolHostExtensionInForce
function extensionInForce(kind: uint16, body: uint64, size: uint16): boolean {
	if (kind == 1) { return size >= 108 && (anyByte(body, 88, 90) || anyByte(body, 106, 108)); }
	if (kind == 14) { return size >= 64 && anyByte(body, 32, 64); }
	if (kind == 26) { return size >= 33 && msSolLoadU8(body + 32) != 0; }
	if (kind == 2 || kind == 4 || kind == 5 || kind == 8 || kind == 11 || kind == 12 || kind == 16 || kind == 17 || kind == 24) {
		return anyByte(body, 0, size as uint64);
	}
	return false;
}

function anyByte(bytes: uint64, from: uint64, to: uint64): boolean {
	for (let index = from; index < to; index++) {
		if (msSolLoadU8(bytes + index) != 0) { return true; }
	}
	return false;
}

// host.c msSolHostExtensionNotSimulated
function extensionNotSimulated(call: Call): boolean {
	const count = msSolLoadU64(call.header + 16);
	for (let index: uint64 = 0; index < count; index++) {
		const record = recordOf(call, index);
		const length = recordLength(record);
		if (!ownedByCallee(call, record) || length == MULTISIG_LENGTH) { continue; }
		const data = fields(record);
		let offset: uint64 = ACCOUNT_LENGTH + 1;
		while (offset + 4 <= length) {
			const kind = msSolLoadU16(data + offset);
			const size = msSolLoadU16(data + offset + 2);
			if (kind == 0 || (size as uint64) > length - offset - 4) { break; }
			if (extensionInForce(kind, data + offset + 4, size)) {
				fault(NOT_SIMULATED, `sol_invoke_signed: Token-2022 extension ${kind} with a setting in force is not simulated`);
				return true;
			}
			offset += 4 + (size as uint64);
		}
	}
	return false;
}

// host.c msSolHostToken
export function tokenInvoke(header: uint64): uint64 {
	const call = callOf(header);
	if (call.length < 1) { return INVALID_INSTRUCTION; }
	if (isToken2022(call) && extensionNotSimulated(call)) { return INVALID_ACCOUNT_DATA; }
	const tag = msSolLoadU8(call.data);
	if (tag == 3) { return transfer(call, false); }
	if (tag == 7) { return mintTo(call); }
	if (tag == 9) { return closeAccount(call); }
	if (tag == 12) { return transfer(call, true); }
	if (tag == 5) { return revoke(call); }
	if (tag == 6) { return setAuthority(call); }
	if (tag == 13) { return approveChecked(call); }
	if (tag == 8) { return burn(call, false); }
	if (tag == 15) { return burn(call, true); }
	if (tag == 18) {
		if (fixedDataRefused(call, 33)) { return shortData(call); }
		return initializeAccount3(call, recordOf(call, 0), recordOf(call, 1), call.data + 1, false);
	}
	if (tag == 20) { return initializeMint2(call); }
	return notSimulated(isToken2022(call) ? "Token-2022" : "Token", tag, INVALID_INSTRUCTION);
}

// host.c msSolHostAssociated
export function associatedInvoke(header: uint64): uint64 {
	const call = callOf(header);
	const tag = call.length >= 1 ? msSolLoadU8(call.data) : 0;
	if (call.length >= 1 && tag > 1) { return notSimulated("Associated Token", tag, INVALID_INSTRUCTION_DATA); }
	const payer = recordOf(call, 0);
	const associated = recordOf(call, 1);
	const wallet = recordOf(call, 2);
	const mint = recordOf(call, 3);
	const program = recordOf(call, 5);
	if (payer == 0 || associated == 0 || wallet == 0 || mint == 0 || program == 0) { return NOT_ENOUGH_ACCOUNT_KEYS; }
	const seeds: uint64[] = [wallet + 8, 32, program + 8, 32, mint + 8, 32];
	const associatedProgram: uint64[] = [ASSOCIATED_PROGRAM[0], ASSOCIATED_PROGRAM[1], ASSOCIATED_PROGRAM[2], ASSOCIATED_PROGRAM[3]];
	const address: uint64[] = [0, 0, 0, 0];
	const bump: uint64[] = [0];
	const found = msSolHostTryFindProgramAddress(
		msSolWordsAddress(seeds), 3, msSolWordsAddress(associatedProgram), msSolWordsAddress(address), msSolWordsAddress(bump),
	);
	if (found != 0 || !sameKey(msSolWordsAddress(address), associated + 8)) { return INVALID_SEEDS; }
	if (!isKey(program + 8, TOKEN_PROGRAM) && !isKey(program + 8, TOKEN_2022_PROGRAM)) {
		fault(NOT_SIMULATED, "sol_invoke_signed: an associated account under a program that is not a token program is not simulated");
		return INCORRECT_PROGRAM_ID;
	}
	const inner: Call = { header: 0, program: program + 8, data: 0, length: 33 };
	const idempotent = call.length >= 1 && tag == 1;
	if (idempotent && ownedByCallee(inner, associated) && tokenAccount(inner, associated) == 0) {
		if (!sameKey(fields(associated) + 32, wallet + 8)) { return NOT_RENT_EXEMPT; }
		if (!sameKey(fields(associated), mint + 8)) { return INVALID_ACCOUNT_DATA; }
		return 0;
	}
	if (!isZeroKey(associated + OWNER_AT)) { return ILLEGAL_OWNER; }
	if (recordLength(associated) != 0) {
		fault(NOT_SIMULATED, "sol_invoke_signed: an associated account at a System-owned address that holds data is not simulated");
		return INVALID_ACCOUNT_DATA;
	}
	const extended = isToken2022(inner);
	if (!isKey(mint + 8, extended ? NATIVE_MINT_2022 : NATIVE_MINT)) {
		if (!ownedByCallee(inner, mint)) { return INCORRECT_PROGRAM_ID; }
		if (mintAccount(inner, mint) != 0) { return INVALID_MINT; }
	}
	let space: uint64 = ACCOUNT_LENGTH;
	if (extended) { space += 1 + (accountExtensionsOf(mint, true).bytes.length as uint64); }
	const rent = rentExemptFor(space);
	const held = lamportsOf(associated);
	const missing = rent > held ? rent - held : 0;
	if (missing != 0) {
		if (msSolLoadU8(msSolLoadU64(call.header + 8) + META_SIGNER_AT) == 0) {
			refuses("PrivilegeEscalation: sol_invoke_signed: the Associated Token program funds the account from a payer that did not sign");
			return MISSING_REQUIRED_SIGNATURE;
		}
		if (lamportsOf(payer) < missing) { return 1; }
	}
	const status = resizeRecord(associated, space);
	if (status != 0) { return status; }
	setLamportsOf(payer, lamportsOf(payer) - missing);
	setLamportsOf(associated, held + missing);
	msSolCopy(associated + OWNER_AT, program + 8, 32);
	return initializeAccount3(inner, associated, mint, wallet + 8, true);
}
