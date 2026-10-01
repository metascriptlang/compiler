import {
	ProgramError,
	failWith,
	instructionData,
	programId,
	writableAccount,
} from "std/solana";
import { Counter, increment } from "./rules";

function execute(): Result<uint64, ProgramError> {
	const target = try writableAccount(0);
	if (!target.isOwnedBy(programId())) {
		return Result.err(ProgramError.invalidAccountOwner());
	}
	if (!target.isSigner()) {
		return Result.err(ProgramError.missingRequiredSignature());
	}
	const data = target.data();
	if (data.length != 8) {
		return Result.err(ProgramError.invalidAccountData());
	}
	const instruction = instructionData();
	if (instruction.length != 8) {
		return Result.err(ProgramError.invalidInstructionData());
	}
	const amount = try instruction.readU64(0);
	let counter: Counter = { value: try data.readU64(0) };
	const changed = counter.increment(amount);
	if (!changed.ok) {
		return Result.err(ProgramError.custom(1000 + (changed.error as uint32)));
	}
	const written = try data.writeU64(0, counter.value);
	return Result.ok(changed.value);
}

function run(): void {
	const result = execute();
	if (!result.ok) { failWith(result.error); }
}

run();
