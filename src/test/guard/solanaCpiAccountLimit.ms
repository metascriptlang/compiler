// GUARD-OS solana
// GUARD-CHECK-FAIL solanaCpiAccountLimit.ms:14:
// GUARD-CHECK-FAIL a CPI lists at most 16 accounts here, and the list has 17
// A CPI written at the call lists at most sixteen accounts, the local maximum of the
// ephemeral-rollups SDK's commit; a longer list is invokeList over a run-time list.
// RED MEANS: invoke accepted a list the frame cannot hold, or lost the error that names the limit.
import { InstructionAccount, ProgramError, account, failWith, invoke, programId, putU8 } from "std/solana";

function main(): void {
	const first = account(0);
	if (!first.ok) { return; }
	const a = first.value;
	let storage: uint8[1] = [];
	const sent = invoke(programId(), [
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a), InstructionAccount.writable(a),
		InstructionAccount.writable(a), InstructionAccount.writable(a),
	], storage, putU8(storage, 0, 1));
	if (!sent.ok) { failWith(sent.error); }
}
main();
