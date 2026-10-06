// GUARD-OS solana
// An overloaded std function that returns a struct builds for SBF as an initializer and as a try
// operand: scheduleTask in both overloads, requestRandomness with a callback list and with one
// account (signed or not), commit and commitAndUndelegate.
// RED MEANS: a call to an overload after the first got the first overload's prototype (clang: too
// many arguments, or an incompatible account argument), so std/solana cannot keep these overloaded.
import {
	AccountMeta,
	InstructionAccount,
	ProgramError,
	account,
	failWith,
	instructionData,
	programId,
	signed,
	signerAccount,
} from "std/solana";
import { commit, commitAndUndelegate, scheduleTask } from "std/solana/magicblock";
import { RandomnessRequest, requestRandomness } from "std/solana/vrf";

function request(): Result<RandomnessRequest, ProgramError> {
	return Result.ok({
		payer: try signerAccount(0),
		programIdentity: try account(1),
		oracleQueue: try account(2),
		systemProgram: try account(3),
		slotHashes: try account(4),
	});
}

function dispatch(): Result<uint64, ProgramError> {
	const op = try instructionData().readU8(0);
	const payer = try signerAccount(0);
	const target = try account(5);
	const args: uint8[2] = [1, 2];
	const task: InstructionAccount[1] = [InstructionAccount.writable(target)];
	const metas: AccountMeta[1] = [AccountMeta.writable(target.key())];
	if (op == 0) {
		const sent = try scheduleTask(payer, 7, 400, 3, target, args, programId());
		return Result.ok(sent);
	}
	if (op == 1) {
		const sent = try scheduleTask(payer, 7, 400, 3, programId(), task, args);
		return Result.ok(sent);
	}
	if (op == 2) {
		const sent = try requestRandomness(try request(), programId(), 6, target, args);
		return Result.ok(sent);
	}
	if (op == 3) {
		const sent = try requestRandomness(try request(), programId(), 6, metas, args);
		return Result.ok(sent);
	}
	if (op == 4) {
		const sent = try signed(requestRandomness(try request(), programId(), 6, target, args), ["payer"]);
		return Result.ok(sent);
	}
	if (op == 5) {
		const sent = try commit(payer, target, try account(6));
		return Result.ok(sent);
	}
	const sent = try commitAndUndelegate(payer, target, try account(6));
	return Result.ok(sent);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
