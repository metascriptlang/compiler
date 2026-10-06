// GUARD-OS solana -d:programId=notbase58
// GUARD-CHECK-FAIL the build declares programId 'notbase58' (build.ms `defines` or -d:programId), which is not a base58 public key
// A declared program id that is not a base58 public key stops the build at the instruction table,
// before an entry could compare the runtime's id with garbage.
// RED MEANS: the program builds with a malformed id, and its entry check refuses every call or none.
import { ProgramError, failWith, instruction } from "std/solana";

enum Op { Ping }

function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<Op>()) {
		Op.Ping => Result.ok(0),
	};
}

const result = dispatch();
if (!result.ok) { failWith(result.error); }
