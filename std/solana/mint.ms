import {
	Account,
	InstructionAccount,
	Writable,
	WritableSigner,
	createProgramAccountSeeded,
	putPubkey,
	putU8,
} from "./core";
import { invoke } from "./invoke";
import { ProgramError } from "./error";
import { Pubkey } from "./pubkey";
import { SeedSlice, findAt, ownProgram, tableAddress } from "./seed";

export function isTokenProgram(program: Pubkey): boolean {
	return program.equals(Pubkey.tokenProgram()) || program.equals(Pubkey.token2022Program());
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
