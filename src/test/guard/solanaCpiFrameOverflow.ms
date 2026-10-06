// GUARD-OS solana
// GUARD-CHECK-FAIL overflows the maximum allowed frame space
// GUARD-CHECK-FAIL compile failed for
// A CPI written at the call builds its accounts in the caller's frame, so a list too long for the
// 4 KB frame (45 accounts beside a one-byte buffer) fails the build, naming the function and its size;
// the 44 that fit build in solanaCpiFrame.ms.
// RED MEANS: a CPI list stopped living in the caller's frame, or the frame check no longer fires.
import { Account, InstructionAccount, ProgramError, account, failWith, invoke, programId, putU8 } from "std/solana";

function send(a: Account): Result<uint64, ProgramError> {
	let storage: uint8[1] = [];
	return invoke(programId(), [
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
	], storage, putU8(storage, 0, 1));
}

function main(): void {
	const first = account(0);
	if (!first.ok) { return; }
	const sent = send(first.value);
	if (!sent.ok) { failWith(sent.error); }
}
main();
