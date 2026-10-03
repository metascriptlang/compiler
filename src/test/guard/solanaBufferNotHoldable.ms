// GUARD-OS solana
// GUARD-CHECK-FAIL solanaBufferNotHoldable.ms:7:
// GUARD-CHECK-FAIL has no export 'BorshBuffer'
// Instruction bytes are written by functions over a stack array and an offset, so no value an author can
// return or store holds the address of that array; a writer value over the frame is not expressible.
// RED MEANS: std/solana exports a writer that can outlive the array it points into.
import { BorshBuffer, borshBuffer } from "std/solana";

function leaked(): BorshBuffer {
	let storage: uint8[8] = [];
	return borshBuffer(storage).u8(1);
}

function main(): void {
	leaked().written();
}
main();
