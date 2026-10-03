import {
	Account,
	Instruction,
	Writable,
	WritableSigner,
	createProgramAccountSeeded,
} from "./core";
import { ProgramError } from "./error";
import { Pubkey } from "./pubkey";
import { SeedSlice, findAt, ownProgram, tableAddress } from "./seed";

export function isTokenProgram(program: Pubkey): boolean {
	return program.equals(Pubkey.tokenProgram()) || program.equals(Pubkey.token2022Program());
}

export function tokenInstruction(
	program: Pubkey,
	accountCount: uint64,
	dataLength: uint64,
): Result<Instruction, ProgramError> {
	if (!isTokenProgram(program)) { return Result.err(ProgramError.incorrectProgramId()); }
	return Result.ok(Instruction.forProgram(program, accountCount, dataLength));
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
