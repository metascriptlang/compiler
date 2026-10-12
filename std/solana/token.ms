import {
	Account,
	Bytes,
	InstructionAccount,
	System,
	createProgramAccount,
	putPubkey,
	putU64,
	putU8,
	unchecked,
} from "./core";
import {
	External,
	ExternalMutable,
	Program,
	Signer,
	Writable,
	WritableSigner,
	asAccount,
} from "./typed";
import { ProgramError } from "./error";
import { invoke, invokeSigned } from "./invoke";
import { associatedTokenAddress, isTokenProgram } from "./mint";
import {
	ASSOCIATED_TOKEN_PROGRAM_ID,
	Pubkey,
	SYSTEM_PROGRAM_ID,
	TOKEN_2022_PROGRAM_ID,
	TOKEN_PROGRAM_ID,
} from "./pubkey";
import { SignerSeeds } from "./seed";

export { associatedTokenAddress, initializeMint2 } from "./mint";
export { createMintPda } from "./macro";

when (testBuild) {
	import {
		account,
		failWith,
		instructionData,
		logU64,
	} from "./core";
	import {
		external,
		accounts,
		externalMutable,
		writable,
		writableSigner,
	} from "./typed";
	import { HostAccount, invocations, logs, run, signerIs, textBytes } from "./host";
	import {
		associated,
		findProgramAddressOf,
		signed,
		tokenAuthority,
		tokenMint,
	} from "./macro";
}

export enum TokenAccountState {
	Uninitialized = 0,
	Initialized = 1,
	Frozen = 2,
}

export struct Mint {
	mintAuthority: Pubkey | null;
	supply: uint64;
	decimals: uint8;
	freezeAuthority: Pubkey | null;
}

export struct GroupMemberPointer {
	authority: Pubkey | null;
	memberAddress: Pubkey | null;
}

export struct TokenGroupMember {
	mint: Pubkey;
	group: Pubkey;
	memberNumber: uint64;
}

export struct TokenAccount {
	mint: Pubkey;
	owner: Pubkey;
	amount: uint64;
	delegate: Pubkey | null;
	state: TokenAccountState;
	nativeReserve: uint64 | null;
	delegatedAmount: uint64;
	closeAuthority: Pubkey | null;
}

export enum ExtensionType {
	Uninitialized = 0,
	TransferFeeConfig = 1,
	TransferFeeAmount = 2,
	MintCloseAuthority = 3,
	ConfidentialTransferMint = 4,
	ConfidentialTransferAccount = 5,
	DefaultAccountState = 6,
	ImmutableOwner = 7,
	MemoTransfer = 8,
	NonTransferable = 9,
	InterestBearingConfig = 10,
	CpiGuard = 11,
	PermanentDelegate = 12,
	NonTransferableAccount = 13,
	TransferHook = 14,
	TransferHookAccount = 15,
	ConfidentialTransferFeeConfig = 16,
	ConfidentialTransferFeeAmount = 17,
	MetadataPointer = 18,
	TokenMetadata = 19,
	GroupPointer = 20,
	TokenGroup = 21,
	GroupMemberPointer = 22,
	TokenGroupMember = 23,
	ConfidentialMintBurn = 24,
	ScaledUiAmount = 25,
	Pausable = 26,
	PausableAccount = 27,
	PermissionedBurn = 28,
}

function extensionNotFound(): ProgramError {
	return ProgramError.custom(48);
}

function hasExtensionLayout(data: Bytes, accountType: uint8): Result<boolean, ProgramError> {
	if (data.length == 355 || data.length <= 165) { return Result.ok(false); }
	return Result.ok((try data.readU8(165)) == accountType);
}

function canonicalTag(data: Bytes, offset: uint64): Result<void, ProgramError> {
	if ((try data.readU32(offset)) > 1) { return Result.err(ProgramError.invalidAccountData()); }
	return Result.ok(null);
}

function optionalKey(data: Bytes, offset: uint64): Result<Pubkey | null, ProgramError> {
	let key: Pubkey | null = null;
	if ((try data.readU32(offset)) == 1) { key = try data.readPubkey(offset + 4); }
	return Result.ok(key);
}

function stateOf(value: uint8): Result<TokenAccountState, ProgramError> {
	return match (value) {
		0 => Result.ok(TokenAccountState.Uninitialized),
		1 => Result.ok(TokenAccountState.Initialized),
		2 => Result.ok(TokenAccountState.Frozen),
		_ => Result.err(ProgramError.invalidAccountData()),
	};
}

function mintBytes(account: Account): Result<Bytes, ProgramError> {
	const data = account.data();
	if (account.isOwnedBy(TOKEN_PROGRAM_ID)) {
		if (data.length != 82) { return Result.err(ProgramError.invalidAccountData()); }
		return Result.ok(data);
	}
	if (!account.isOwnedBy(TOKEN_2022_PROGRAM_ID)) {
		return Result.err(ProgramError.invalidAccountOwner());
	}
	if (data.length != 82 && !(try hasExtensionLayout(data, 1))) {
		return Result.err(ProgramError.invalidAccountData());
	}
	return Result.ok(data);
}

function tokenAccountBytes(account: Account): Result<Bytes, ProgramError> {
	const data = account.data();
	if (account.isOwnedBy(TOKEN_PROGRAM_ID)) {
		if (data.length != 165) { return Result.err(ProgramError.invalidAccountData()); }
		return Result.ok(data);
	}
	if (!account.isOwnedBy(TOKEN_2022_PROGRAM_ID)) {
		return Result.err(ProgramError.invalidAccountData());
	}
	if (data.length != 165 && !(try hasExtensionLayout(data, 2))) {
		return Result.err(ProgramError.invalidAccountData());
	}
	return Result.ok(data);
}

function mintFields(data: Bytes): Result<Mint, ProgramError> {
	const _authority = try canonicalTag(data, 0);
	const _freeze = try canonicalTag(data, 46);
	if ((try data.readU8(45)) != 1) { return Result.err(ProgramError.uninitializedAccount()); }
	return Result.ok({
		mintAuthority: try optionalKey(data, 0),
		supply: try data.readU64(36),
		decimals: try data.readU8(44),
		freezeAuthority: try optionalKey(data, 46),
	});
}

export function readMint(this account: Account): Result<Mint, ProgramError> {
	const data = try mintBytes(account);
	return mintFields(data);
}

function tokenAccountFields(data: Bytes): Result<TokenAccount, ProgramError> {
	const _delegate = try canonicalTag(data, 72);
	const _native = try canonicalTag(data, 109);
	const _close = try canonicalTag(data, 129);
	const state = try stateOf(try data.readU8(108));
	if (state == TokenAccountState.Uninitialized) {
		return Result.err(ProgramError.uninitializedAccount());
	}
	let nativeReserve: uint64 | null = null;
	if ((try data.readU32(109)) == 1) { nativeReserve = try data.readU64(113); }
	return Result.ok({
		mint: try data.readPubkey(0),
		owner: try data.readPubkey(32),
		amount: try data.readU64(64),
		delegate: try optionalKey(data, 72),
		state: state,
		nativeReserve: nativeReserve,
		delegatedAmount: try data.readU64(121),
		closeAuthority: try optionalKey(data, 129),
	});
}

export function readTokenAccount(this account: Account): Result<TokenAccount, ProgramError> {
	const data = try tokenAccountBytes(account);
	return tokenAccountFields(data);
}

function mintReadable(account: Account): boolean {
	const bytes = mintBytes(account);
	if (!bytes.ok) { return false; }
	const initialized = bytes.value.readU8(45);
	return initialized.ok && initialized.value == 1;
}

function tokenAccountReadable(account: Account): boolean {
	const bytes = tokenAccountBytes(account);
	if (!bytes.ok) { return false; }
	const state = bytes.value.readU8(108);
	return state.ok && (state.value == 1 || state.value == 2);
}

function extensionBase(kind: ExtensionType): uint8 {
	return match (kind) {
		ExtensionType.Uninitialized => 0,
		ExtensionType.TransferFeeAmount |
			ExtensionType.ConfidentialTransferAccount |
			ExtensionType.ImmutableOwner |
			ExtensionType.MemoTransfer |
			ExtensionType.CpiGuard |
			ExtensionType.NonTransferableAccount |
			ExtensionType.TransferHookAccount |
			ExtensionType.ConfidentialTransferFeeAmount |
			ExtensionType.PausableAccount => 2,
		_ => 1,
	};
}

function extensionIn(data: Bytes, kind: ExtensionType): Result<Bytes, ProgramError> {
	const start = Math.min(data.length, 166);
	const tlv = try data.range(start, data.length - start);
	const target = (kind as int32) as uint64;
	let offset: uint64 = 0;
	while (tlv.length - offset >= 4) {
		const found = (try tlv.readU16(offset)) as uint64;
		const length = (try tlv.readU16(offset + 2)) as uint64;
		if (found == 0) { return Result.err(extensionNotFound()); }
		if (length > tlv.length - offset - 4) {
			return Result.err(ProgramError.invalidAccountData());
		}
		if (found == target) { return tlv.range(offset + 4, length); }
		offset = offset + 4 + length;
	}
	if (offset == tlv.length) { return Result.err(extensionNotFound()); }
	return Result.err(ProgramError.invalidAccountData());
}

function withExtensions(
	data: Bytes,
	base: uint64,
	accountType: uint8,
): Result<Bytes, ProgramError> {
	if (data.length == 355) { return Result.err(ProgramError.invalidAccountData()); }
	if (data.length == base) { return Result.ok(data); }
	if (data.length <= 165) { return Result.err(ProgramError.invalidAccountData()); }
	if (accountType == 1) {
		for (let offset: uint64 = 82; offset < 165; offset++) {
			if ((try data.readU8(offset)) != 0) {
				return Result.err(ProgramError.invalidAccountData());
			}
		}
	}
	if ((try data.readU8(165)) != accountType) {
		return Result.err(ProgramError.invalidAccountData());
	}
	return Result.ok(data);
}

export function mintExtension(
	this account: Account,
	kind: ExtensionType,
): Result<Bytes, ProgramError> {
	if (!account.isOwnedBy(TOKEN_2022_PROGRAM_ID)) {
		return Result.err(ProgramError.invalidAccountOwner());
	}
	const data = try withExtensions(account.data(), 82, 1);
	if (extensionBase(kind) != 1) { return Result.err(ProgramError.invalidAccountData()); }
	return extensionIn(data, kind);
}

function maybeNull(key: Pubkey): Pubkey | null {
	if (key.isZero()) { return null; }
	return key;
}

export function groupMemberPointer(this account: Account): Result<GroupMemberPointer, ProgramError> {
	const bytes = try account.mintExtension(ExtensionType.GroupMemberPointer);
	if (bytes.length != 64) { return Result.err(ProgramError.invalidArgument()); }
	return Result.ok({
		authority: maybeNull(try bytes.readPubkey(0)),
		memberAddress: maybeNull(try bytes.readPubkey(32)),
	});
}

export function tokenGroupMember(this account: Account): Result<TokenGroupMember, ProgramError> {
	const bytes = try account.mintExtension(ExtensionType.TokenGroupMember);
	if (bytes.length != 72) { return Result.err(ProgramError.invalidArgument()); }
	return Result.ok({
		mint: try bytes.readPubkey(0),
		group: try bytes.readPubkey(32),
		memberNumber: try bytes.readU64(64),
	});
}

export function tokenAccountExtension(
	this account: Account,
	kind: ExtensionType,
): Result<Bytes, ProgramError> {
	if (!account.isOwnedBy(TOKEN_2022_PROGRAM_ID)) {
		return Result.err(ProgramError.invalidAccountOwner());
	}
	const data = try withExtensions(account.data(), 165, 2);
	if (extensionBase(kind) != 2) { return Result.err(ProgramError.invalidAccountData()); }
	return extensionIn(data, kind);
}

export function mintTo(
	program: Pubkey,
	mint: Account,
	destination: Account,
	authority: Account,
	amount: uint64,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[9] = [];
	const length = putU64(storage, putU8(storage, 0, 7), amount);
	return invokeSigned(
		program,
		[
			InstructionAccount.writable(mint),
			InstructionAccount.writable(destination),
			InstructionAccount.readonlySigner(authority),
		],
		storage,
		length,
		signers,
	);
}

export function transferChecked(
	program: Pubkey,
	source: Account,
	mint: Account,
	destination: Account,
	authority: Account,
	amount: uint64,
	decimals: uint8,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[10] = [];
	let length = putU8(storage, 0, 12);
	length = putU64(storage, length, amount);
	length = putU8(storage, length, decimals);
	return invokeSigned(
		program,
		[
			InstructionAccount.writable(source),
			InstructionAccount.readonly(mint),
			InstructionAccount.writable(destination),
			InstructionAccount.readonlySigner(authority),
		],
		storage,
		length,
		signers,
	);
}

export function closeAccount(
	program: Pubkey,
	account: Account,
	destination: Account,
	authority: Account,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[1] = [];
	const length = putU8(storage, 0, 9);
	return invokeSigned(
		program,
		[
			InstructionAccount.writable(account),
			InstructionAccount.writable(destination),
			InstructionAccount.readonlySigner(authority),
		],
		storage,
		length,
		signers,
	);
}

export function burnChecked(
	program: Pubkey,
	account: Account,
	mint: Account,
	authority: Account,
	amount: uint64,
	decimals: uint8,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[10] = [];
	let length = putU8(storage, 0, 15);
	length = putU64(storage, length, amount);
	length = putU8(storage, length, decimals);
	return invokeSigned(
		program,
		[
			InstructionAccount.writable(account),
			InstructionAccount.writable(mint),
			InstructionAccount.readonlySigner(authority),
		],
		storage,
		length,
		signers,
	);
}

export function revoke(
	program: Pubkey,
	source: Account,
	owner: Account,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[1] = [];
	const length = putU8(storage, 0, 5);
	return invokeSigned(
		program,
		[InstructionAccount.writable(source), InstructionAccount.readonlySigner(owner)],
		storage,
		length,
		signers,
	);
}

export function approveChecked(
	program: Pubkey,
	source: Account,
	mint: Account,
	delegate: Account,
	owner: Account,
	amount: uint64,
	decimals: uint8,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[10] = [];
	let length = putU8(storage, 0, 13);
	length = putU64(storage, length, amount);
	length = putU8(storage, length, decimals);
	return invokeSigned(
		program,
		[
			InstructionAccount.writable(source),
			InstructionAccount.readonly(mint),
			InstructionAccount.readonly(delegate),
			InstructionAccount.readonlySigner(owner),
		],
		storage,
		length,
		signers,
	);
}

export enum AuthorityType {
	MintTokens = 0,
	FreezeAccount = 1,
	AccountOwner = 2,
	CloseAccount = 3,
}

export function setAuthority(
	program: Pubkey,
	target: Account,
	authority: Account,
	kind: AuthorityType,
	next: Pubkey | null,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[35] = [];
	let length = putU8(storage, 0, 6);
	length = putU8(storage, length, kind as uint8);
	if (next === null) {
		length = putU8(storage, length, 0);
	} else {
		length = putU8(storage, length, 1);
		length = putPubkey(storage, length, next);
	}
	return invokeSigned(
		program,
		[InstructionAccount.writable(target), InstructionAccount.readonlySigner(authority)],
		storage,
		length,
		signers,
	);
}

export function initializeAccount3(
	program: Pubkey,
	account: Account,
	mint: Account,
	owner: Pubkey,
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[33] = [];
	const length = putPubkey(storage, putU8(storage, 0, 18), owner);
	return invoke(
		program,
		[InstructionAccount.writable(account), InstructionAccount.readonly(mint)],
		storage,
		length,
	);
}

function createAssociated(
	payer: Account,
	associated: Account,
	wallet: Account,
	mint: Account,
	systemProgram: Account,
	program: Account,
	discriminator: uint8,
	signers: Readonly<Span<SignerSeeds>>,
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program.key())) { return Result.err(ProgramError.incorrectProgramId()); }
	if (systemProgram.key() != SYSTEM_PROGRAM_ID) {
		return Result.err(ProgramError.incorrectProgramId());
	}
	let storage: uint8[1] = [];
	const length = putU8(storage, 0, discriminator);
	return invokeSigned(
		ASSOCIATED_TOKEN_PROGRAM_ID,
		[
			InstructionAccount.writableSigner(payer),
			InstructionAccount.writable(associated),
			InstructionAccount.readonly(wallet),
			InstructionAccount.readonly(mint),
			InstructionAccount.readonly(systemProgram),
			InstructionAccount.readonly(program),
		],
		storage,
		length,
		signers,
	);
}

export function createAssociatedToken(
	payer: Account,
	associated: Account,
	wallet: Account,
	mint: Account,
	systemProgram: Account,
	program: Account,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	return createAssociated(payer, associated, wallet, mint, systemProgram, program, 0, signers);
}

export function createAssociatedTokenIdempotent(
	payer: Account,
	associated: Account,
	wallet: Account,
	mint: Account,
	systemProgram: Account,
	program: Account,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	return createAssociated(payer, associated, wallet, mint, systemProgram, program, 1, signers);
}

export function acceptsOwner(this typeof Mint, owner: Pubkey): boolean {
	return isTokenProgram(owner);
}

export function decode(this typeof Mint, data: Bytes): Result<Mint, ProgramError> {
	const fits = data.length == 82 || (try hasExtensionLayout(data, 1) catch false);
	if (!fits) { return Result.err(ProgramError.accountDidNotDeserialize()); }
	const decoded = mintFields(data);
	if (!decoded.ok) { return Result.err(ProgramError.accountDidNotDeserialize()); }
	return decoded;
}

export function verify(this typeof Mint, index: int32): Result<Account, ProgramError> {
	const found = try unchecked(index);
	if (!found.isOwnedBy(TOKEN_PROGRAM_ID) && !found.isOwnedBy(TOKEN_2022_PROGRAM_ID)) {
		return Result.err(ProgramError.accountOwnedByWrongProgram());
	}
	if (!mintReadable(found)) { return Result.err(ProgramError.accountDidNotDeserialize()); }
	return Result.ok(found);
}

export function acceptsOwner(this typeof TokenAccount, owner: Pubkey): boolean {
	return isTokenProgram(owner);
}

export function decode(this typeof TokenAccount, data: Bytes): Result<TokenAccount, ProgramError> {
	const fits = data.length == 165 || (try hasExtensionLayout(data, 2) catch false);
	if (!fits) { return Result.err(ProgramError.accountDidNotDeserialize()); }
	const decoded = tokenAccountFields(data);
	if (!decoded.ok) { return Result.err(ProgramError.accountDidNotDeserialize()); }
	return decoded;
}

export function verify(this typeof TokenAccount, index: int32): Result<Account, ProgramError> {
	const found = try unchecked(index);
	if (!found.isOwnedBy(TOKEN_PROGRAM_ID) && !found.isOwnedBy(TOKEN_2022_PROGRAM_ID)) {
		return Result.err(ProgramError.accountOwnedByWrongProgram());
	}
	if (!tokenAccountReadable(found)) { return Result.err(ProgramError.accountDidNotDeserialize()); }
	return Result.ok(found);
}

function tokenProgramOf(mint: External<Mint>): Pubkey {
	return mint.asAccount().owner();
}

function mintDecimals(mint: External<Mint>): Result<uint8, ProgramError> {
	const decoded = try mint.asAccount().readMint();
	return Result.ok(decoded.decimals);
}

export function transferTokens(
	from: ExternalMutable<TokenAccount>,
	to: ExternalMutable<TokenAccount>,
	mint: External<Mint>,
	authority: Account,
	amount: uint64,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const decimals = try mintDecimals(mint);
	return transferChecked(
		tokenProgramOf(mint),
		from.asAccount(),
		mint.asAccount(),
		to.asAccount(),
		authority,
		amount,
		decimals,
		signers,
	);
}

export function mintTokens(
	mint: ExternalMutable<Mint>,
	to: ExternalMutable<TokenAccount>,
	authority: Account,
	amount: uint64,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const target = mint.asAccount();
	return mintTo(target.owner(), target, to.asAccount(), authority, amount, signers);
}

export function closeTokenAccount(
	account: ExternalMutable<TokenAccount>,
	destination: Writable,
	authority: Account,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const closing = account.asAccount();
	return closeAccount(closing.owner(), closing, destination.asAccount(), authority, signers);
}

const TOKEN_ACCOUNT_LENGTH: uint64 = 165;
const ACCOUNT_TYPE_BYTE: uint64 = 1;
const TRANSFER_FEE_AMOUNT_ENTRY: uint64 = 4 + 8;
const NON_TRANSFERABLE_AND_IMMUTABLE_OWNER_ENTRIES: uint64 = 4 + 4;
const TRANSFER_HOOK_ACCOUNT_ENTRY: uint64 = 4 + 1;
const PAUSABLE_ACCOUNT_ENTRY: uint64 = 4;

function entryWhen(mint: Account, kind: ExtensionType, entry: uint64): uint64 {
	return mint.mintExtension(kind).ok ? entry : 0;
}

function tokenAccountSpace(mint: Account): uint64 {
	if (!mint.isOwnedBy(TOKEN_2022_PROGRAM_ID)) { return TOKEN_ACCOUNT_LENGTH; }
	const entries = entryWhen(mint, ExtensionType.TransferFeeConfig, TRANSFER_FEE_AMOUNT_ENTRY) +
		entryWhen(mint, ExtensionType.NonTransferable, NON_TRANSFERABLE_AND_IMMUTABLE_OWNER_ENTRIES) +
		entryWhen(mint, ExtensionType.TransferHook, TRANSFER_HOOK_ACCOUNT_ENTRY) +
		entryWhen(mint, ExtensionType.Pausable, PAUSABLE_ACCOUNT_ENTRY);
	if (entries == 0) { return TOKEN_ACCOUNT_LENGTH; }
	return TOKEN_ACCOUNT_LENGTH + ACCOUNT_TYPE_BYTE + entries;
}

function expectSigning(
	account: Account,
	signers: Readonly<Span<SignerSeeds>>,
): Result<void, ProgramError> {
	if (signers.length == 0 && !account.isSigner()) {
		return Result.err(ProgramError.missingRequiredSignature());
	}
	return Result.ok(null);
}

function createdTokenAccount(
	payer: WritableSigner,
	target: Account,
	mint: External<Mint>,
	owner: Pubkey,
	signers: Readonly<Span<SignerSeeds>>,
): Result<uint64, ProgramError> {
	const minted = mint.asAccount();
	const program = minted.owner();
	const _created = try createProgramAccount(
		payer.asAccount(),
		target,
		tokenAccountSpace(minted),
		program,
		signers,
	);
	return initializeAccount3(program, target, minted, owner);
}

export function createTokenAccount(
	payer: WritableSigner,
	account: WritableSigner,
	mint: External<Mint>,
	owner: Pubkey,
): Result<uint64, ProgramError> {
	return createdTokenAccount(payer, account.asAccount(), mint, owner, []);
}

export function createTokenAccount(
	payer: WritableSigner,
	account: Writable,
	mint: External<Mint>,
	owner: Pubkey,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const target = account.asAccount();
	const _signing = try expectSigning(target, signers);
	return createdTokenAccount(payer, target, mint, owner, signers);
}

function burned(
	from: ExternalMutable<TokenAccount>,
	mint: ExternalMutable<Mint>,
	authority: Account,
	amount: uint64,
	signers: Readonly<Span<SignerSeeds>>,
): Result<uint64, ProgramError> {
	const minted = mint.asAccount();
	const decoded = try minted.readMint();
	return burnChecked(
		minted.owner(),
		from.asAccount(),
		minted,
		authority,
		amount,
		decoded.decimals,
		signers,
	);
}

export function burnTokens(
	from: ExternalMutable<TokenAccount>,
	mint: ExternalMutable<Mint>,
	authority: Signer,
	amount: uint64,
): Result<uint64, ProgramError> {
	return burned(from, mint, authority.asAccount(), amount, []);
}

export function burnTokens(
	from: ExternalMutable<TokenAccount>,
	mint: ExternalMutable<Mint>,
	authority: Account,
	amount: uint64,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const _signing = try expectSigning(authority, signers);
	return burned(from, mint, authority, amount, signers);
}

export function setAuthorityOf(
	mint: ExternalMutable<Mint>,
	kind: AuthorityType,
	authority: Signer,
	next: Pubkey | null,
): Result<uint64, ProgramError> {
	const target = mint.asAccount();
	return setAuthority(target.owner(), target, authority.asAccount(), kind, next);
}

export function setAuthorityOf(
	mint: ExternalMutable<Mint>,
	kind: AuthorityType,
	authority: Account,
	next: Pubkey | null,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const _signing = try expectSigning(authority, signers);
	const target = mint.asAccount();
	return setAuthority(target.owner(), target, authority, kind, next, signers);
}

export function setAuthorityOf(
	account: ExternalMutable<TokenAccount>,
	kind: AuthorityType,
	authority: Signer,
	next: Pubkey | null,
): Result<uint64, ProgramError> {
	const target = account.asAccount();
	return setAuthority(target.owner(), target, authority.asAccount(), kind, next);
}

export function setAuthorityOf(
	account: ExternalMutable<TokenAccount>,
	kind: AuthorityType,
	authority: Account,
	next: Pubkey | null,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const _signing = try expectSigning(authority, signers);
	const target = account.asAccount();
	return setAuthority(target.owner(), target, authority, kind, next, signers);
}

function approved(
	source: ExternalMutable<TokenAccount>,
	mint: External<Mint>,
	delegate: Account,
	authority: Account,
	amount: uint64,
	signers: Readonly<Span<SignerSeeds>>,
): Result<uint64, ProgramError> {
	const decimals = try mintDecimals(mint);
	return approveChecked(
		tokenProgramOf(mint),
		source.asAccount(),
		mint.asAccount(),
		delegate,
		authority,
		amount,
		decimals,
		signers,
	);
}

export function approveDelegate(
	source: ExternalMutable<TokenAccount>,
	mint: External<Mint>,
	delegate: Account,
	authority: Signer,
	amount: uint64,
): Result<uint64, ProgramError> {
	return approved(source, mint, delegate, authority.asAccount(), amount, []);
}

export function approveDelegate(
	source: ExternalMutable<TokenAccount>,
	mint: External<Mint>,
	delegate: Account,
	authority: Account,
	amount: uint64,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const _signing = try expectSigning(authority, signers);
	return approved(source, mint, delegate, authority, amount, signers);
}

export function revokeDelegate(
	source: ExternalMutable<TokenAccount>,
	authority: Signer,
): Result<uint64, ProgramError> {
	const held = source.asAccount();
	return revoke(held.owner(), held, authority.asAccount());
}

export function revokeDelegate(
	source: ExternalMutable<TokenAccount>,
	authority: Account,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const _signing = try expectSigning(authority, signers);
	const held = source.asAccount();
	return revoke(held.owner(), held, authority, signers);
}

export function createAssociatedFor(
	payer: WritableSigner,
	associated: Writable,
	wallet: Account,
	mint: External<Mint>,
	systemProgram: Program<System>,
	tokenProgram: Account,
): Result<uint64, ProgramError> {
	if (tokenProgram.key() != tokenProgramOf(mint)) {
		return Result.err(ProgramError.constraintAssociatedTokenTokenProgram());
	}
	return createAssociatedToken(
		payer.asAccount(),
		associated.asAccount(),
		wallet,
		mint.asAccount(),
		systemProgram.asAccount(),
		tokenProgram,
	);
}

export function expectAssociated(
	tokenAccount: Pubkey,
	wallet: Pubkey,
	mint: External<Mint>,
): Result<void, ProgramError> {
	const mintKey = mint.asAccount().key();
	const derived = try associatedTokenAddress(wallet, mintKey, tokenProgramOf(mint));
	if (derived.key != tokenAccount) {
		return Result.err(ProgramError.accountNotAssociatedTokenAccount());
	}
	return Result.ok(null);
}

export function expectTokenMint(token: TokenAccount, mint: Pubkey): Result<void, ProgramError> {
	if (token.mint != mint) { return Result.err(ProgramError.constraintTokenMint()); }
	return Result.ok(null);
}

export function expectTokenOwner(token: TokenAccount, owner: Pubkey): Result<void, ProgramError> {
	if (token.owner != owner) { return Result.err(ProgramError.constraintTokenOwner()); }
	return Result.ok(null);
}

when (testBuild) {
	function keyOf(word: uint64): Pubkey {
		let key = Pubkey.zero();
		for (let index = 0; index < 8; index++) {
			key.bytes[index] = ((word >> ((index * 8) as uint64)) & 255) as uint8;
		}
		return key;
	}

	function wordAt(key: Pubkey, word: int32): uint64 {
		let value: uint64 = 0;
		for (let index = word * 8 + 7; index >= word * 8; index--) {
			const byte: uint64 = key.bytes[index] as uint64;
			value = (value << 8) | byte;
		}
		return value;
	}

	function pushU64(bytes: uint8[], value: uint64): void {
		for (let index: uint64 = 0; index < 8; index++) {
			bytes.push(((value >> (index * 8)) & 255) as uint8);
		}
	}

	function pushU16(bytes: uint8[], value: uint64): void {
		bytes.push((value & 255) as uint8);
		bytes.push(((value >> 8) & 255) as uint8);
	}

	function pushKey(bytes: uint8[], key: Pubkey): void {
		for (let index = 0; index < 32; index++) { bytes.push(key.bytes[index]); }
	}

	function pushZeros(bytes: uint8[], count: int32): void {
		for (let index = 0; index < count; index++) { bytes.push(0); }
	}

	function mintData(authority: uint64, supply: uint64, decimals: uint8): uint8[] {
		const bytes: uint8[] = [1, 0, 0, 0];
		pushKey(bytes, keyOf(authority));
		pushU64(bytes, supply);
		bytes.push(decimals);
		bytes.push(1);
		pushZeros(bytes, 36);
		return bytes;
	}

	function tokenAccountData(mint: uint64, owner: uint64, amount: uint64, state: uint8): uint8[] {
		const bytes: uint8[] = [];
		pushKey(bytes, keyOf(mint));
		pushKey(bytes, keyOf(owner));
		pushU64(bytes, amount);
		pushZeros(bytes, 36);
		bytes.push(state);
		pushZeros(bytes, 20);
		bytes.push(1);
		pushZeros(bytes, 3);
		pushKey(bytes, keyOf(owner));
		return bytes;
	}

	function mint2022Data(): uint8[] {
		return memberMintData(keyOf(33), 64);
	}

	function memberMintData(authority: Pubkey, pointerLength: int32): uint8[] {
		const bytes = mintData(5, 1, 0);
		pushZeros(bytes, 83);
		bytes.push(1);
		pushU16(bytes, 18);
		pushU16(bytes, 64);
		pushZeros(bytes, 64);
		pushU16(bytes, 22);
		pushU16(bytes, pointerLength as uint64);
		pushKey(bytes, authority);
		pushKey(bytes, keyOf(44));
		pushZeros(bytes, pointerLength - 64);
		pushU16(bytes, 23);
		pushU16(bytes, 72);
		pushKey(bytes, keyOf(1));
		pushKey(bytes, keyOf(55));
		pushU64(bytes, 4242);
		return bytes;
	}

	function holderOf(word: uint64, owner: Pubkey, data: uint8[]): HostAccount {
		return {
			key: keyOf(word),
			owner: owner,
			lamports: 1000,
			data: data,
			signer: false,
			writable: true,
			executable: false,
		};
	}

	function single(owner: Pubkey, data: uint8[]): HostAccount[] {
		return [holderOf(1, owner, data)];
	}

	function resultOf(accounts: HostAccount[], op: uint8, entry: () => void): uint64 {
		const data: uint8[] = [op];
		return run(keyOf(9), accounts, data, entry).result;
	}

	function readerStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const holder = try account(0);
		if (op == 0) {
			const mint = try holder.readMint();
			const authority = mint.mintAuthority;
			logU64(mint.supply);
			logU64(mint.decimals as uint64);
			if (authority !== null) { logU64(wordAt(authority, 0)); }
			if (mint.freezeAuthority === null) { logU64(0); }
			return Result.ok(0);
		}
		if (op == 1) {
			const tokens = try holder.readTokenAccount();
			const closer = tokens.closeAuthority;
			logU64(tokens.amount);
			logU64((tokens.state as int32) as uint64);
			if (tokens.delegate === null && tokens.nativeReserve === null) { logU64(0); }
			if (closer !== null) { logU64(wordAt(closer, 0)); }
			return Result.ok(0);
		}
		if (op == 2) {
			const member = try holder.mintExtension(ExtensionType.GroupMemberPointer);
			logU64(member.length);
			logU64(try member.readU64(32));
			return Result.ok(0);
		}
		if (op == 5) {
			const pointer = try holder.groupMemberPointer();
			const authority = pointer.authority;
			const member = pointer.memberAddress;
			if (authority === null) { logU64(0); } else { logU64(wordAt(authority, 0)); }
			if (member !== null) { logU64(wordAt(member, 0)); }
			return Result.ok(0);
		}
		if (op == 6) {
			const member = try holder.tokenGroupMember();
			logU64(wordAt(member.mint, 0));
			logU64(wordAt(member.group, 0));
			logU64(member.memberNumber);
			return Result.ok(0);
		}
		const kind = op == 3 ? ExtensionType.TransferHook : ExtensionType.ImmutableOwner;
		return Result.ok((try holder.mintExtension(kind)).length);
	}

	function readerEntry(): void {
		const result = readerStep();
		if (!result.ok) { failWith(result.error); }
	}

	function sameBytes(left: uint8[], right: uint8[]): boolean {
		if (left.length != right.length) { return false; }
		for (let index = 0; index < left.length; index++) {
			if (left[index] != right[index]) { return false; }
		}
		return true;
	}

	function logged(line: string): string {
		return `Program log: 0x0, 0x0, 0x0, 0x0, ${line}`;
	}

	test "readMint reads a token mint's supply, decimals and authorities" {
		const accounts = single(TOKEN_PROGRAM_ID, mintData(5, 1000000, 6));
		assert resultOf(accounts, 0, readerEntry) == 0;
		const lines = logs();
		assert lines[0] == logged("0xf4240");
		assert lines[1] == logged("0x6");
		assert lines[2] == logged("0x5");
		assert lines[3] == logged("0x0");
	}

	test "readMint refuses a foreign owner, a wrong length and an uninitialized mint" {
		const foreign = single(keyOf(3), mintData(5, 1, 6));
		assert resultOf(foreign, 0, readerEntry) == ProgramError.invalidAccountOwner().code;
		const short = mintData(5, 1, 6);
		short.pop();
		const shortened = single(TOKEN_PROGRAM_ID, short);
		assert resultOf(shortened, 0, readerEntry) == ProgramError.invalidAccountData().code;
		const blank = mintData(5, 1, 6);
		blank[45] = 0;
		const uninitialized = single(TOKEN_PROGRAM_ID, blank);
		assert resultOf(uninitialized, 0, readerEntry) == ProgramError.uninitializedAccount().code;
	}

	test "readTokenAccount reads amount, state and the close authority at their byte offsets" {
		const accounts = single(TOKEN_PROGRAM_ID, tokenAccountData(4, 8, 77, 2));
		assert resultOf(accounts, 1, readerEntry) == 0;
		const lines = logs();
		assert lines[0] == logged("0x4d");
		assert lines[1] == logged("0x2");
		assert lines[2] == logged("0x0");
		assert lines[3] == logged("0x8");
	}

	test "a token account with an unknown state byte is refused" {
		const accounts = single(TOKEN_PROGRAM_ID, tokenAccountData(4, 8, 77, 3));
		assert resultOf(accounts, 1, readerEntry) == ProgramError.invalidAccountData().code;
	}

	test "a mint with a COption tag other than 0 or 1 is refused before its initialized byte is read" {
		for (const bad of [[0, 2], [1, 2], [3, 1]] as int32[][]) {
			const authority = mintData(5, 1, 6);
			authority[bad[0]] = bad[1] as uint8;
			assert resultOf(single(TOKEN_PROGRAM_ID, authority), 0, readerEntry) == ProgramError.invalidAccountData().code;
		}
		const freeze = mintData(5, 1, 6);
		freeze[49] = 1;
		assert resultOf(single(TOKEN_PROGRAM_ID, freeze), 0, readerEntry) == ProgramError.invalidAccountData().code;
		const blank = mintData(5, 1, 6);
		blank[1] = 2;
		blank[45] = 0;
		assert resultOf(single(TOKEN_PROGRAM_ID, blank), 0, readerEntry) == ProgramError.invalidAccountData().code;
		const none = mintData(5, 1, 6);
		none[0] = 0;
		assert resultOf(single(TOKEN_PROGRAM_ID, none), 0, readerEntry) == 0;
	}

	test "a token account with a COption tag other than 0 or 1 is refused at each of its three tags" {
		for (const offset of [72, 109, 129] as int32[]) {
			for (const at of [0, 1, 3] as int32[]) {
				const bytes = tokenAccountData(4, 8, 77, 2);
				bytes[offset + at] = 2;
				assert resultOf(single(TOKEN_PROGRAM_ID, bytes), 1, readerEntry) == ProgramError.invalidAccountData().code;
			}
		}
		const blank = tokenAccountData(4, 8, 77, 0);
		blank[73] = 1;
		assert resultOf(single(TOKEN_PROGRAM_ID, blank), 1, readerEntry) == ProgramError.invalidAccountData().code;
	}

	test "mintExtension walks the Token-2022 TLV entries after byte 166" {
		const accounts = single(TOKEN_2022_PROGRAM_ID, mint2022Data());
		assert resultOf(accounts, 2, readerEntry) == 0;
		assert logs()[0] == logged("0x40");
		assert logs()[1] == logged("0x2c");
	}

	test "mintExtension reports a missing extension and refuses an account extension" {
		const accounts = single(TOKEN_2022_PROGRAM_ID, mint2022Data());
		assert resultOf(accounts, 3, readerEntry) == ProgramError.custom(48).code;
		assert resultOf(accounts, 4, readerEntry) == ProgramError.invalidAccountData().code;
		const plain = single(TOKEN_2022_PROGRAM_ID, mintData(5, 1, 0));
		assert resultOf(plain, 3, readerEntry) == ProgramError.custom(48).code;
	}

	test "groupMemberPointer and tokenGroupMember decode Token-2022's layouts" {
		const accounts = single(TOKEN_2022_PROGRAM_ID, mint2022Data());
		assert resultOf(accounts, 5, readerEntry) == 0;
		assert logs()[0] == logged("0x21") && logs()[1] == logged("0x2c");
		assert resultOf(accounts, 6, readerEntry) == 0;
		assert logs()[0] == logged("0x1") && logs()[1] == logged("0x37");
		assert logs()[2] == logged("0x1092");
		const unset = single(TOKEN_2022_PROGRAM_ID, memberMintData(Pubkey.zero(), 64));
		assert resultOf(unset, 5, readerEntry) == 0;
		assert logs()[0] == logged("0x0") && logs()[1] == logged("0x2c");
	}

	test "a group member pointer of another length is refused, as bytemuck refuses it" {
		const longer = single(TOKEN_2022_PROGRAM_ID, memberMintData(keyOf(33), 65));
		assert resultOf(longer, 5, readerEntry) == ProgramError.invalidArgument().code;
		const plain = single(TOKEN_PROGRAM_ID, mintData(5, 1, 0));
		assert resultOf(plain, 6, readerEntry) == ProgramError.invalidAccountOwner().code;
	}

	function cpiStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const mint = try account(0);
		const target = try account(1);
		const authority = try account(2);
		const payer = try account(3);
		const token = TOKEN_PROGRAM_ID;
		if (op == 7) {
			return signed(mintTo(token, mint, target, authority, 500), ["auth", [5]]);
		}
		if (op == 8) {
			return signed(
				transferChecked(token, payer, mint, target, authority, 250, 6),
				["auth", [5]],
			);
		}
		if (op == 9) {
			return signed(closeAccount(token, target, payer, authority), ["auth", [5]]);
		}
		if (op == 10) {
			const system = try account(4);
			const program = try account(5);
			return signed(
				createAssociatedToken(payer, target, authority, mint, system, program),
				["auth", [5]],
			);
		}
		if (op == 11) {
			const system = try account(4);
			const program = try account(5);
			return signed(
				createAssociatedTokenIdempotent(payer, target, authority, mint, system, program),
				["auth", [5]],
			);
		}
		if (op == 12) {
			const minting = try externalMutable<Mint>(0);
			const receiving = try externalMutable<TokenAccount>(1);
			return signed(mintTokens(minting, receiving, authority, 500), ["auth", [5]]);
		}
		if (op == 13) {
			const closing = try externalMutable<TokenAccount>(1);
			const destination = try writable(3);
			return signed(closeTokenAccount(closing, destination, authority), ["auth", [5]]);
		}
		if (op == 14) {
			const from = try externalMutable<TokenAccount>(3);
			const to = try externalMutable<TokenAccount>(1);
			const typed = try external<Mint>(0);
			return signed(transferTokens(from, to, typed, authority, 250), ["auth", [5]]);
		}
		if (op == 15) {
			const system = try account(4);
			const program = try account(5);
			return createAssociatedToken(payer, target, authority, mint, system, program);
		}
		if (op == 0) { return mintTo(token, mint, target, authority, 500); }
		if (op == 1) {
			const extended = TOKEN_2022_PROGRAM_ID;
			return transferChecked(extended, payer, mint, target, authority, 250, 6);
		}
		if (op == 2) { return closeAccount(token, target, payer, authority); }
		if (op == 3) { return initializeMint2(token, mint, 6, authority.key(), null); }
		if (op == 4) { return initializeMint2(token, mint, 6, authority.key(), payer.key()); }
		if (op == 5) {
			const system = try account(4);
			const program = try account(5);
			return createAssociatedTokenIdempotent(payer, target, authority, mint, system, program);
		}
		return mintTo(keyOf(3), mint, target, authority, 500);
	}

	function cpiEntry(): void {
		const result = cpiStep();
		if (!result.ok) { failWith(result.error); }
	}

	function cpiAccounts(): HostAccount[] {
		const program: HostAccount = {
			...holderOf(6, keyOf(0), []),
			key: TOKEN_PROGRAM_ID,
			writable: false,
			executable: true,
		};
		return [
			holderOf(1, TOKEN_PROGRAM_ID, mintData(7, 500, 6)),
			holderOf(2, TOKEN_PROGRAM_ID, tokenAccountData(1, 3, 0, 1)),
			{ ...holderOf(3, keyOf(0), []), signer: true, writable: false },
			{ ...holderOf(4, keyOf(0), tokenAccountData(1, 3, 900, 1)), signer: true },
			{ ...holderOf(0, keyOf(0), []), writable: false, executable: true },
			program,
		];
	}

	test "mintTo, transferChecked and closeAccount carry the token program's accounts and data" {
		assert resultOf(cpiAccounts(), 0, cpiEntry) == 0;
		const minted = invocations()[0];
		assert minted.program.equals(TOKEN_PROGRAM_ID);
		assert minted.accounts.length == 3;
		assert minted.accounts[0].writable && !minted.accounts[0].signer;
		assert minted.accounts[1].key.equals(keyOf(2)) && minted.accounts[1].writable;
		assert minted.accounts[2].signer && !minted.accounts[2].writable;
		const mintBytes: uint8[] = [7, 0xf4, 1, 0, 0, 0, 0, 0, 0];
		assert sameBytes(minted.data, mintBytes);

		assert resultOf(cpiAccounts(), 1, cpiEntry) == 0;
		const moved = invocations()[0];
		assert moved.program.equals(TOKEN_2022_PROGRAM_ID);
		assert moved.accounts[0].key.equals(keyOf(4)) && moved.accounts[0].writable;
		assert moved.accounts[1].key.equals(keyOf(1)) && !moved.accounts[1].writable;
		assert moved.accounts[2].key.equals(keyOf(2)) && moved.accounts[2].writable;
		assert moved.accounts[3].key.equals(keyOf(3)) && moved.accounts[3].signer;
		const moveBytes: uint8[] = [12, 250, 0, 0, 0, 0, 0, 0, 0, 6];
		assert sameBytes(moved.data, moveBytes);

		assert resultOf(cpiAccounts(), 2, cpiEntry) == 0;
		const closed = invocations()[0];
		assert closed.accounts[0].key.equals(keyOf(2)) && closed.accounts[1].key.equals(keyOf(4));
		assert closed.accounts[2].signer;
		const closeBytes: uint8[] = [9];
		assert sameBytes(closed.data, closeBytes);
	}

	test "initializeMint2 writes 35 bytes without a freeze authority and 67 with one" {
		assert resultOf(cpiAccounts(), 3, cpiEntry) == 0;
		const plain = invocations()[0];
		assert plain.accounts.length == 1;
		assert plain.accounts[0].writable && !plain.accounts[0].signer;
		assert plain.data.length == 35;
		assert plain.data[0] == 20 && plain.data[1] == 6;
		assert plain.data[2] == 3 && plain.data[34] == 0;
		assert resultOf(cpiAccounts(), 4, cpiEntry) == 0;
		const frozen = invocations()[0];
		assert frozen.data.length == 67;
		assert frozen.data[34] == 1 && frozen.data[35] == 4;
	}

	test "createAssociatedTokenIdempotent sends discriminator 1 with the six accounts in order" {
		assert resultOf(cpiAccounts(), 5, cpiEntry) == 0;
		const created = invocations()[0];
		assert created.program.equals(ASSOCIATED_TOKEN_PROGRAM_ID);
		assert created.accounts.length == 6;
		const funding = created.accounts[0];
		assert funding.key.equals(keyOf(4)) && funding.signer && funding.writable;
		assert created.accounts[1].key.equals(keyOf(2)) && created.accounts[1].writable;
		const program = created.accounts[5];
		assert program.key.equals(TOKEN_PROGRAM_ID) && !program.writable;
		assert created.data.length == 1 && created.data[0] == 1;
	}

	test "createAssociatedToken and its idempotent form refuse a system program account that is not System" {
		for (const op of [15, 5]) {
			const accounts = cpiAccounts();
			accounts[1].lamports = 0;
			accounts[3].lamports = 10000000;
			accounts[4].key = keyOf(8);
			assert resultOf(accounts, op as uint8, cpiEntry) == ProgramError.incorrectProgramId().code;
			assert invocations().length == 0 && accounts[3].lamports == 10000000;
		}
	}

	test "createAssociatedToken sends discriminator 0 with the six accounts and their flags" {
		const accounts = cpiAccounts();
		accounts[1].lamports = 0;
		accounts[3].lamports = 10000000;
		assert resultOf(accounts, 15, cpiEntry) == 0;
		const created = invocations()[0];
		assert created.program.equals(ASSOCIATED_TOKEN_PROGRAM_ID);
		assert created.accounts.length == 6;
		assert created.accounts[0].key.equals(keyOf(4)) && created.accounts[0].writable;
		assert created.accounts[0].signer;
		assert created.accounts[1].key.equals(keyOf(2)) && created.accounts[1].writable;
		assert !created.accounts[1].signer;
		assert created.accounts[2].key.equals(keyOf(3)) && !created.accounts[2].writable;
		assert !created.accounts[2].signer;
		assert created.accounts[3].key.equals(keyOf(1)) && !created.accounts[3].writable;
		assert created.accounts[4].key.equals(keyOf(0)) && !created.accounts[4].writable;
		assert created.accounts[5].key.equals(TOKEN_PROGRAM_ID) && !created.accounts[5].writable;
		assert created.data.length == 1 && created.data[0] == 0 && created.signers == 0;
	}

	function authSigner(): uint8[][] {
		return [textBytes("auth"), [5]];
	}

	test "each token CPI sends the signer seeds it was given" {
		for (const op of [7, 8, 9, 10, 11, 12, 13, 14]) {
			const accounts = cpiAccounts();
			if (op == 10) {
				accounts[1].lamports = 0;
				accounts[3].lamports = 10000000;
			}
			if (op == 14) { accounts[3].owner = TOKEN_PROGRAM_ID; }
			assert resultOf(accounts, op as uint8, cpiEntry) == 0;
			const calls = invocations();
			assert calls.length == 1 && calls[0].signers == 1;
			assert signerIs(calls[0], 0, authSigner());
		}
		assert resultOf(cpiAccounts(), 0, cpiEntry) == 0;
		const unsigned = invocations()[0];
		assert unsigned.signers == 0 && unsigned.signerSeeds.length == 0;
	}

	function mintPdaStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const program = op == 0 ? TOKEN_PROGRAM_ID : Pubkey.zero();
		const payer = try writableSigner(0);
		const mint = try writable(1);
		const bump = try createMintPda(payer, mint, ["mint"], program, 6, keyOf(7), null);
		return Result.ok(bump as uint64);
	}

	function mintPdaEntry(): void {
		const result = mintPdaStep();
		if (!result.ok) { failWith(result.error); }
	}

	function mintPdaAccounts(mintKey: Pubkey): HostAccount[] {
		const payer: HostAccount = {
			...holderOf(1, Pubkey.zero(), []),
			lamports: 10000000,
			signer: true,
		};
		const mint: HostAccount = {
			...holderOf(2, Pubkey.zero(), []),
			key: mintKey,
			lamports: 0,
		};
		return [payer, mint];
	}

	function mintKey(): Pubkey {
		const found = findProgramAddressOf(keyOf(9), ["mint"]);
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	test "createMintPda creates the mint at its PDA for the token program, then initializes it" {
		const accounts = mintPdaAccounts(mintKey());
		assert resultOf(accounts, 0, mintPdaEntry) == 0;
		assert accounts[1].owner.equals(TOKEN_PROGRAM_ID) && accounts[1].data.length == 82;
		assert accounts[1].lamports > 0;
		const created = invocations()[0];
		assert created.program.equals(Pubkey.zero()) && created.data[0] == 13;
		assert created.data.length == 52 && created.data[1] == 0 && created.data[2] == 0 && created.data[3] == 0;
		assert created.data[12] == 82 && created.signers == 1;
		for (let i = 0; i < 32; i++) { assert created.data[20 + i] == TOKEN_PROGRAM_ID.bytes[i]; }
		assert created.accounts.length == 2;
		assert created.accounts[0].key.equals(mintKey()) && created.accounts[0].writable && created.accounts[0].signer;
		assert created.accounts[1].key.equals(accounts[0].key) && created.accounts[1].writable && created.accounts[1].signer;
		const mintBump = findProgramAddressOf(keyOf(9), ["mint"]);
		assert mintBump.ok;
		if (mintBump.ok) { assert signerIs(created, 0, [textBytes("mint"), [mintBump.value.bump]]); }
		const initialized = invocations()[1];
		assert initialized.program.equals(TOKEN_PROGRAM_ID);
		assert initialized.accounts.length == 1 && initialized.accounts[0].key.equals(mintKey());
		assert initialized.data[0] == 20 && initialized.data[1] == 6 && initialized.data[2] == 7;
		assert initialized.data[34] == 0;
	}

	test "createMintPda refuses another address and a program that is not a token program" {
		assert resultOf(mintPdaAccounts(keyOf(3)), 0, mintPdaEntry) ==
			ProgramError.constraintSeeds().code;
		assert resultOf(mintPdaAccounts(mintKey()), 1, mintPdaEntry) ==
			ProgramError.incorrectProgramId().code;
		assert invocations().length == 0;
	}

	test "a CPI to a program that is not a token program is refused before it is sent" {
		assert resultOf(cpiAccounts(), 6, cpiEntry) == ProgramError.incorrectProgramId().code;
		assert invocations().length == 0;
	}

	test "associatedTokenAddress derives the address the associated token program derives" {
		const wallet = keyOf(0x51);
		const mint = keyOf(0x4d);
		const tokenWord0: uint64 = 0x68c7bc0b9c46ed44;
		const tokenWord3: uint64 = 0x04c88d35ee417be8;
		const classic = associatedTokenAddress(wallet, mint, TOKEN_PROGRAM_ID);
		assert classic.ok;
		if (classic.ok) {
			assert classic.value.bump == 255;
			assert wordAt(classic.value.key, 0) == tokenWord0;
			assert wordAt(classic.value.key, 3) == tokenWord3;
		}
		const extendedWord0: uint64 = 0xc080ac8fa7881df3;
		const extendedWord3: uint64 = 0x08b979898d73f9d3;
		const extended = associatedTokenAddress(wallet, mint, TOKEN_2022_PROGRAM_ID);
		assert extended.ok;
		if (extended.ok) {
			const found = extended.value.key;
			assert extended.value.bump == 254;
			assert wordAt(found, 0) == extendedWord0 && wordAt(found, 3) == extendedWord3;
		}
	}
}

when (testBuild) {
	export struct TransferAccounts {
		owner: Signer;
		from: ExternalMutable<TokenAccount>;
		to: ExternalMutable<TokenAccount>;
		mint: External<Mint>;
	}

	function typedTransferStep(): Result<uint64, ProgramError> {
		const x = try accounts<TransferAccounts>();
		const op = try instructionData().readU8(0);
		if (op == 1) {
			const _checked = try expectAssociated(x.from.key(), x.owner.key(), x.mint);
		}
		return transferTokens(x.from, x.to, x.mint, x.owner.asAccount(), 250);
	}

	function typedTransferEntry(): void {
		const result = typedTransferStep();
		if (!result.ok) { failWith(result.error); }
	}

	function typedAccounts(mintOwner: Pubkey, mintData: uint8[]): HostAccount[] {
		let owner = holderOf(3, Pubkey.zero(), []);
		owner.signer = true;
		return [
			owner,
			holderOf(4, TOKEN_2022_PROGRAM_ID, tokenAccountData(1, 3, 900, 1)),
			holderOf(5, TOKEN_2022_PROGRAM_ID, tokenAccountData(1, 6, 0, 1)),
			holderOf(1, mintOwner, mintData),
		];
	}

	function goodMint(): HostAccount[] {
		return typedAccounts(TOKEN_2022_PROGRAM_ID, mintData(7, 500, 6));
	}

	test "typed token accounts verify through accounts<T>() and transfer with the mint's decimals" {
		assert resultOf(goodMint(), 0, typedTransferEntry) == 0;
		const moved = invocations()[0];
		assert moved.program == TOKEN_2022_PROGRAM_ID;
		const moveBytes: uint8[] = [12, 250, 0, 0, 0, 0, 0, 0, 0, 6];
		assert sameBytes(moved.data, moveBytes);
	}

	test "a mint owned by another program or with a broken layout is refused with Anchor's codes" {
		const foreign = typedAccounts(Pubkey.zero(), mintData(7, 500, 6));
		assert resultOf(foreign, 0, typedTransferEntry) ==
			ProgramError.accountOwnedByWrongProgram().code;
		const short: uint8[] = [1, 2, 3];
		const broken = typedAccounts(TOKEN_2022_PROGRAM_ID, short);
		assert resultOf(broken, 0, typedTransferEntry) ==
			ProgramError.accountDidNotDeserialize().code;
	}

	test "expectAssociated refuses a token account that is not the owner's associated account" {
		assert resultOf(goodMint(), 1, typedTransferEntry) ==
			ProgramError.accountNotAssociatedTokenAccount().code;
	}

	export struct DecoratedTokens {
		owner: Signer;
		mint: External<Mint>;
		@associated(mint, owner) own: ExternalMutable<TokenAccount>;
		@tokenMint(mint) @tokenAuthority(owner) plain: ExternalMutable<TokenAccount>;
	}

	function decoratedStep(): Result<uint64, ProgramError> {
		const x = try accounts<DecoratedTokens>();
		return Result.ok((try x.own.read()).amount + (try x.plain.read()).amount);
	}

	function decoratedEntry(): void {
		const result = decoratedStep();
		if (!result.ok) { failWith(result.error); }
	}

	function ataOf(wallet: uint64, mint: uint64, program: Pubkey): Pubkey {
		const found = associatedTokenAddress(keyOf(wallet), keyOf(mint), program);
		return found.ok ? found.value.key : Pubkey.zero();
	}

	function decorated(program: Pubkey, ownerWord: uint64, ownAt: Pubkey, plainMint: uint64, plainOwner: uint64): HostAccount[] {
		let owner = holderOf(3, Pubkey.zero(), []);
		owner.signer = true;
		let own = holderOf(5, program, tokenAccountData(1, ownerWord, 900, 1));
		own.key = ownAt;
		return [
			owner,
			holderOf(1, program, mintData(7, 500, 6)),
			own,
			holderOf(6, program, tokenAccountData(plainMint, plainOwner, 0, 1)),
		];
	}

	test "@associated checks the token account's authority, then that it sits at the associated address of the authority and the mint" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const good = decorated(program, 3, ataOf(3, 1, program), 1, 3);
			assert resultOf(good, 0, decoratedEntry) == 0;
			const otherOwner = decorated(program, 4, ataOf(3, 1, program), 1, 3);
			assert resultOf(otherOwner, 0, decoratedEntry) ==
				ProgramError.constraintTokenOwner().code;
			const elsewhere = decorated(program, 3, keyOf(66), 1, 3);
			assert resultOf(elsewhere, 0, decoratedEntry) ==
				ProgramError.constraintAssociated().code;
			const otherProgram = program == TOKEN_PROGRAM_ID
				? TOKEN_2022_PROGRAM_ID
				: TOKEN_PROGRAM_ID;
			const derivedByAnother = decorated(program, 3, ataOf(3, 1, otherProgram), 1, 3);
			assert resultOf(derivedByAnother, 0, decoratedEntry) ==
				ProgramError.constraintAssociated().code;
		}
	}

	test "@tokenAuthority and @tokenMint check the fields of the token account, the authority first" {
		const program = TOKEN_2022_PROGRAM_ID;
		const own = ataOf(3, 1, program);
		assert resultOf(decorated(program, 3, own, 1, 3), 0, decoratedEntry) == 0;
		assert resultOf(decorated(program, 3, own, 2, 3), 0, decoratedEntry) ==
			ProgramError.constraintTokenMint().code;
		assert resultOf(decorated(program, 3, own, 1, 4), 0, decoratedEntry) ==
			ProgramError.constraintTokenOwner().code;
		assert resultOf(decorated(program, 3, own, 2, 4), 0, decoratedEntry) ==
			ProgramError.constraintTokenOwner().code;
	}

	function agreeStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const found = try account(0);
		if (op == 0) {
			const lean = Mint.verify(0);
			const full = found.readMint();
			if (lean.ok != full.ok) { return Result.err(ProgramError.custom(8)); }
			if (!lean.ok) { return Result.err(ProgramError.custom(7)); }
			return Result.ok(0);
		}
		const lean = TokenAccount.verify(0);
		const full = found.readTokenAccount();
		if (lean.ok != full.ok) { return Result.err(ProgramError.custom(8)); }
		if (!lean.ok) { return Result.err(ProgramError.custom(7)); }
		return Result.ok(0);
	}

	function agreeEntry(): void {
		const result = agreeStep();
		if (!result.ok) { failWith(result.error); }
	}

	function resized(bytes: uint8[], length: int32, at: int32, value: uint8): uint8[] {
		while (bytes.length < length) { bytes.push(0); }
		while (bytes.length > length) { bytes.pop(); }
		if (at < bytes.length) { bytes[at] = value; }
		return bytes;
	}

	test "verifying a mint or a token account accepts exactly what decoding it accepts" {
		let accepted = 0;
		let refused = 0;
		for (const owner of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID, Pubkey.zero()]) {
			for (const length of [0, 44, 81, 82, 83, 164, 165, 166, 200, 355]) {
				for (const tag of [0 as uint8, 1 as uint8, 2 as uint8, 3 as uint8]) {
					const mintBytes = resized(mintData(7, 500, 6), length, 165, tag);
					const initialized = resized(mintBytes, length, 45, 1 as uint8);
					const uninitialized = resized(mintData(7, 500, 6), length, 45, 0 as uint8);
					for (const data of [initialized, uninitialized]) {
						const code = resultOf([holderOf(1, owner, data)], 0, agreeEntry);
						assert code == 0 || code == 7;
						if (code == 0) { accepted = accepted + 1; } else { refused = refused + 1; }
					}
					for (const state of [0 as uint8, 1 as uint8, 2 as uint8, 3 as uint8]) {
						const bytes = resized(tokenAccountData(1, 3, 900, state), length, 165, tag);
						const kept = resized(bytes, length, 108, state);
						const code = resultOf([holderOf(1, owner, kept)], 1, agreeEntry);
						assert code == 0 || code == 7;
						if (code == 0) { accepted = accepted + 1; } else { refused = refused + 1; }
					}
				}
			}
		}
		assert accepted > 20 && refused > 100;
	}

	function wrongProgramStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const mint = try account(0);
		const target = try account(1);
		const authority = try account(2);
		const payer = try account(3);
		const system = try account(4);
		const wrong = keyOf(3);
		if (op == 0) { return transferChecked(wrong, payer, mint, target, authority, 250, 6); }
		if (op == 1) { return closeAccount(wrong, target, payer, authority); }
		if (op == 2) { return initializeMint2(wrong, mint, 6, authority.key(), null); }
		if (op == 3) { return createAssociatedToken(payer, target, authority, mint, system, system); }
		return createAssociatedTokenIdempotent(payer, target, authority, mint, system, system);
	}

	function wrongProgramEntry(): void {
		const result = wrongProgramStep();
		if (!result.ok) { failWith(result.error); }
	}

	test "every token wrapper refuses a program id that is not a token program before it sends anything" {
		for (const op of [0, 1, 2, 3, 4]) {
			assert resultOf(cpiAccounts(), op as uint8, wrongProgramEntry) ==
				ProgramError.incorrectProgramId().code;
			assert invocations().length == 0;
		}
	}

	test "createMintPda refuses a mint address that already holds an initialized mint and leaves it intact" {
		const accounts = mintPdaAccounts(mintKey());
		accounts[1].owner = TOKEN_PROGRAM_ID;
		accounts[1].data = mintData(7, 500, 6);
		accounts[1].lamports = 10000000;
		assert resultOf(accounts, 0, mintPdaEntry) == ProgramError.custom(0).code;
		assert accounts[1].data.length == 165 - 83 && accounts[1].lamports == 10000000;
		assert accounts[0].lamports == 10000000;
	}

	test "createMintPda on a pre-funded mint address keeps the lamports and tops up only the shortfall" {
		const accounts = mintPdaAccounts(mintKey());
		accounts[1].lamports = 5;
		assert resultOf(accounts, 0, mintPdaEntry) == 0;
		assert accounts[1].owner.equals(TOKEN_PROGRAM_ID) && accounts[1].data.length == 82;
		assert accounts[1].lamports == 2 * (82 + 128) * 3480;
		assert accounts[0].lamports == 10000000 - (accounts[1].lamports - 5);
	}
}

when (testBuild) {
	import { signedPda } from "./macro";
	import { ProgramAddress } from "./pda";

	const TOKEN_ACCOUNT_RENT: uint64 = 2 * (165 + 128) * 3480;

	function u64At(bytes: uint8[], offset: int32): uint64 {
		let value: uint64 = 0;
		for (let index = offset + 7; index >= offset; index--) {
			value = (value << 8) | (bytes[index] as uint64);
		}
		return value;
	}

	function keyAt(bytes: uint8[], offset: int32): Pubkey {
		let key = Pubkey.zero();
		for (let index = 0; index < 32; index++) { key.bytes[index] = bytes[offset + index]; }
		return key;
	}

	function newTokenStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const owner = keyOf(8);
		if (op == 4) {
			return initializeAccount3(TOKEN_PROGRAM_ID, try account(1), try account(2), owner);
		}
		const payer = try writableSigner(0);
		const mint = try external<Mint>(2);
		if (op == 0) {
			return createTokenAccount(payer, try writableSigner(1), mint, owner);
		}
		const fresh = try writable(1);
		if (op == 1) { return createTokenAccount(payer, fresh, mint, owner); }
		if (op == 2) {
			return signedPda(
				createTokenAccount(payer, fresh, mint, owner),
				fresh.asAccount(),
				["vault", mint],
			);
		}
		const bump = try instructionData().readU8(1);
		return signed(createTokenAccount(payer, fresh, mint, owner), ["vault", mint, [bump]]);
	}

	function newTokenEntry(): void {
		const result = newTokenStep();
		if (!result.ok) { failWith(result.error); }
	}

	function newTokenAccounts(program: Pubkey, mint: uint8[]): HostAccount[] {
		const payer: HostAccount = {
			...holderOf(4, Pubkey.zero(), []),
			lamports: 10000000,
			signer: true,
		};
		const fresh: HostAccount = { ...holderOf(2, Pubkey.zero(), []), lamports: 0, signer: true };
		return [payer, fresh, holderOf(1, program, mint)];
	}

	function vaultAddress(): ProgramAddress {
		const mint = keyOf(1);
		const found = findProgramAddressOf(keyOf(9), ["vault", mint]);
		return found.ok ? found.value : { key: Pubkey.zero(), bump: 0 };
	}

	function keyBytes(key: Pubkey): uint8[] {
		const bytes: uint8[] = [];
		pushKey(bytes, key);
		return bytes;
	}

	function vaultAccounts(program: Pubkey): HostAccount[] {
		const accounts = newTokenAccounts(program, mintData(7, 500, 6));
		accounts[1].key = vaultAddress().key;
		accounts[1].signer = false;
		return accounts;
	}

	function isFreshTokenAccount(holder: HostAccount, program: Pubkey, length: int32): boolean {
		return holder.owner.equals(program) && holder.data.length == length &&
			keyAt(holder.data, 0).equals(keyOf(1)) && keyAt(holder.data, 32).equals(keyOf(8)) &&
			u64At(holder.data, 64) == 0 && holder.data[108] == 1 && u64At(holder.data, 72) == 0 &&
			holder.data[129] == 0 && holder.data[109] == 0;
	}

	test "createTokenAccount creates the account for the mint's token program and initializes it for the mint and the owner" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = newTokenAccounts(program, mintData(7, 500, 6));
			assert resultOf(accounts, 0, newTokenEntry) == 0;
			assert isFreshTokenAccount(accounts[1], program, 165);
			assert accounts[1].lamports == TOKEN_ACCOUNT_RENT;
			assert accounts[0].lamports == 10000000 - TOKEN_ACCOUNT_RENT;
			const calls = invocations();
			assert calls.length == 2 && calls[0].program.isZero() && calls[0].data[0] == 13;
			assert calls[0].data[12] == 165 && keyAt(calls[0].data, 20).equals(program);
			const initialized = calls[1];
			assert initialized.program.equals(program) && initialized.accounts.length == 2;
			assert initialized.accounts[0].key.equals(keyOf(2)) && initialized.accounts[0].writable;
			assert !initialized.accounts[0].signer;
			assert initialized.accounts[1].key.equals(keyOf(1));
			assert !initialized.accounts[1].writable && !initialized.accounts[1].signer;
			assert initialized.data.length == 33 && initialized.data[0] == 18;
			assert keyAt(initialized.data, 1).equals(keyOf(8));
		}
	}

	test "createTokenAccount at an address that did not sign and has no seeds is refused before any CPI" {
		const accounts = newTokenAccounts(TOKEN_PROGRAM_ID, mintData(7, 500, 6));
		accounts[1].signer = false;
		assert resultOf(accounts, 0, newTokenEntry) == ProgramError.accountNotSigner().code;
		assert resultOf(accounts, 1, newTokenEntry) == ProgramError.missingRequiredSignature().code;
		assert invocations().length == 0 && accounts[1].data.length == 0;
	}

	test "createTokenAccount under signedPda creates the account at the canonical address of the seeds" {
		const accounts = vaultAccounts(TOKEN_PROGRAM_ID);
		assert resultOf(accounts, 2, newTokenEntry) == 0;
		assert isFreshTokenAccount(accounts[1], TOKEN_PROGRAM_ID, 165);
		const created = invocations()[0];
		assert created.signers == 1;
		const seeds: uint8[][] = [textBytes("vault"), keyBytes(keyOf(1)), [vaultAddress().bump]];
		assert signerIs(created, 0, seeds);
		assert invocations()[1].signers == 0;
		const elsewhere = vaultAccounts(TOKEN_PROGRAM_ID);
		elsewhere[1].key = keyOf(2);
		assert resultOf(elsewhere, 2, newTokenEntry) == ProgramError.constraintSeeds().code;
		assert invocations().length == 0;
	}

	test "createTokenAccount under signed creates the account only at the address its seeds sign for" {
		const accounts = vaultAccounts(TOKEN_2022_PROGRAM_ID);
		const data: uint8[] = [3, vaultAddress().bump];
		assert run(keyOf(9), accounts, data, newTokenEntry).result == 0;
		assert isFreshTokenAccount(accounts[1], TOKEN_2022_PROGRAM_ID, 165);
		const elsewhere = vaultAccounts(TOKEN_2022_PROGRAM_ID);
		elsewhere[1].key = keyOf(2);
		const refused = run(keyOf(9), elsewhere, data, newTokenEntry);
		assert refused.result == ProgramError.missingRequiredSignature().code;
		assert refused.fault.indexOf("signer privilege escalated") >= 0;
		assert elsewhere[1].data.length == 0 && elsewhere[1].owner.isZero();
	}

	test "createTokenAccount refuses an address that already holds a token account and leaves it intact" {
		const accounts = newTokenAccounts(TOKEN_PROGRAM_ID, mintData(7, 500, 6));
		accounts[1].owner = TOKEN_PROGRAM_ID;
		accounts[1].data = tokenAccountData(1, 3, 77, 1);
		accounts[1].lamports = TOKEN_ACCOUNT_RENT;
		assert resultOf(accounts, 0, newTokenEntry) == ProgramError.custom(0).code;
		assert u64At(accounts[1].data, 64) == 77 && keyAt(accounts[1].data, 32).equals(keyOf(3));
		assert resultOf(accounts, 4, newTokenEntry) == ProgramError.custom(6).code;
		assert u64At(accounts[1].data, 64) == 77 && keyAt(accounts[1].data, 32).equals(keyOf(3));
	}

	function mintExtensionLength(kind: int32): int32 {
		return match (kind) {
			1 => 108,
			3 => 32,
			14 => 64,
			26 => 33,
			6 => 1,
			_ => 0,
		};
	}

	function extendedMint(kinds: int32[]): uint8[] {
		const bytes = mintData(7, 500, 6);
		pushZeros(bytes, 83);
		bytes.push(1);
		for (const kind of kinds) {
			pushU16(bytes, kind as uint64);
			pushU16(bytes, mintExtensionLength(kind) as uint64);
			pushZeros(bytes, mintExtensionLength(kind));
		}
		return bytes;
	}

	test "createTokenAccount sizes a Token-2022 account for the account extensions its mint requires" {
		const cases: int32[][] = [[1], [9], [14], [26], [3], [1, 9, 14, 26]];
		const sizes: int32[] = [178, 174, 171, 170, 165, 195];
		for (let index = 0; index < cases.length; index++) {
			const accounts = newTokenAccounts(TOKEN_2022_PROGRAM_ID, extendedMint(cases[index]));
			assert resultOf(accounts, 0, newTokenEntry) == 0;
			assert accounts[1].data.length == sizes[index];
			assert invocations()[0].data[12] == sizes[index];
			assert accounts[1].lamports == 2 * ((sizes[index] as uint64) + 128) * 3480;
			assert sizes[index] == 165 || accounts[1].data[165] == 2;
		}
	}

	test "a Token-2022 account created for a mint with a default account state starts in that state" {
		const frozen = extendedMint([6]);
		frozen[170] = 2;
		const accounts = newTokenAccounts(TOKEN_2022_PROGRAM_ID, frozen);
		assert resultOf(accounts, 0, newTokenEntry) == 0;
		assert accounts[1].data.length == 165 && accounts[1].data[108] == 2;
	}

	test "a token account created for the native mint holds the lamports above its rent reserve" {
		const native = Pubkey.parse("So11111111111111111111111111111111111111112");
		assert native.ok;
		if (native.ok) {
			const accounts = newTokenAccounts(TOKEN_PROGRAM_ID, mintData(7, 0, 9));
			accounts[2].key = native.value;
			accounts[1].lamports = TOKEN_ACCOUNT_RENT + 5000;
			assert resultOf(accounts, 0, newTokenEntry) == 0;
			assert accounts[0].lamports == 10000000;
			assert accounts[1].lamports == TOKEN_ACCOUNT_RENT + 5000;
			assert u64At(accounts[1].data, 64) == 5000 && accounts[1].data[109] == 1;
			assert u64At(accounts[1].data, 113) == TOKEN_ACCOUNT_RENT;
		}
	}

	function blankTokenAccounts(mint: uint8[]): HostAccount[] {
		const accounts = newTokenAccounts(TOKEN_PROGRAM_ID, mint);
		accounts[1].owner = TOKEN_PROGRAM_ID;
		accounts[1].data = tokenAccountData(0, 0, 0, 0);
		accounts[1].lamports = TOKEN_ACCOUNT_RENT;
		return accounts;
	}

	test "initializeAccount3 is refused by the token program for a mint that is not initialized, a mint of another program and an account below rent" {
		assert resultOf(blankTokenAccounts(mintData(7, 500, 6)), 4, newTokenEntry) == 0;
		const blank = mintData(7, 500, 6);
		blank[45] = 0;
		assert resultOf(blankTokenAccounts(blank), 4, newTokenEntry) == ProgramError.custom(2).code;
		const foreign = blankTokenAccounts(mintData(7, 500, 6));
		foreign[2].owner = TOKEN_2022_PROGRAM_ID;
		assert resultOf(foreign, 4, newTokenEntry) == ProgramError.incorrectProgramId().code;
		const poor = blankTokenAccounts(mintData(7, 500, 6));
		poor[1].lamports = TOKEN_ACCOUNT_RENT - 1;
		assert resultOf(poor, 4, newTokenEntry) == ProgramError.custom(0).code;
		assert poor[1].data[108] == 0;
		const short = blankTokenAccounts(mintData(7, 500, 6));
		short[1].data.pop();
		assert resultOf(short, 4, newTokenEntry) == ProgramError.invalidAccountData().code;
	}

	test "initializeAccount3 on an account the token program does not own is refused as the runtime refuses the write" {
		const foreign = blankTokenAccounts(mintData(7, 500, 6));
		foreign[1].owner = keyOf(9);
		const input: uint8[] = [4];
		const refused = run(keyOf(9), foreign, input, newTokenEntry);
		assert refused.result == ProgramError.incorrectProgramId().code;
		assert refused.fault.indexOf("ExternalAccountDataModified") >= 0;
		assert foreign[1].data[108] == 0;
	}
}

when (testBuild) {
	import { signer } from "./typed";
	import { programAddressOf } from "./macro";
	import { HostRun } from "./host";

	function burnStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const amount = try instructionData().readU64(1);
		const authority = try account(2);
		if (op == 3) {
			const program = (try account(1)).owner();
			return burnChecked(program, try account(0), try account(1), authority, amount, 5);
		}
		const from = try externalMutable<TokenAccount>(0);
		const mint = try externalMutable<Mint>(1);
		if (op == 0) { return burnTokens(from, mint, try signer(2), amount); }
		if (op == 1) { return burnTokens(from, mint, authority, amount); }
		return signed(burnTokens(from, mint, authority, amount), ["auth", [5]]);
	}

	function burnEntry(): void {
		const result = burnStep();
		if (!result.ok) { failWith(result.error); }
	}

	function burnAccounts(program: Pubkey): HostAccount[] {
		return [
			holderOf(4, program, tokenAccountData(1, 3, 900, 1)),
			holderOf(1, program, mintData(7, 5000, 6)),
			{ ...holderOf(3, Pubkey.zero(), []), signer: true, writable: false },
		];
	}

	function burnRun(accounts: HostAccount[], op: uint8, amount: uint64): HostRun {
		const data: uint8[] = [op];
		pushU64(data, amount);
		return run(keyOf(9), accounts, data, burnEntry);
	}

	function setKeyAt(bytes: uint8[], offset: int32, key: Pubkey): void {
		for (let index = 0; index < 32; index++) { bytes[offset + index] = key.bytes[index]; }
	}

	function withDelegate(bytes: uint8[], delegate: Pubkey, allowance: uint64): uint8[] {
		bytes[72] = 1;
		setKeyAt(bytes, 76, delegate);
		for (let index = 0; index < 8; index++) {
			bytes[121 + index] = ((allowance >> ((index * 8) as uint64)) & 255) as uint8;
		}
		return bytes;
	}

	function authorityPda(): Pubkey {
		const found = programAddressOf(keyOf(9), ["auth", [5]]);
		return found.ok ? found.value : Pubkey.zero();
	}

	test "burnTokens takes the amount from the account and the supply, with the mint's decimals and token program" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = burnAccounts(program);
			assert burnRun(accounts, 0, 250).result == 0;
			assert u64At(accounts[0].data, 64) == 650 && u64At(accounts[1].data, 36) == 4750;
			const sent = invocations()[0];
			assert sent.program.equals(program) && sent.accounts.length == 3 && sent.signers == 0;
			assert sent.accounts[0].key.equals(keyOf(4)) && sent.accounts[0].writable;
			assert sent.accounts[1].key.equals(keyOf(1)) && sent.accounts[1].writable;
			assert !sent.accounts[0].signer && !sent.accounts[1].signer;
			assert sent.accounts[2].key.equals(keyOf(3)) && sent.accounts[2].signer;
			assert !sent.accounts[2].writable;
			const burnBytes: uint8[] = [15, 250, 0, 0, 0, 0, 0, 0, 0, 6];
			assert sameBytes(sent.data, burnBytes);
		}
	}

	test "burnTokens is refused for more than the account holds, another authority, another mint and a frozen account" {
		const beyond = burnAccounts(TOKEN_PROGRAM_ID);
		assert burnRun(beyond, 0, 901).result == ProgramError.custom(1).code;
		const stranger = burnAccounts(TOKEN_PROGRAM_ID);
		stranger[2].key = keyOf(5);
		assert burnRun(stranger, 0, 250).result == ProgramError.custom(4).code;
		const otherMint = burnAccounts(TOKEN_PROGRAM_ID);
		otherMint[1].key = keyOf(6);
		assert burnRun(otherMint, 0, 250).result == ProgramError.custom(3).code;
		const frozen = burnAccounts(TOKEN_PROGRAM_ID);
		frozen[0].data[108] = 2;
		assert burnRun(frozen, 0, 250).result == ProgramError.custom(17).code;
		for (const refused of [beyond, stranger, otherMint, frozen]) {
			assert u64At(refused[0].data, 64) == 900 && u64At(refused[1].data, 36) == 5000;
		}
	}

	test "burnTokens by an authority that did not sign is refused before any CPI" {
		const accounts = burnAccounts(TOKEN_PROGRAM_ID);
		accounts[2].signer = false;
		assert burnRun(accounts, 0, 250).result == ProgramError.accountNotSigner().code;
		assert burnRun(accounts, 1, 250).result == ProgramError.missingRequiredSignature().code;
		assert invocations().length == 0 && u64At(accounts[0].data, 64) == 900;
	}

	test "burnTokens under signed burns for a PDA authority and only for the PDA its seeds derive" {
		const accounts = burnAccounts(TOKEN_2022_PROGRAM_ID);
		setKeyAt(accounts[0].data, 32, authorityPda());
		accounts[2].key = authorityPda();
		accounts[2].signer = false;
		assert burnRun(accounts, 2, 250).result == 0;
		assert u64At(accounts[0].data, 64) == 650 && u64At(accounts[1].data, 36) == 4750;
		assert signerIs(invocations()[0], 0, authSigner());
		const stranger = burnAccounts(TOKEN_2022_PROGRAM_ID);
		stranger[2].signer = false;
		const refused = burnRun(stranger, 2, 250);
		assert refused.result == ProgramError.missingRequiredSignature().code;
		assert refused.fault.indexOf("signer privilege escalated") >= 0;
		assert u64At(stranger[0].data, 64) == 900;
	}

	test "a delegate burns within its allowance, which the burn spends" {
		const accounts = burnAccounts(TOKEN_PROGRAM_ID);
		accounts[0].data = withDelegate(tokenAccountData(1, 8, 900, 1), keyOf(3), 300);
		assert burnRun(accounts, 0, 301).result == ProgramError.custom(1).code;
		assert u64At(accounts[0].data, 121) == 300 && u64At(accounts[0].data, 64) == 900;
		assert burnRun(accounts, 0, 100).result == 0;
		assert u64At(accounts[0].data, 64) == 800 && u64At(accounts[0].data, 121) == 200;
		assert accounts[0].data[72] == 1;
		assert burnRun(accounts, 0, 200).result == 0;
		assert u64At(accounts[0].data, 64) == 600 && u64At(accounts[0].data, 121) == 0;
		assert accounts[0].data[72] == 0;
		assert burnRun(accounts, 0, 1).result == ProgramError.custom(4).code;
	}

	test "burnChecked is refused for decimals that are not the mint's, a native account and an account of another token program" {
		const accounts = burnAccounts(TOKEN_PROGRAM_ID);
		assert burnRun(accounts, 3, 250).result == ProgramError.custom(18).code;
		const native = burnAccounts(TOKEN_PROGRAM_ID);
		native[0].data[109] = 1;
		assert burnRun(native, 0, 250).result == ProgramError.custom(10).code;
		const mixed = burnAccounts(TOKEN_PROGRAM_ID);
		mixed[0].owner = TOKEN_2022_PROGRAM_ID;
		const refused = burnRun(mixed, 0, 250);
		assert refused.result == ProgramError.incorrectProgramId().code;
		assert refused.fault.indexOf("ExternalAccountDataModified") >= 0;
		assert u64At(mixed[0].data, 64) == 900 && u64At(mixed[1].data, 36) == 5000;
	}

	function authorityStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const kind = (try instructionData().readU8(1)) as AuthorityType;
		const next: Pubkey | null = (try instructionData().readU8(2)) == 1 ? keyOf(6) : null;
		const authority = try account(1);
		if (op == 5) {
			const target = try account(0);
			return setAuthority(target.owner(), target, authority, kind, next);
		}
		if (op >= 3) {
			const held = try externalMutable<TokenAccount>(0);
			if (op == 3) { return setAuthorityOf(held, kind, try signer(1), next); }
			return signed(setAuthorityOf(held, kind, authority, next), ["auth", [5]]);
		}
		const mint = try externalMutable<Mint>(0);
		if (op == 0) { return setAuthorityOf(mint, kind, try signer(1), next); }
		if (op == 1) { return setAuthorityOf(mint, kind, authority, next); }
		return signed(setAuthorityOf(mint, kind, authority, next), ["auth", [5]]);
	}

	function authorityEntry(): void {
		const result = authorityStep();
		if (!result.ok) { failWith(result.error); }
	}

	function signingAs(word: uint64): HostAccount {
		return { ...holderOf(word, Pubkey.zero(), []), signer: true, writable: false };
	}

	function mintAuthorityAccounts(program: Pubkey): HostAccount[] {
		return [holderOf(1, program, mintData(7, 5000, 6)), signingAs(7)];
	}

	function ownerAuthorityAccounts(program: Pubkey): HostAccount[] {
		return [holderOf(4, program, tokenAccountData(1, 3, 900, 1)), signingAs(3)];
	}

	function authorityRun(
		accounts: HostAccount[],
		op: uint8,
		kind: AuthorityType,
		next: boolean,
	): HostRun {
		const data: uint8[] = [op, kind as uint8, next ? 1 : 0];
		return run(keyOf(9), accounts, data, authorityEntry);
	}

	test "setAuthorityOf hands a mint's mint authority to another key through the mint's token program" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = mintAuthorityAccounts(program);
			assert authorityRun(accounts, 0, AuthorityType.MintTokens, true).result == 0;
			assert accounts[0].data[0] == 1 && keyAt(accounts[0].data, 4).equals(keyOf(6));
			const sent = invocations()[0];
			assert sent.program.equals(program) && sent.accounts.length == 2 && sent.signers == 0;
			assert sent.accounts[0].key.equals(keyOf(1)) && sent.accounts[0].writable;
			assert !sent.accounts[0].signer;
			assert sent.accounts[1].key.equals(keyOf(7)) && sent.accounts[1].signer;
			assert !sent.accounts[1].writable;
			const expected: uint8[] = [6, 0, 1];
			pushKey(expected, keyOf(6));
			assert sameBytes(sent.data, expected);
			const former = authorityRun(accounts, 0, AuthorityType.MintTokens, true);
			assert former.result == ProgramError.custom(4).code;
		}
	}

	test "setAuthorityOf with no next authority fixes the supply, and a fixed supply stays fixed" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = mintAuthorityAccounts(program);
			assert authorityRun(accounts, 0, AuthorityType.MintTokens, false).result == 0;
			assert accounts[0].data[0] == 0;
			const left = program.equals(TOKEN_PROGRAM_ID) ? keyOf(7) : Pubkey.zero();
			assert keyAt(accounts[0].data, 4).equals(left);
			const cleared: uint8[] = [6, 0, 0];
			assert sameBytes(invocations()[0].data, cleared);
			const again = authorityRun(accounts, 0, AuthorityType.MintTokens, true);
			assert again.result == ProgramError.custom(5).code && accounts[0].data[0] == 0;
		}
	}

	test "setAuthorityOf changes a mint's freeze authority only where the mint has one" {
		const accounts = mintAuthorityAccounts(TOKEN_PROGRAM_ID);
		const never = authorityRun(accounts, 0, AuthorityType.FreezeAccount, true);
		assert never.result == ProgramError.custom(16).code && accounts[0].data[46] == 0;
		accounts[0].data[46] = 1;
		setKeyAt(accounts[0].data, 50, keyOf(7));
		assert authorityRun(accounts, 0, AuthorityType.FreezeAccount, true).result == 0;
		assert accounts[0].data[46] == 1 && keyAt(accounts[0].data, 50).equals(keyOf(6));
		assert keyAt(accounts[0].data, 4).equals(keyOf(7));
		accounts[1].key = keyOf(6);
		assert authorityRun(accounts, 0, AuthorityType.FreezeAccount, false).result == 0;
		assert accounts[0].data[46] == 0;
	}

	test "setAuthorityOf hands a token account to another owner and drops its delegate" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = ownerAuthorityAccounts(program);
			accounts[0].data = withDelegate(accounts[0].data, keyOf(8), 300);
			const kept = authorityRun(accounts, 3, AuthorityType.AccountOwner, false);
			assert kept.result == ProgramError.custom(12).code;
			assert keyAt(accounts[0].data, 32).equals(keyOf(3)) && accounts[0].data[72] == 1;
			assert authorityRun(accounts, 3, AuthorityType.AccountOwner, true).result == 0;
			assert keyAt(accounts[0].data, 32).equals(keyOf(6));
			assert u64At(accounts[0].data, 64) == 900;
			assert accounts[0].data[72] == 0 && u64At(accounts[0].data, 121) == 0;
			assert accounts[0].data[129] == 1 && keyAt(accounts[0].data, 133).equals(keyOf(3));
			assert invocations()[0].program.equals(program);
			const former = authorityRun(accounts, 3, AuthorityType.AccountOwner, true);
			assert former.result == ProgramError.custom(4).code;
		}
	}

	test "a close authority is changed by itself when the account has one and by the owner when it has none" {
		const accounts = ownerAuthorityAccounts(TOKEN_PROGRAM_ID);
		setKeyAt(accounts[0].data, 133, keyOf(8));
		const byOwner = authorityRun(accounts, 3, AuthorityType.CloseAccount, true);
		assert byOwner.result == ProgramError.custom(4).code;
		accounts[1].key = keyOf(8);
		assert authorityRun(accounts, 3, AuthorityType.CloseAccount, false).result == 0;
		assert accounts[0].data[129] == 0 && keyAt(accounts[0].data, 32).equals(keyOf(3));
		assert authorityRun(accounts, 3, AuthorityType.CloseAccount, true).result
			== ProgramError.custom(4).code;
		accounts[1].key = keyOf(3);
		assert authorityRun(accounts, 3, AuthorityType.CloseAccount, true).result == 0;
		assert accounts[0].data[129] == 1 && keyAt(accounts[0].data, 133).equals(keyOf(6));
	}

	test "setAuthorityOf is refused for a frozen account and for an authority the target does not have" {
		const frozen = ownerAuthorityAccounts(TOKEN_PROGRAM_ID);
		frozen[0].data[108] = 2;
		const cold = authorityRun(frozen, 3, AuthorityType.AccountOwner, true);
		assert cold.result == ProgramError.custom(17).code;
		assert keyAt(frozen[0].data, 32).equals(keyOf(3));
		const held = ownerAuthorityAccounts(TOKEN_PROGRAM_ID);
		for (const kind of [AuthorityType.MintTokens, AuthorityType.FreezeAccount]) {
			assert authorityRun(held, 3, kind, true).result == ProgramError.custom(15).code;
		}
		const minted = mintAuthorityAccounts(TOKEN_PROGRAM_ID);
		for (const kind of [AuthorityType.AccountOwner, AuthorityType.CloseAccount]) {
			assert authorityRun(minted, 0, kind, true).result == ProgramError.custom(15).code;
		}
		assert keyAt(minted[0].data, 4).equals(keyOf(7));
	}

	test "setAuthorityOf by an authority that did not sign is refused before any CPI" {
		const accounts = mintAuthorityAccounts(TOKEN_PROGRAM_ID);
		accounts[1].signer = false;
		const proof = authorityRun(accounts, 0, AuthorityType.MintTokens, true);
		assert proof.result == ProgramError.accountNotSigner().code;
		const bare = authorityRun(accounts, 1, AuthorityType.MintTokens, true);
		assert bare.result == ProgramError.missingRequiredSignature().code;
		assert invocations().length == 0 && keyAt(accounts[0].data, 4).equals(keyOf(7));
	}

	test "setAuthorityOf under signed changes what a PDA of the program holds, mint or token account" {
		const minted = mintAuthorityAccounts(TOKEN_2022_PROGRAM_ID);
		setKeyAt(minted[0].data, 4, authorityPda());
		minted[1].key = authorityPda();
		minted[1].signer = false;
		assert authorityRun(minted, 2, AuthorityType.MintTokens, true).result == 0;
		assert keyAt(minted[0].data, 4).equals(keyOf(6));
		assert signerIs(invocations()[0], 0, authSigner());
		const held = ownerAuthorityAccounts(TOKEN_PROGRAM_ID);
		setKeyAt(held[0].data, 32, authorityPda());
		setKeyAt(held[0].data, 133, authorityPda());
		held[1].key = authorityPda();
		held[1].signer = false;
		assert authorityRun(held, 4, AuthorityType.CloseAccount, true).result == 0;
		assert keyAt(held[0].data, 133).equals(keyOf(6));
		const stranger = mintAuthorityAccounts(TOKEN_PROGRAM_ID);
		stranger[1].signer = false;
		const refused = authorityRun(stranger, 2, AuthorityType.MintTokens, true);
		assert refused.result == ProgramError.missingRequiredSignature().code;
		assert refused.fault.indexOf("signer privilege escalated") >= 0;
		assert keyAt(stranger[0].data, 4).equals(keyOf(7));
	}

	test "setAuthority on an account that is neither a mint nor a token account, or not initialized, is refused" {
		const neither: uint64[] = [
			ProgramError.invalidArgument().code,
			ProgramError.invalidAccountData().code,
		];
		const empty: uint64[] = [
			ProgramError.uninitializedAccount().code,
			ProgramError.invalidAccountData().code,
		];
		const programs: Pubkey[] = [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID];
		for (let index = 0; index < 2; index++) {
			const other = mintAuthorityAccounts(programs[index]);
			other[0].data.push(0);
			assert authorityRun(other, 5, AuthorityType.MintTokens, true).result == neither[index];
			const unminted = mintAuthorityAccounts(programs[index]);
			unminted[0].data[45] = 0;
			assert authorityRun(unminted, 5, AuthorityType.MintTokens, true).result == empty[index];
			const unheld = ownerAuthorityAccounts(programs[index]);
			unheld[0].data[108] = 0;
			assert authorityRun(unheld, 5, AuthorityType.AccountOwner, true).result == empty[index];
		}
	}

	test "a Token-2022 account with an immutable owner keeps its owner and still takes a close authority" {
		const accounts = ownerAuthorityAccounts(TOKEN_2022_PROGRAM_ID);
		for (const byte of [2, 7, 0, 0, 0]) { accounts[0].data.push(byte as uint8); }
		const kept = authorityRun(accounts, 3, AuthorityType.AccountOwner, true);
		assert kept.result == ProgramError.custom(34).code;
		assert keyAt(accounts[0].data, 32).equals(keyOf(3));
		assert authorityRun(accounts, 3, AuthorityType.CloseAccount, true).result == 0;
		assert keyAt(accounts[0].data, 133).equals(keyOf(6));
	}

	function delegateStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const amount = try instructionData().readU64(1);
		const source = try externalMutable<TokenAccount>(0);
		const delegate = try account(2);
		const authority = try account(3);
		if (op == 3) { return revokeDelegate(source, try signer(3)); }
		if (op == 4) { return revokeDelegate(source, authority); }
		if (op == 5) { return signed(revokeDelegate(source, authority), ["auth", [5]]); }
		if (op == 6) {
			const minted = try account(1);
			return approveChecked(
				minted.owner(),
				try account(0),
				minted,
				delegate,
				authority,
				amount,
				5,
			);
		}
		const mint = try external<Mint>(1);
		if (op == 7) {
			const to = try externalMutable<TokenAccount>(4);
			return transferTokens(source, to, mint, delegate, amount);
		}
		if (op == 0) { return approveDelegate(source, mint, delegate, try signer(3), amount); }
		if (op == 1) { return approveDelegate(source, mint, delegate, authority, amount); }
		return signed(approveDelegate(source, mint, delegate, authority, amount), ["auth", [5]]);
	}

	function delegateEntry(): void {
		const result = delegateStep();
		if (!result.ok) { failWith(result.error); }
	}

	function delegateAccounts(program: Pubkey): HostAccount[] {
		return [
			holderOf(4, program, tokenAccountData(1, 3, 900, 1)),
			{ ...holderOf(1, program, mintData(7, 5000, 6)), writable: false },
			signingAs(8),
			signingAs(3),
			holderOf(5, program, tokenAccountData(1, 6, 0, 1)),
		];
	}

	function delegateRun(accounts: HostAccount[], op: uint8, amount: uint64): HostRun {
		const data: uint8[] = [op];
		pushU64(data, amount);
		return run(keyOf(9), accounts, data, delegateEntry);
	}

	function delegateOf(accounts: HostAccount[]): Pubkey | null {
		return accounts[0].data[72] == 1 ? keyAt(accounts[0].data, 76) : null;
	}

	test "approveDelegate names the delegate and its allowance, with the mint's decimals and token program" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = delegateAccounts(program);
			assert delegateRun(accounts, 0, 300).result == 0;
			assert delegateOf(accounts) == keyOf(8) && u64At(accounts[0].data, 121) == 300;
			assert u64At(accounts[0].data, 64) == 900;
			assert keyAt(accounts[0].data, 32).equals(keyOf(3));
			const sent = invocations()[0];
			assert sent.program.equals(program) && sent.accounts.length == 4 && sent.signers == 0;
			assert sent.accounts[0].key.equals(keyOf(4)) && sent.accounts[0].writable;
			assert sent.accounts[1].key.equals(keyOf(1)) && !sent.accounts[1].writable;
			assert sent.accounts[2].key.equals(keyOf(8)) && !sent.accounts[2].writable;
			assert !sent.accounts[0].signer && !sent.accounts[1].signer && !sent.accounts[2].signer;
			assert sent.accounts[3].key.equals(keyOf(3)) && sent.accounts[3].signer;
			assert !sent.accounts[3].writable;
			const approveBytes: uint8[] = [13, 44, 1, 0, 0, 0, 0, 0, 0, 6];
			assert sameBytes(sent.data, approveBytes);
		}
	}

	test "a later approveDelegate replaces the delegate and the allowance, which the balance does not bound" {
		const accounts = delegateAccounts(TOKEN_PROGRAM_ID);
		assert delegateRun(accounts, 0, 300).result == 0;
		accounts[2].key = keyOf(6);
		assert delegateRun(accounts, 0, 5000).result == 0;
		assert delegateOf(accounts) == keyOf(6) && u64At(accounts[0].data, 121) == 5000;
	}

	test "approveDelegate is refused for another authority, another mint, a frozen account and wrong decimals" {
		const stranger = delegateAccounts(TOKEN_PROGRAM_ID);
		stranger[3].key = keyOf(6);
		assert delegateRun(stranger, 0, 300).result == ProgramError.custom(4).code;
		const otherMint = delegateAccounts(TOKEN_PROGRAM_ID);
		otherMint[1].key = keyOf(6);
		assert delegateRun(otherMint, 0, 300).result == ProgramError.custom(3).code;
		const frozen = delegateAccounts(TOKEN_PROGRAM_ID);
		frozen[0].data[108] = 2;
		assert delegateRun(frozen, 0, 300).result == ProgramError.custom(17).code;
		const decimals = delegateAccounts(TOKEN_PROGRAM_ID);
		assert delegateRun(decimals, 6, 300).result == ProgramError.custom(18).code;
		for (const refused of [stranger, otherMint, frozen, decimals]) {
			assert delegateOf(refused) == null && u64At(refused[0].data, 121) == 0;
		}
	}

	test "approveDelegate and revokeDelegate by an authority that did not sign are refused before any CPI" {
		const accounts = delegateAccounts(TOKEN_PROGRAM_ID);
		accounts[3].signer = false;
		for (const op of [0, 3]) {
			const refused = delegateRun(accounts, op as uint8, 300);
			assert refused.result == ProgramError.accountNotSigner().code;
		}
		for (const op of [1, 4]) {
			const refused = delegateRun(accounts, op as uint8, 300);
			assert refused.result == ProgramError.missingRequiredSignature().code;
		}
		assert invocations().length == 0 && delegateOf(accounts) == null;
	}

	test "a delegate transfers within its allowance, which the transfer spends" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = delegateAccounts(program);
			assert delegateRun(accounts, 0, 300).result == 0;
			assert delegateRun(accounts, 7, 301).result == ProgramError.custom(1).code;
			assert u64At(accounts[0].data, 121) == 300 && u64At(accounts[4].data, 64) == 0;
			assert delegateRun(accounts, 7, 100).result == 0;
			assert u64At(accounts[0].data, 64) == 800 && u64At(accounts[4].data, 64) == 100;
			assert u64At(accounts[0].data, 121) == 200 && delegateOf(accounts) == keyOf(8);
			assert delegateRun(accounts, 7, 200).result == 0;
			assert u64At(accounts[4].data, 64) == 300 && u64At(accounts[0].data, 121) == 0;
			assert delegateOf(accounts) == null;
			assert delegateRun(accounts, 7, 1).result == ProgramError.custom(4).code;
		}
	}

	test "revokeDelegate removes the delegate and its allowance through the account's token program" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = delegateAccounts(program);
			assert delegateRun(accounts, 0, 300).result == 0 && delegateOf(accounts) == keyOf(8);
			assert delegateRun(accounts, 3, 0).result == 0;
			assert delegateOf(accounts) == null && u64At(accounts[0].data, 121) == 0;
			assert u64At(accounts[0].data, 64) == 900;
			const sent = invocations()[0];
			assert sent.program.equals(program) && sent.accounts.length == 2 && sent.signers == 0;
			assert sent.accounts[0].key.equals(keyOf(4)) && sent.accounts[0].writable;
			assert !sent.accounts[0].signer;
			assert sent.accounts[1].key.equals(keyOf(3)) && sent.accounts[1].signer;
			assert !sent.accounts[1].writable;
			const revokeBytes: uint8[] = [5];
			assert sameBytes(sent.data, revokeBytes);
			assert delegateRun(accounts, 7, 1).result == ProgramError.custom(4).code;
			assert delegateRun(accounts, 3, 0).result == 0;
		}
	}

	test "revokeDelegate is refused for a signer that is not the owner and for a frozen account" {
		const stranger = delegateAccounts(TOKEN_PROGRAM_ID);
		assert delegateRun(stranger, 0, 300).result == 0;
		stranger[3].key = keyOf(6);
		assert delegateRun(stranger, 3, 0).result == ProgramError.custom(4).code;
		const frozen = delegateAccounts(TOKEN_PROGRAM_ID);
		assert delegateRun(frozen, 0, 300).result == 0;
		frozen[0].data[108] = 2;
		assert delegateRun(frozen, 3, 0).result == ProgramError.custom(17).code;
		for (const refused of [stranger, frozen]) {
			assert delegateOf(refused) == keyOf(8) && u64At(refused[0].data, 121) == 300;
		}
	}

	test "the delegate itself revokes its own allowance" {
		for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
			const accounts = delegateAccounts(program);
			assert delegateRun(accounts, 0, 300).result == 0 && delegateOf(accounts) == keyOf(8);
			accounts[3].key = keyOf(8);
			assert delegateRun(accounts, 3, 0).result == 0;
			assert delegateOf(accounts) == null && u64At(accounts[0].data, 121) == 0;
			assert delegateRun(accounts, 3, 0).result == ProgramError.custom(4).code;
		}
	}

	test "approveDelegate and revokeDelegate under signed act for a PDA owner and only for that PDA" {
		const accounts = delegateAccounts(TOKEN_2022_PROGRAM_ID);
		setKeyAt(accounts[0].data, 32, authorityPda());
		accounts[3].key = authorityPda();
		accounts[3].signer = false;
		assert delegateRun(accounts, 2, 300).result == 0;
		assert delegateOf(accounts) == keyOf(8) && u64At(accounts[0].data, 121) == 300;
		assert signerIs(invocations()[0], 0, authSigner());
		assert delegateRun(accounts, 5, 0).result == 0;
		assert delegateOf(accounts) == null;
		assert signerIs(invocations()[0], 0, authSigner());
		const stranger = delegateAccounts(TOKEN_PROGRAM_ID);
		stranger[3].signer = false;
		for (const op of [2, 5]) {
			const refused = delegateRun(stranger, op as uint8, 300);
			assert refused.result == ProgramError.missingRequiredSignature().code;
			assert refused.fault.indexOf("signer privilege escalated") >= 0;
		}
		assert delegateOf(stranger) == null;
	}
}
