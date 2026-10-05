import {
	Account,
	Bytes,
	External,
	ExternalMutable,
	InstructionAccount,
	Program,
	System,
	Writable,
	WritableSigner,
	putU64,
	putU8,
	unchecked,
} from "./core";
import { ProgramError } from "./error";
import { invokeSigned } from "./invoke";
import { associatedTokenAddress, isTokenProgram } from "./mint";
import { ASSOCIATED_TOKEN_PROGRAM_ID, Pubkey, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID } from "./pubkey";
import { SignerSeeds } from "./seed";

export { associatedTokenAddress, initializeMint2 } from "./mint";
export { createMintPda } from "./macro";

when (testBuild) {
	import {
		account,
		failWith,
		instructionData,
		logU64,
		writable,
		writableSigner,
	} from "./core";
	import { external, externalMutable } from "./typed";
	import { HostAccount, invocations, logs, run, signerIs, textBytes } from "./host";
	import {
		accounts,
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

function optionalKey(data: Bytes, offset: uint64): Result<Pubkey | null, ProgramError> {
	let key: Pubkey | null = null;
	if ((try data.readU8(offset)) == 1) { key = try data.readPubkey(offset + 4); }
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
	const state = try stateOf(try data.readU8(108));
	if (state == TokenAccountState.Uninitialized) {
		return Result.err(ProgramError.uninitializedAccount());
	}
	let nativeReserve: uint64 | null = null;
	if ((try data.readU8(109)) == 1) { nativeReserve = try data.readU64(113); }
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
	return (mint as Account).owner();
}

function mintDecimals(mint: External<Mint>): Result<uint8, ProgramError> {
	const decoded = try (mint as Account).readMint();
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
		from as Account,
		mint as Account,
		to as Account,
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
	const target = mint as Account;
	return mintTo(target.owner(), target, to as Account, authority, amount, signers);
}

export function closeTokenAccount(
	account: ExternalMutable<TokenAccount>,
	destination: Writable,
	authority: Account,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const closing = account as Account;
	return closeAccount(closing.owner(), closing, destination as Account, authority, signers);
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
		payer as Account,
		associated as Account,
		wallet,
		mint as Account,
		systemProgram as Account,
		tokenProgram,
	);
}

export function expectAssociated(
	tokenAccount: Pubkey,
	wallet: Pubkey,
	mint: External<Mint>,
): Result<void, ProgramError> {
	const mintKey = (mint as Account).key();
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
		assert created.program.equals(Pubkey.zero()) && created.data[0] == 0;
		assert created.data[12] == 82 && created.signers == 1;
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
	import { Signer } from "./core";
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
		return transferTokens(x.from, x.to, x.mint, x.owner as Account, 250);
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
}
