import {
	Account,
	Bytes,
	External,
	ExternalMutable,
	Instruction,
	Program,
	ProgramAddress,
	ProgramError,
	Pubkey,
	Seeds,
	Signer,
	System,
	Writable,
	WritableSigner,
	createProgramAccount,
	programId,
	unchecked,
} from "./core";

when (testBuild) {
	import {
		account,
		failWith,
		instructionData,
		logU64,
		readArgs,
		writable,
		writableSigner,
	} from "./core";
	import { HostAccount, invocations, logs, run } from "./host";
	import { accounts } from "./macro";
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

function isTokenProgram(program: Pubkey): boolean {
	return program.equals(Pubkey.tokenProgram()) || program.equals(Pubkey.token2022Program());
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
	if (account.isOwnedBy(Pubkey.tokenProgram())) {
		if (data.length != 82) { return Result.err(ProgramError.invalidAccountData()); }
		return Result.ok(data);
	}
	if (!account.isOwnedBy(Pubkey.token2022Program())) {
		return Result.err(ProgramError.invalidAccountOwner());
	}
	if (data.length != 82 && !(try hasExtensionLayout(data, 1))) {
		return Result.err(ProgramError.invalidAccountData());
	}
	return Result.ok(data);
}

function tokenAccountBytes(account: Account): Result<Bytes, ProgramError> {
	const data = account.data();
	if (account.isOwnedBy(Pubkey.tokenProgram())) {
		if (data.length != 165) { return Result.err(ProgramError.invalidAccountData()); }
		return Result.ok(data);
	}
	if (!account.isOwnedBy(Pubkey.token2022Program())) {
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
	if (!account.isOwnedBy(Pubkey.token2022Program())) {
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
	if (!account.isOwnedBy(Pubkey.token2022Program())) {
		return Result.err(ProgramError.invalidAccountOwner());
	}
	const data = try withExtensions(account.data(), 165, 2);
	if (extensionBase(kind) != 2) { return Result.err(ProgramError.invalidAccountData()); }
	return extensionIn(data, kind);
}

function tokenInstruction(
	program: Pubkey,
	accountCount: uint64,
	dataLength: uint64,
): Result<Instruction, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	return Result.ok(Instruction.forProgram(program, accountCount, dataLength));
}

export function createMintPda(
	payer: WritableSigner,
	mint: Writable,
	seeds: Seeds,
	program: Pubkey,
	decimals: uint8,
	mintAuthority: Pubkey,
	freezeAuthority: Pubkey | null,
): Result<uint8, ProgramError> {
	const target = mint as Account;
	if ((payer as Account).key() == target.key()) {
		return Result.err(ProgramError.tryingToInitPayerAsProgramAccount());
	}
	const found = try seeds.findProgramAddress(programId());
	if (found.key != target.key()) { return Result.err(ProgramError.constraintSeeds()); }
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	const signer = seeds.withBump(found.bump);
	const _created = try createProgramAccount(payer as Account, target, 82, program, signer);
	const _initialized = try initializeMint2(program, target, decimals, mintAuthority, freezeAuthority);
	return Result.ok(found.bump);
}

export function initializeMint2(
	program: Pubkey,
	mint: Account,
	decimals: uint8,
	mintAuthority: Pubkey,
	freezeAuthority: Pubkey | null,
): Result<uint64, ProgramError> {
	const instruction = try tokenInstruction(program, 1, 67);
	instruction.addWritable(mint);
	instruction.appendU8(20);
	instruction.appendU8(decimals);
	instruction.appendPubkey(mintAuthority);
	if (freezeAuthority === null) {
		instruction.appendU8(0);
	} else {
		instruction.appendU8(1);
		instruction.appendPubkey(freezeAuthority);
	}
	return instruction.invoke();
}

export function mintTo(
	program: Pubkey,
	mint: Account,
	destination: Account,
	authority: Account,
	amount: uint64,
	signer: Seeds,
): Result<uint64, ProgramError> {
	const instruction = try tokenInstruction(program, 3, 9);
	instruction.addWritable(mint);
	instruction.addWritable(destination);
	instruction.addReadonlySigner(authority);
	instruction.appendU8(7);
	instruction.appendU64(amount);
	return instruction.invokeSigned(signer);
}

export function transferChecked(
	program: Pubkey,
	source: Account,
	mint: Account,
	destination: Account,
	authority: Account,
	amount: uint64,
	decimals: uint8,
	signer: Seeds,
): Result<uint64, ProgramError> {
	const instruction = try tokenInstruction(program, 4, 10);
	instruction.addWritable(source);
	instruction.addReadonly(mint);
	instruction.addWritable(destination);
	instruction.addReadonlySigner(authority);
	instruction.appendU8(12);
	instruction.appendU64(amount);
	instruction.appendU8(decimals);
	return instruction.invokeSigned(signer);
}

export function closeAccount(
	program: Pubkey,
	account: Account,
	destination: Account,
	authority: Account,
	signer: Seeds,
): Result<uint64, ProgramError> {
	const instruction = try tokenInstruction(program, 3, 1);
	instruction.addWritable(account);
	instruction.addWritable(destination);
	instruction.addReadonlySigner(authority);
	instruction.appendU8(9);
	return instruction.invokeSigned(signer);
}

export function associatedTokenAddress(
	wallet: Pubkey,
	mint: Pubkey,
	program: Pubkey,
): Result<ProgramAddress, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	const seeds = Seeds.empty(3).addPubkey(wallet).addPubkey(program).addPubkey(mint);
	return seeds.findProgramAddress(Pubkey.associatedTokenProgram());
}

function createAssociated(
	payer: Account,
	associated: Account,
	wallet: Account,
	mint: Account,
	systemProgram: Account,
	program: Account,
	discriminator: uint8,
	signer: Seeds,
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program.key())) { return Result.err(ProgramError.incorrectProgramId()); }
	const instruction = Instruction.forProgram(Pubkey.associatedTokenProgram(), 6, 1);
	instruction.addWritableSigner(payer);
	instruction.addWritable(associated);
	instruction.addReadonly(wallet);
	instruction.addReadonly(mint);
	instruction.addReadonly(systemProgram);
	instruction.addReadonly(program);
	instruction.appendU8(discriminator);
	return instruction.invokeSigned(signer);
}

export function createAssociatedToken(
	payer: Account,
	associated: Account,
	wallet: Account,
	mint: Account,
	systemProgram: Account,
	program: Account,
	signer: Seeds,
): Result<uint64, ProgramError> {
	return createAssociated(payer, associated, wallet, mint, systemProgram, program, 0, signer);
}

export function createAssociatedTokenIdempotent(
	payer: Account,
	associated: Account,
	wallet: Account,
	mint: Account,
	systemProgram: Account,
	program: Account,
	signer: Seeds,
): Result<uint64, ProgramError> {
	return createAssociated(payer, associated, wallet, mint, systemProgram, program, 1, signer);
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
	if (!isTokenProgram(found.owner())) {
		return Result.err(ProgramError.accountOwnedByWrongProgram());
	}
	const decoded = found.readMint();
	if (!decoded.ok) { return Result.err(ProgramError.accountDidNotDeserialize()); }
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
	if (!isTokenProgram(found.owner())) {
		return Result.err(ProgramError.accountOwnedByWrongProgram());
	}
	const decoded = found.readTokenAccount();
	if (!decoded.ok) { return Result.err(ProgramError.accountDidNotDeserialize()); }
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
	authority: Signer,
	amount: uint64,
): Result<uint64, ProgramError> {
	return transferTokensSigned(from, to, mint, authority as Account, amount, Seeds.none());
}

export function transferTokensSigned(
	from: ExternalMutable<TokenAccount>,
	to: ExternalMutable<TokenAccount>,
	mint: External<Mint>,
	authority: Account,
	amount: uint64,
	signer: Seeds,
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
		signer,
	);
}

export function mintTokens(
	mint: ExternalMutable<Mint>,
	to: ExternalMutable<TokenAccount>,
	authority: Account,
	amount: uint64,
	signer: Seeds,
): Result<uint64, ProgramError> {
	const target = mint as Account;
	return mintTo(target.owner(), target, to as Account, authority, amount, signer);
}

export function closeTokenAccount(
	account: ExternalMutable<TokenAccount>,
	destination: Writable,
	authority: Account,
	signer: Seeds,
): Result<uint64, ProgramError> {
	const closing = account as Account;
	return closeAccount(closing.owner(), closing, destination as Account, authority, signer);
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
		Seeds.none(),
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
		const accounts = single(Pubkey.tokenProgram(), mintData(5, 1000000, 6));
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
		const shortened = single(Pubkey.tokenProgram(), short);
		assert resultOf(shortened, 0, readerEntry) == ProgramError.invalidAccountData().code;
		const blank = mintData(5, 1, 6);
		blank[45] = 0;
		const uninitialized = single(Pubkey.tokenProgram(), blank);
		assert resultOf(uninitialized, 0, readerEntry) == ProgramError.uninitializedAccount().code;
	}

	test "readTokenAccount reads amount, state and the close authority at their byte offsets" {
		const accounts = single(Pubkey.tokenProgram(), tokenAccountData(4, 8, 77, 2));
		assert resultOf(accounts, 1, readerEntry) == 0;
		const lines = logs();
		assert lines[0] == logged("0x4d");
		assert lines[1] == logged("0x2");
		assert lines[2] == logged("0x0");
		assert lines[3] == logged("0x8");
	}

	test "a token account with an unknown state byte is refused" {
		const accounts = single(Pubkey.tokenProgram(), tokenAccountData(4, 8, 77, 3));
		assert resultOf(accounts, 1, readerEntry) == ProgramError.invalidAccountData().code;
	}

	test "mintExtension walks the Token-2022 TLV entries after byte 166" {
		const accounts = single(Pubkey.token2022Program(), mint2022Data());
		assert resultOf(accounts, 2, readerEntry) == 0;
		assert logs()[0] == logged("0x40");
		assert logs()[1] == logged("0x2c");
	}

	test "mintExtension reports a missing extension and refuses an account extension" {
		const accounts = single(Pubkey.token2022Program(), mint2022Data());
		assert resultOf(accounts, 3, readerEntry) == ProgramError.custom(48).code;
		assert resultOf(accounts, 4, readerEntry) == ProgramError.invalidAccountData().code;
		const plain = single(Pubkey.token2022Program(), mintData(5, 1, 0));
		assert resultOf(plain, 3, readerEntry) == ProgramError.custom(48).code;
	}

	test "groupMemberPointer and tokenGroupMember decode Token-2022's layouts" {
		const accounts = single(Pubkey.token2022Program(), mint2022Data());
		assert resultOf(accounts, 5, readerEntry) == 0;
		assert logs()[0] == logged("0x21") && logs()[1] == logged("0x2c");
		assert resultOf(accounts, 6, readerEntry) == 0;
		assert logs()[0] == logged("0x1") && logs()[1] == logged("0x37");
		assert logs()[2] == logged("0x1092");
		const unset = single(Pubkey.token2022Program(), memberMintData(Pubkey.zero(), 64));
		assert resultOf(unset, 5, readerEntry) == 0;
		assert logs()[0] == logged("0x0") && logs()[1] == logged("0x2c");
	}

	test "a group member pointer of another length is refused, as bytemuck refuses it" {
		const longer = single(Pubkey.token2022Program(), memberMintData(keyOf(33), 65));
		assert resultOf(longer, 5, readerEntry) == ProgramError.invalidArgument().code;
		const plain = single(Pubkey.tokenProgram(), mintData(5, 1, 0));
		assert resultOf(plain, 6, readerEntry) == ProgramError.invalidAccountOwner().code;
	}

	function cpiStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const mint = try account(0);
		const target = try account(1);
		const authority = try account(2);
		const payer = try account(3);
		const none = Seeds.none();
		const token = Pubkey.tokenProgram();
		if (op == 0) { return mintTo(token, mint, target, authority, 500, none); }
		if (op == 1) {
			const extended = Pubkey.token2022Program();
			return transferChecked(extended, payer, mint, target, authority, 250, 6, none);
		}
		if (op == 2) { return closeAccount(token, target, payer, authority, none); }
		if (op == 3) { return initializeMint2(token, mint, 6, authority.key(), null); }
		if (op == 4) { return initializeMint2(token, mint, 6, authority.key(), payer.key()); }
		if (op == 5) {
			const system = try account(4);
			const program = try account(5);
			return createAssociatedTokenIdempotent(
				payer,
				target,
				authority,
				mint,
				system,
				program,
				none,
			);
		}
		return mintTo(keyOf(3), mint, target, authority, 500, none);
	}

	function cpiEntry(): void {
		const result = cpiStep();
		if (!result.ok) { failWith(result.error); }
	}

	function cpiAccounts(): HostAccount[] {
		const program: HostAccount = {
			...holderOf(6, keyOf(0), []),
			key: Pubkey.tokenProgram(),
			writable: false,
			executable: true,
		};
		return [
			holderOf(1, Pubkey.tokenProgram(), mintData(7, 500, 6)),
			holderOf(2, Pubkey.tokenProgram(), tokenAccountData(1, 3, 0, 1)),
			{ ...holderOf(3, keyOf(0), []), signer: true, writable: false },
			{ ...holderOf(4, keyOf(0), tokenAccountData(1, 3, 900, 1)), signer: true },
			{ ...holderOf(0, keyOf(0), []), writable: false, executable: true },
			program,
		];
	}

	test "mintTo, transferChecked and closeAccount carry the token program's accounts and data" {
		assert resultOf(cpiAccounts(), 0, cpiEntry) == 0;
		const minted = invocations()[0];
		assert minted.program.equals(Pubkey.tokenProgram());
		assert minted.accounts.length == 3;
		assert minted.accounts[0].writable && !minted.accounts[0].signer;
		assert minted.accounts[1].key.equals(keyOf(2)) && minted.accounts[1].writable;
		assert minted.accounts[2].signer && !minted.accounts[2].writable;
		const mintBytes: uint8[] = [7, 0xf4, 1, 0, 0, 0, 0, 0, 0];
		assert sameBytes(minted.data, mintBytes);

		assert resultOf(cpiAccounts(), 1, cpiEntry) == 0;
		const moved = invocations()[0];
		assert moved.program.equals(Pubkey.token2022Program());
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
		assert created.program.equals(Pubkey.associatedTokenProgram());
		assert created.accounts.length == 6;
		const funding = created.accounts[0];
		assert funding.key.equals(keyOf(4)) && funding.signer && funding.writable;
		assert created.accounts[1].key.equals(keyOf(2)) && created.accounts[1].writable;
		const program = created.accounts[5];
		assert program.key.equals(Pubkey.tokenProgram()) && !program.writable;
		assert created.data.length == 1 && created.data[0] == 1;
	}

	function mintSeeds(): Seeds {
		return Seeds.empty(1).addText("mint");
	}

	function mintPdaStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const program = op == 0 ? Pubkey.tokenProgram() : Pubkey.systemProgram();
		const payer = try writableSigner(0);
		const mint = try writable(1);
		const bump = try createMintPda(payer, mint, mintSeeds(), program, 6, keyOf(7), null);
		return Result.ok(bump as uint64);
	}

	function mintPdaEntry(): void {
		const result = mintPdaStep();
		if (!result.ok) { failWith(result.error); }
	}

	function mintPdaAccounts(mintKey: Pubkey): HostAccount[] {
		const payer: HostAccount = {
			...holderOf(1, Pubkey.systemProgram(), []),
			lamports: 10000000,
			signer: true,
		};
		const mint: HostAccount = {
			...holderOf(2, Pubkey.systemProgram(), []),
			key: mintKey,
			lamports: 0,
		};
		return [payer, mint];
	}

	function mintKey(): Pubkey {
		const found = mintSeeds().findProgramAddress(keyOf(9));
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	test "createMintPda creates the mint at its PDA for the token program, then initializes it" {
		const accounts = mintPdaAccounts(mintKey());
		assert resultOf(accounts, 0, mintPdaEntry) == 0;
		assert accounts[1].owner.equals(Pubkey.tokenProgram()) && accounts[1].data.length == 82;
		assert accounts[1].lamports > 0;
		const created = invocations()[0];
		assert created.program.equals(Pubkey.systemProgram()) && created.data[0] == 0;
		assert created.data[12] == 82 && created.signers == 1;
		const initialized = invocations()[1];
		assert initialized.program.equals(Pubkey.tokenProgram());
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
		const classic = associatedTokenAddress(wallet, mint, Pubkey.tokenProgram());
		assert classic.ok;
		if (classic.ok) {
			assert classic.value.bump == 255;
			assert wordAt(classic.value.key, 0) == tokenWord0;
			assert wordAt(classic.value.key, 3) == tokenWord3;
		}
		const extendedWord0: uint64 = 0xc080ac8fa7881df3;
		const extendedWord3: uint64 = 0x08b979898d73f9d3;
		const extended = associatedTokenAddress(wallet, mint, Pubkey.token2022Program());
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
		return transferTokens(x.from, x.to, x.mint, x.owner, 250);
	}

	function typedTransferEntry(): void {
		const result = typedTransferStep();
		if (!result.ok) { failWith(result.error); }
	}

	function typedAccounts(mintOwner: Pubkey, mintData: uint8[]): HostAccount[] {
		let owner = holderOf(3, Pubkey.systemProgram(), []);
		owner.signer = true;
		return [
			owner,
			holderOf(4, Pubkey.token2022Program(), tokenAccountData(1, 3, 900, 1)),
			holderOf(5, Pubkey.token2022Program(), tokenAccountData(1, 6, 0, 1)),
			holderOf(1, mintOwner, mintData),
		];
	}

	function goodMint(): HostAccount[] {
		return typedAccounts(Pubkey.token2022Program(), mintData(7, 500, 6));
	}

	test "typed token accounts verify through accounts<T>() and transfer with the mint's decimals" {
		assert resultOf(goodMint(), 0, typedTransferEntry) == 0;
		const moved = invocations()[0];
		assert moved.program == Pubkey.token2022Program();
		const moveBytes: uint8[] = [12, 250, 0, 0, 0, 0, 0, 0, 0, 6];
		assert sameBytes(moved.data, moveBytes);
	}

	test "a mint owned by another program or with a broken layout is refused with Anchor's codes" {
		const foreign = typedAccounts(Pubkey.systemProgram(), mintData(7, 500, 6));
		assert resultOf(foreign, 0, typedTransferEntry) ==
			ProgramError.accountOwnedByWrongProgram().code;
		const short: uint8[] = [1, 2, 3];
		const broken = typedAccounts(Pubkey.token2022Program(), short);
		assert resultOf(broken, 0, typedTransferEntry) ==
			ProgramError.accountDidNotDeserialize().code;
	}

	test "expectAssociated refuses a token account that is not the owner's associated account" {
		assert resultOf(goodMint(), 1, typedTransferEntry) ==
			ProgramError.accountNotAssociatedTokenAccount().code;
	}
}
