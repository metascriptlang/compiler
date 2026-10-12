// GUARD-OS solana
// GUARD-CHECK-FAIL instruction<SignedOp>(): member 'Below' has the value -1
// GUARD-CHECK-FAIL instruction<TwinOp>(): members 'Open' and 'Shut' have the same value 1
// instruction<Op>() selects a member by its value and carries a failure as a negative number, so a
// negative member would be returned as an error code; two members of one value are one member to
// the match that reads the result.
// RED MEANS: instruction<Op>() compiled an enum whose member is reported as a failure, or whose
// two members reach the same match arm.
import { ProgramError, failWith, instruction } from "std/solana";

export enum SignedOp { Below = -1, Zero = 0 }
export enum TwinOp { Open = 1, Shut = 1 }

function bySign(): Result<uint64, ProgramError> {
	const op = try instruction<SignedOp>();
	return Result.ok(op == SignedOp.Zero ? 0 : 1);
}

function byTwin(): Result<uint64, ProgramError> {
	const op = try instruction<TwinOp>();
	return Result.ok(op == TwinOp.Open ? 0 : 1);
}

function main(): void {
	const first = bySign();
	if (!first.ok) { failWith(first.error); }
	const second = byTwin();
	if (!second.ok) { failWith(second.error); }
}

main();
