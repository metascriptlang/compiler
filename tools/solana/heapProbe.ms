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

struct Pair {
	left: uint64;
	right: uint64;
}

function pushLoop(count: uint64): Result<uint64, ProgramError> {
	const values: uint64[] = [];
	for (let index: uint64 = 0; index < count; index++) {
		values.push(index * 3 + 1);
	}
	let sum: uint64 = 0;
	for (let index: uint64 = 0; index < count; index++) {
		sum = sum + values[index] * (index + 1);
	}
	logU64(sum);
	return Result.ok(0);
}

function literalLoop(count: uint64): Result<uint64, ProgramError> {
	let sum: uint64 = 0;
	for (let index: uint64 = 0; index < count; index++) {
		const values: uint64[] = [index, index + 1, index + 2];
		values.push(index + 3);
		sum = sum + values[0] + values[1] * 2 + values[2] * 3 + values[3] * 4;
	}
	logU64(sum);
	return Result.ok(0);
}

function pairLoop(count: uint64): Result<uint64, ProgramError> {
	const pairs: Pair[] = [];
	for (let index: uint64 = 0; index < count; index++) {
		pairs.push({ left: index, right: index * 2 + 1 });
	}
	let sum: uint64 = 0;
	for (let index: uint64 = 0; index < count; index++) {
		sum = sum + pairs[index].left * 7 + pairs[index].right;
	}
	logU64(sum);
	return Result.ok(0);
}

function textLoop(count: uint64): Result<uint64, ProgramError> {
	let text = "";
	for (let index: uint64 = 0; index < count; index++) {
		text = text + "ab";
	}
	let sum: uint64 = text.length as uint64;
	for (let index: int32 = 0; index < (count as int32); index++) {
		const first = text.charCodeAt(index * 2) as uint64;
		const second = text.charCodeAt(index * 2 + 1) as uint64;
		sum = sum + first + second * 3;
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
	if (op == 6) { return pushLoop(count); }
	if (op == 7) { return literalLoop(count); }
	if (op == 8) { return pairLoop(count); }
	if (op == 9) { return textLoop(count); }
	return request(0 - count);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
