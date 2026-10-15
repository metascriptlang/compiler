// GUARD-OS solana
// GUARD-CHECK-FAIL 'solanaEmptyTopLevelRefused.ms' calls nothing at its top level, so this Solana program would do nothing and report success for every instruction
// GUARD-CHECK-FAIL for example 'when (!testBuild) { entry(); }' at the end of the file
// A program whose only call of its handler sits in a test block builds no handler call into the deployed program.
// RED MEANS: the .so builds, and on chain it answers success to every instruction without running any.
import { ProgramError, failWith, instruction } from "std/solana";

enum Op { Ping }

function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<Op>()) {
		Op.Ping => Result.ok(0),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (testBuild) {
	entry();
}
