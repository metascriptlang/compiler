// GUARD-OS solana
import {
	ProgramError,
	account,
	failWith,
	instructionData,
	invoke,
	logU64,
	programId,
	putU8,
	returnData,
	setReturnData,
} from "std/solana";

function answer(): Result<uint64, ProgramError> {
	const payload: uint8[3] = [7, 8, 9];
	setReturnData(payload);
	return Result.ok(0);
}

function ask(): Result<uint64, ProgramError> {
	if (returnData() !== null) { return Result.err(ProgramError.invalidAccountData()); }
	const _self = try account(1);
	let storage: uint8[1] = [];
	const _invoked = try invoke(programId(), [], storage, putU8(storage, 0, 1));
	const answered = returnData();
	if (answered === null) { return Result.err(ProgramError.invalidAccountData()); }
	if (!answered.program.equals(programId())) { return Result.err(ProgramError.incorrectProgramId()); }
	logU64(answered.length);
	logU64(try answered.readU8(2));
	return Result.ok(0);
}

function dispatch(): Result<uint64, ProgramError> {
	const op = try instructionData().readU8(0);
	if (op == 1) { return answer(); }
	return ask();
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
