// GUARD-OS solana
// GUARD-CHECK-FAIL solanaReturnDataOwnsItsBytes.ms:12:
// GUARD-CHECK-FAIL is not assignable to type 'Bytes'
// The return data is a value that owns its 1024 bytes, as the reference's ReturnData does, so it holds no
// address: a Bytes view cannot be taken from it.
// RED MEANS: ReturnData holds a Bytes view into memory the program does not keep alive.
import { Bytes, ProgramError, failWith, returnData } from "std/solana";

function main(): void {
	const found = returnData();
	if (found === null) { return; }
	const view: Bytes = found.data;
	if (view.length == 0) { failWith(ProgramError.invalidArgument()); }
}
main();
