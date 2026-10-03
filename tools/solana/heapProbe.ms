@include("runtime/solana/solana.h");

import {
	InstructionAccount,
	ProgramError,
	Pubkey,
	account,
	clock,
	emitEvent,
	failWith,
	findProgramAddress,
	instructionData,
	invoke,
	invokeList,
	logPubkey,
	logU64,
	minimumBalance,
	programAddress,
	programId,
	putU8,
	returnData,
	setReturnData,
	signed,
} from "std/solana";

extern function msSolAlloc(size: uint64): uint64;

function seedsLoop(count: uint64): Result<uint64, ProgramError> {
	const program = programId();
	const found = try findProgramAddress(["pet", program]);
	for (let index: uint64 = 0; index < count; index++) {
		const _key = try programAddress(["pet", program, [found.bump]]);
	}
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

function builderLoop(count: uint64): Result<uint64, ProgramError> {
	for (let index: uint64 = 0; index < count; index++) {
		const self = try account(0);
		let storage: uint8[512] = [];
		const _sent = try invoke(
			programId(),
			[InstructionAccount.readonly(self)],
			storage,
			putU8(storage, putU8(storage, putU8(storage, 0, 12), 0), 0),
		);
	}
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

function signedLoop(count: uint64): Result<uint64, ProgramError> {
	const program = programId();
	const found = try findProgramAddress(["pet", program]);
	for (let index: uint64 = 0; index < count; index++) {
		const self = try account(0);
		let storage: uint8[3] = [];
		const _sent = try signed(
			invoke(
				program,
				[InstructionAccount.readonly(self)],
				storage,
				putU8(storage, putU8(storage, putU8(storage, 0, 12), 0), 0),
			),
			["pet", program, [found.bump]],
		);
	}
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

function limitCall(which: uint64): Result<uint64, ProgramError> {
	const self = try account(0);
	let storage: uint8[3] = [];
	const length = putU8(storage, putU8(storage, putU8(storage, 0, 12), 0), 0);
	const accounts: InstructionAccount[1] = [InstructionAccount.readonly(self)];
	if (which == 0) {
		return signed(invokeList(programId(), accounts, storage, length), [
			[0], [1], [2], [3], [4], [5], [6], [7], [8], [9], [10], [11], [12], [13], [14], [15],
		]);
	}
	if (which == 1) {
		return signed(invokeList(programId(), accounts, storage, length), [
			[0], [1], [2], [3], [4], [5], [6], [7], [8], [9], [10], [11], [12], [13], [14], [15], [16],
		]);
	}
	return signed(invokeList(programId(), accounts, storage, length), ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]);
}

function unsignedLoop(count: uint64): Result<uint64, ProgramError> {
	for (let index: uint64 = 0; index < count; index++) {
		const self = try account(0);
		let storage: uint8[3] = [];
		const _sent = try invoke(
			programId(),
			[InstructionAccount.readonly(self)],
			storage,
			putU8(storage, putU8(storage, putU8(storage, 0, 12), 0), 0),
		);
	}
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

function rentLoop(count: uint64): Result<uint64, ProgramError> {
	let sum: uint64 = 0;
	for (let index: uint64 = 0; index < count; index++) { sum = sum + minimumBalance(index); }
	logU64(sum);
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

struct Probed {
	amount: uint64;
	owner: Pubkey;
	done: boolean;
}

function clockLoop(count: uint64): Result<uint64, ProgramError> {
	let sum: uint64 = 0;
	for (let index: uint64 = 0; index < count; index++) {
		const now = clock();
		sum = sum + now.slot + now.epoch + now.leaderScheduleEpoch;
		sum = sum + (now.unixTimestamp as uint64) + (now.epochStartTimestamp as uint64);
	}
	logU64(sum);
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

function returnDataLoop(count: uint64): Result<uint64, ProgramError> {
	for (let index: uint64 = 0; index < count; index++) {
		const payload: uint8[4] = [1, 2, 3, (index & 0xff) as uint8];
		setReturnData(payload);
		const found = returnData();
		if (found === null) { return Result.err(ProgramError.invalidAccountData()); }
		if (!found.program.equals(programId()) || found.length != 4) {
			return Result.err(ProgramError.invalidAccountData());
		}
		const word = try found.readU32(0);
		if (word != (0x00030201 | (((index & 0xff) as uint32) << 24))) {
			return Result.err(ProgramError.invalidAccountData());
		}
	}
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

function logKeyLoop(count: uint64): Result<uint64, ProgramError> {
	const key = programId();
	for (let index: uint64 = 0; index < count; index++) { logPubkey(key); }
	logU64(msSolAlloc(0));
	return Result.ok(0);
}

function eventLoop(count: uint64): Result<uint64, ProgramError> {
	const probed: Probed = { amount: 7, owner: programId(), done: true };
	for (let index: uint64 = 0; index < count; index++) { emitEvent<Probed>(probed); }
	logU64(msSolAlloc(0));
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
	if (op == 10) { return signedLoop(count); }
	if (op == 11) { return unsignedLoop(count); }
	if (op == 12) { return Result.ok(0); }
	if (op == 13) { return limitCall(count); }
	if (op == 14) { return rentLoop(count); }
	if (op == 15) { return clockLoop(count); }
	if (op == 16) { return returnDataLoop(count); }
	if (op == 17) { return logKeyLoop(count); }
	if (op == 18) { return eventLoop(count); }
	return request(0 - count);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
