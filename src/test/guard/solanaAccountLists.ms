// GUARD-OS solana
import {
	AccountMeta,
	InstructionAccount,
	ProgramError,
	Pubkey,
	account,
	failWith,
	instructionData,
	programId,
	putBytes,
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

function vrfList(args: Readonly<Span<uint8>>): Result<uint64, ProgramError> {
	const metas: AccountMeta[3] = [
		AccountMeta.writable(key(11)),
		AccountMeta.readonly(key(12)),
		AccountMeta.writable(key(13)),
	];
	return requestRandomness(try request(), key(99), 6, metas, args);
}

function crankList(args: Readonly<Span<uint8>>): Result<uint64, ProgramError> {
	const payer = try signerAccount(0);
	const task: InstructionAccount[2] = [
		InstructionAccount.writable(try account(1)),
		InstructionAccount.readonly(try account(2)),
	];
	return scheduleTask(payer, 7, 400, 3, programId(), task, args);
}

function crankSingle(args: Readonly<Span<uint8>>): Result<uint64, ProgramError> {
	const payer = try signerAccount(0);
	return scheduleTask(payer, 7, 400, 3, try account(1), args, programId());
}

function dispatch(): Result<uint64, ProgramError> {
	const data = instructionData();
	const op = try data.readU8(0);
	const tail = try data.range(1, data.length - 1);
	let relay: uint8[64] = [];
	const kept = putBytes(relay, 0, tail) as int32;
	if (op == 0) { return vrfList(relay[0..kept]); }
	if (op == 1) { return crankList(relay[0..kept]); }
	return crankSingle(relay[0..kept]);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
