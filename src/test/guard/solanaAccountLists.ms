// GUARD-OS solana
import {
	AccountMeta,
	Bytes,
	Instruction,
	ProgramError,
	Pubkey,
	account,
	failWith,
	instructionData,
	programId,
	signerAccount,
} from "std/solana";
import { scheduleTask } from "std/solana/magicblock";
import { RandomnessRequest, requestRandomness } from "std/solana/vrf";

function key(word: uint64): Pubkey {
	let made = Pubkey.zero();
	made.bytes[0] = (word & 255) as uint8;
	return made;
}

function request(): Result<RandomnessRequest, ProgramError> {
	return Result.ok({
		payer: try signerAccount(0),
		programIdentity: try account(1),
		oracleQueue: try account(2),
		systemProgram: try account(3),
		slotHashes: try account(4),
	});
}

function vrfList(args: Bytes): Result<uint64, ProgramError> {
	const metas: AccountMeta[3] = [
		AccountMeta.writableKey(key(11)),
		AccountMeta.readonlyKey(key(12)),
		AccountMeta.writableKey(key(13)),
	];
	return requestRandomness(try request(), key(99), 6, metas, args);
}

function vrfSingle(args: Bytes): Result<uint64, ProgramError> {
	const callback = try account(6);
	return requestRandomness(try request(), key(99), 6, callback, args);
}

function crankList(args: Bytes): Result<uint64, ProgramError> {
	const payer = try signerAccount(0);
	const task = Instruction.forProgram(programId(), 2, args.length);
	task.addWritable(try account(1));
	task.addReadonly(try account(2));
	task.appendBytes(args);
	return scheduleTask(payer, 7, 400, 3, task);
}

function crankSingle(args: Bytes): Result<uint64, ProgramError> {
	const payer = try signerAccount(0);
	return scheduleTask(payer, 7, 400, 3, try account(1), args, programId());
}

function dispatch(): Result<uint64, ProgramError> {
	const data = instructionData();
	const op = try data.readU8(0);
	const args = try data.range(1, data.length - 1);
	if (op == 0) { return vrfList(args); }
	if (op == 1) { return vrfSingle(args); }
	if (op == 2) { return crankList(args); }
	return crankSingle(args);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
