import { ProgramError, failWith, instructionData } from "std/solana";

function main(): void {
	const op = instructionData().readU8(0);
	if (!op.ok) { return; }
	if (op.value == 0) {
		failWith(ProgramError.custom(5));
		failWith(ProgramError.custom(6));
	}
	if (op.value == 1) { failWith(ProgramError.custom(6)); }
}
main();
