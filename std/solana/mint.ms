import {
	Account,
	InstructionAccount,
	createProgramAccountSeeded,
	putPubkey,
	putU8,
} from "./core";
import { Writable, WritableSigner, asAccount } from "./typed";
import { invoke } from "./invoke";
import { ProgramAddress } from "./pda";
import { ProgramError } from "./error";
import { ASSOCIATED_TOKEN_PROGRAM_ID, Pubkey, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID } from "./pubkey";
import {
	SeedSlice,
	bytesAddress,
	findAddress,
	seedBytes,
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
	seeds: Readonly<Span<SeedSlice>>,
	program: Pubkey,
	decimals: uint8,
	mintAuthority: Pubkey,
	freezeAuthority: Pubkey | null,
): Result<uint8, ProgramError> {
	const target = mint.asAccount();
	if (payer.asAccount().key() == target.key()) {
		return Result.err(ProgramError.tryingToInitPayerAsProgramAccount());
	}
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	const bump = try createProgramAccountSeeded(
		payer.asAccount(),
		target,
		82,
		program,
		seeds,
	);
	const _initialized = try initializeMint2(
		program,
		target,
		decimals,
		mintAuthority,
		freezeAuthority,
	);
	return Result.ok(bump);
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

