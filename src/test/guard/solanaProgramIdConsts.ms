// GUARD-OS solana
// The well-known program ids are module consts initialized by a @comptime call
// (Nim `evalAtCompileTime` on an `sfCompileTime` callee, NIM-REF CT-32): imported
// from std/solana they compare in the entry, serve as a CPI's program argument and
// are read through `P.id()` in a generic, and no writable global reaches the SBF link.
// RED MEANS: an id const stopped folding under --os=solana (E02) or std went back to
// a function that is not folded at the use.
import {
	CLOCK_ID,
	InstructionAccount,
	Pubkey,
	SYSTEM_PROGRAM_ID,
	TOKEN_PROGRAM_ID,
	Token,
	account,
	instructionData,
	invoke,
	logU64,
} from "std/solana";

function isProgram<P>(key: Pubkey): boolean {
	return key == P.id();
}

function main(): void {
	const found = account(0);
	if (!found.ok) { return; }
	const key = found.value.key();
	let storage: uint8[4] = [];
	logU64(instructionData().length);
	if (key == TOKEN_PROGRAM_ID || key == CLOCK_ID || key == SYSTEM_PROGRAM_ID) { logU64(1); }
	if (isProgram<Token>(key)) { logU64(2); }
	const sent = invoke(TOKEN_PROGRAM_ID, [InstructionAccount.writable(found.value)], storage, 4);
	if (sent.ok) { logU64(3); }
}
main();
