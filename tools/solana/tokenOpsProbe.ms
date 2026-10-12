import {
	ProgramError,
	Pubkey,
	account,
	asAccount,
	external,
	externalMutable,
	failWith,
	instructionData,
	readPubkey,
	readU64,
	readU8,
	signedPda,
	signer,
	writable,
	writableSigner,
} from "std/solana";
import {
	AuthorityType,
	Mint,
	TokenAccount,
	approveChecked,
	approveDelegate,
	burnChecked,
	burnTokens,
	createAssociatedToken,
	createTokenAccount,
	initializeAccount3,
	revokeDelegate,
	setAuthority,
	setAuthorityOf,
	transferTokens,
} from "std/solana/token";

const CREATE_AT_KEYPAIR: uint8 = 0;
const CREATE_AT_PDA: uint8 = 1;
const INITIALIZE_RAW: uint8 = 2;
const BURN: uint8 = 3;
const BURN_AS_PDA: uint8 = 4;
const BURN_RAW: uint8 = 5;
const SET_MINT_AUTHORITY: uint8 = 6;
const SET_ACCOUNT_AUTHORITY: uint8 = 7;
const SET_MINT_AUTHORITY_AS_PDA: uint8 = 8;
const SET_AUTHORITY_RAW: uint8 = 9;
const APPROVE: uint8 = 10;
const APPROVE_AS_PDA: uint8 = 11;
const APPROVE_RAW: uint8 = 12;
const REVOKE: uint8 = 13;
const REVOKE_AS_PDA: uint8 = 14;
const TRANSFER: uint8 = 15;
const CREATE_ASSOCIATED_RAW: uint8 = 16;

function createAtKeypair(): Result<uint64, ProgramError> {
	const payer = try writableSigner(0);
	const fresh = try writableSigner(1);
	const mint = try external<Mint>(2);
	return createTokenAccount(payer, fresh, mint, try instructionData().readPubkey(1));
}

function createAtPda(): Result<uint64, ProgramError> {
	const payer = try writableSigner(0);
	const vault = try writable(1);
	const mint = try external<Mint>(2);
	return signedPda(
		createTokenAccount(payer, vault, mint, try instructionData().readPubkey(1)),
		vault.asAccount(),
		["vault", mint],
	);
}

function initializeRaw(): Result<uint64, ProgramError> {
	const target = try account(1);
	const mint = try account(2);
	const program = try account(3);
	return initializeAccount3(program.key(), target, mint, try instructionData().readPubkey(1));
}

function burn(): Result<uint64, ProgramError> {
	const from = try externalMutable<TokenAccount>(0);
	const mint = try externalMutable<Mint>(1);
	return burnTokens(from, mint, try signer(2), try instructionData().readU64(1));
}

function burnAsPda(): Result<uint64, ProgramError> {
	const from = try externalMutable<TokenAccount>(0);
	const mint = try externalMutable<Mint>(1);
	const authority = try account(2);
	const amount = try instructionData().readU64(1);
	return signedPda(burnTokens(from, mint, authority, amount), authority, ["authority"]);
}

function burnRaw(): Result<uint64, ProgramError> {
	const mint = try account(1);
	return burnChecked(
		mint.owner(),
		try account(0),
		mint,
		try account(2),
		try instructionData().readU64(1),
		try instructionData().readU8(9),
	);
}

function authorityKind(): Result<AuthorityType, ProgramError> {
	return match (try instructionData().readU8(1)) {
		0 => Result.ok(AuthorityType.MintTokens),
		1 => Result.ok(AuthorityType.FreezeAccount),
		2 => Result.ok(AuthorityType.AccountOwner),
		3 => Result.ok(AuthorityType.CloseAccount),
		_ => Result.err(ProgramError.invalidInstructionData()),
	};
}

function nextAuthority(): Result<Pubkey | null, ProgramError> {
	if ((try instructionData().readU8(2)) == 0) { return Result.ok(null); }
	const next: Pubkey | null = try instructionData().readPubkey(3);
	return Result.ok(next);
}

function setMintAuthority(): Result<uint64, ProgramError> {
	const mint = try externalMutable<Mint>(0);
	return setAuthorityOf(mint, try authorityKind(), try signer(1), try nextAuthority());
}

function setAccountAuthority(): Result<uint64, ProgramError> {
	const held = try externalMutable<TokenAccount>(0);
	return setAuthorityOf(held, try authorityKind(), try signer(1), try nextAuthority());
}

function setMintAuthorityAsPda(): Result<uint64, ProgramError> {
	const mint = try externalMutable<Mint>(0);
	const authority = try account(1);
	const kind = try authorityKind();
	const next = try nextAuthority();
	return signedPda(setAuthorityOf(mint, kind, authority, next), authority, ["authority"]);
}

function setAuthorityRaw(): Result<uint64, ProgramError> {
	const program = (try account(2)).key();
	const kind = try authorityKind();
	return setAuthority(program, try account(0), try account(1), kind, try nextAuthority());
}

function approve(): Result<uint64, ProgramError> {
	const source = try externalMutable<TokenAccount>(0);
	const mint = try external<Mint>(1);
	const amount = try instructionData().readU64(1);
	return approveDelegate(source, mint, try account(2), try signer(3), amount);
}

function approveAsPda(): Result<uint64, ProgramError> {
	const source = try externalMutable<TokenAccount>(0);
	const mint = try external<Mint>(1);
	const delegate = try account(2);
	const authority = try account(3);
	const amount = try instructionData().readU64(1);
	return signedPda(
		approveDelegate(source, mint, delegate, authority, amount),
		authority,
		["authority"],
	);
}

function approveRaw(): Result<uint64, ProgramError> {
	const mint = try account(1);
	return approveChecked(
		mint.owner(),
		try account(0),
		mint,
		try account(2),
		try account(3),
		try instructionData().readU64(1),
		try instructionData().readU8(9),
	);
}

function revokeBySigner(): Result<uint64, ProgramError> {
	return revokeDelegate(try externalMutable<TokenAccount>(0), try signer(1));
}

function revokeAsPda(): Result<uint64, ProgramError> {
	const source = try externalMutable<TokenAccount>(0);
	const authority = try account(1);
	return signedPda(revokeDelegate(source, authority), authority, ["authority"]);
}

function transfer(): Result<uint64, ProgramError> {
	const from = try externalMutable<TokenAccount>(0);
	const to = try externalMutable<TokenAccount>(1);
	const mint = try external<Mint>(2);
	return transferTokens(from, to, mint, try account(3), try instructionData().readU64(1));
}

function createAssociatedRaw(): Result<uint64, ProgramError> {
	return createAssociatedToken(
		try account(0),
		try account(1),
		try account(2),
		try account(3),
		try account(4),
		try account(5),
	);
}

function dispatch(): Result<uint64, ProgramError> {
	return match (try instructionData().readU8(0)) {
		CREATE_AT_KEYPAIR => createAtKeypair(),
		CREATE_AT_PDA => createAtPda(),
		INITIALIZE_RAW => initializeRaw(),
		BURN => burn(),
		BURN_AS_PDA => burnAsPda(),
		BURN_RAW => burnRaw(),
		SET_MINT_AUTHORITY => setMintAuthority(),
		SET_ACCOUNT_AUTHORITY => setAccountAuthority(),
		SET_MINT_AUTHORITY_AS_PDA => setMintAuthorityAsPda(),
		SET_AUTHORITY_RAW => setAuthorityRaw(),
		APPROVE => approve(),
		APPROVE_AS_PDA => approveAsPda(),
		APPROVE_RAW => approveRaw(),
		REVOKE => revokeBySigner(),
		REVOKE_AS_PDA => revokeAsPda(),
		TRANSFER => transfer(),
		CREATE_ASSOCIATED_RAW => createAssociatedRaw(),
		_ => Result.err(ProgramError.invalidInstructionData()),
	};
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
