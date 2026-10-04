import {
	Account,
	InstructionAccount,
	Writable,
	WritableSigner,
	createProgramAccountSeeded,
	keysEqual,
	putPubkey,
	putU8,
} from "./core";
import { invoke } from "./invoke";
import { ProgramAddress } from "./pda";
import { ProgramError } from "./error";
import { ASSOCIATED_TOKEN_PROGRAM_ID, Pubkey, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID } from "./pubkey";
import {
	SeedSlice,
	bytesAddress,
	findAddress,
	findAt,
	ownProgram,
	seedBytes,
	seedKey,
	tableAddress,
} from "./seed";

export function isTokenProgram(program: Pubkey): boolean {
	return program.equals(TOKEN_PROGRAM_ID) || program.equals(TOKEN_2022_PROGRAM_ID);
}

export function initializeMint2(
	program: Pubkey,
	mint: Account,
	decimals: uint8,
	mintAuthority: Pubkey,
	freezeAuthority: Pubkey | null,
): Result<uint64, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	let storage: uint8[67] = [];
	let length = putU8(storage, 0, 20);
	length = putU8(storage, length, decimals);
	length = putPubkey(storage, length, mintAuthority);
	if (freezeAuthority === null) {
		length = putU8(storage, length, 0);
	} else {
		length = putU8(storage, length, 1);
		length = putPubkey(storage, length, freezeAuthority);
	}
	return invoke(program, [InstructionAccount.writable(mint)], storage, length);
}

export function createMintPdaAt(
	payer: WritableSigner,
	mint: Writable,
	seeds: Span<SeedSlice>,
	program: Pubkey,
	decimals: uint8,
	mintAuthority: Pubkey,
	freezeAuthority: Pubkey | null,
): Result<uint8, ProgramError> {
	const target = mint as Account;
	if ((payer as Account).key() == target.key()) {
		return Result.err(ProgramError.tryingToInitPayerAsProgramAccount());
	}
	const found = try findAt(tableAddress(seeds), seeds.length as uint64, ownProgram());
	if (found.key != target.key()) { return Result.err(ProgramError.constraintSeeds()); }
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	const _created = try createProgramAccountSeeded(
		payer as Account,
		target,
		82,
		program,
		seeds,
		found.bump,
	);
	const _initialized = try initializeMint2(
		program,
		target,
		decimals,
		mintAuthority,
		freezeAuthority,
	);
	return Result.ok(found.bump);
}

export function associatedTokenAddress(
	wallet: Pubkey,
	mint: Pubkey,
	program: Pubkey,
): Result<ProgramAddress, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	const seeds: SeedSlice[3] = [
		seedBytes(wallet.bytes),
		seedBytes(program.bytes),
		seedBytes(mint.bytes),
	];
	const associatedProgram = ASSOCIATED_TOKEN_PROGRAM_ID;
	return findAddress(seeds, bytesAddress(associatedProgram.bytes));
}

export function tokenMintMatches(token: uint64, expected: uint64): Result<void, ProgramError> {
	if (!keysEqual(token + 80, expected)) { return Result.err(ProgramError.constraintTokenMint()); }
	return Result.ok(null);
}

export function tokenAuthorityMatches(token: uint64, expected: uint64): Result<void, ProgramError> {
	if (!keysEqual(token + 112, expected)) { return Result.err(ProgramError.constraintTokenOwner()); }
	return Result.ok(null);
}

export function associatedMatches(
	token: uint64,
	wallet: uint64,
	mint: uint64,
): Result<void, ProgramError> {
	if (!keysEqual(token + 112, wallet)) { return Result.err(ProgramError.constraintTokenOwner()); }
	const tokenProgram = mint + 32;
	if (!keysEqual(tokenProgram, bytesAddress(TOKEN_PROGRAM_ID.bytes)) &&
		!keysEqual(tokenProgram, bytesAddress(TOKEN_2022_PROGRAM_ID.bytes))) {
		return Result.err(ProgramError.incorrectProgramId());
	}
	const seeds: SeedSlice[3] = [seedKey(wallet), seedKey(tokenProgram), seedKey(mint)];
	const associatedProgram = ASSOCIATED_TOKEN_PROGRAM_ID;
	const derived = try findAddress(seeds, bytesAddress(associatedProgram.bytes));
	if (!keysEqual(bytesAddress(derived.key.bytes), token)) {
		return Result.err(ProgramError.constraintAssociated());
	}
	return Result.ok(null);
}
