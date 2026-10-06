import { ProgramError, failWith, instruction } from "std/solana";

enum Op { Ping }

function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<Op>()) {
		Op.Ping => Result.ok(0),
	};
}

const result = dispatch();
if (!result.ok) { failWith(result.error); }
