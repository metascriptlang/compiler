// GUARD-OS solana
// GUARD-CHECK-FAIL solanaEventWriterGone.ms:7:
// GUARD-CHECK-FAIL has no export 'EventWriter'
// An event is serialized by emitEvent into a stack buffer the core owns: no writer value over a buffer
// is exported, so none can be built, returned or kept by a program.
// RED MEANS: std/solana exports an event writer again.
import { EventWriter, eventWriter } from "std/solana";

function leaked(): EventWriter {
	const discriminator: uint8[8] = [1, 2, 3, 4, 5, 6, 7, 8];
	return eventWriter(16, discriminator).u64(1);
}

function main(): void {
	const writer = leaked();
	writer.finish();
}
main();
