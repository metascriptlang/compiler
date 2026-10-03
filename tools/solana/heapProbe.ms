@include("runtime/solana/solana.h");

import {
	Instruction,
	ProgramError,
	Seeds,
	failWith,
	instructionData,
	logU64,
	programId,
} from "std/solana";

extern function msSolAlloc(size: uint64): uint64;

function seedsLoop(count: uint64): Result<uint64, ProgramError> {
	const program = programId();
	const found = try Seeds.empty(2).addText("pet").addPubkey(program).findProgramAddress(program);
	for (let index: uint64 = 0; index < count; index++) {
		const _key = try Seeds.empty(2).addText("pet").addPubkey(program).withBump(found.bump).createProgramAddress(program);
	}
	logU64(count);
	return Result.ok(0);
}

function builderLoop(count: uint64): Result<uint64, ProgramError> {
	for (let index: uint64 = 0; index < count; index++) {
		const instruction = Instruction.forProgram(programId(), 1, 512);
		instruction.appendU8(0);
	}
	logU64(count);
	return Result.ok(0);
}

class Cell {
	value: uint64 = 0;
}

function cellLoop(count: uint64): Result<uint64, ProgramError> {
	let sum: uint64 = 0;
	for (let index: uint64 = 0; index < count; index++) {
		const cell = new Cell();
		cell.value = index;
		sum = sum + cell.value;
	}
	logU64(sum);
	return Result.ok(0);
}

function request(size: uint64): Result<uint64, ProgramError> {
	logU64(msSolAlloc(size));
	return Result.ok(0);
}

function dispatch(): Result<uint64, ProgramError> {
	const data = instructionData();
	const op = try data.readU8(0);
	const count = (try data.readU16(1)) as uint64;
	if (op == 1) { return seedsLoop(count); }
	if (op == 2) { return builderLoop(count); }
	if (op == 3) { return cellLoop(count); }
	if (op == 4) { return request(count); }
	return request(0 - count);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
