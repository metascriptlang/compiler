import { ProgramError, failWith, instructionData, logU64 } from "std/solana";

function wide(count: int64, at: int64): void {
	const words = new Array<uint64>(count);
	words[at] = 7;
	logU64(words.length as uint64);
	logU64(words[at]);
}

function narrow(count: int64, at: int64): void {
	const bytes = new Array<uint8>(count);
	bytes[at] = 7;
	logU64(bytes.length as uint64);
	logU64(bytes[at] as uint64);
}

function main(): void {
	const data = instructionData();
	const op = data.readU8(0);
	const count = data.readU64(1);
	const at = data.readU64(9);
	if (!op.ok || !count.ok || !at.ok) { return; }
	failWith(ProgramError.custom(5));
	if (op.value == 0) { wide(count.value as int64, at.value as int64); }
	else { narrow(count.value as int64, at.value as int64); }
}
main();
