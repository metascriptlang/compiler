// GUARD-OS solana
// GUARD-CHECK-FAIL must be the last field
import { Bytes, ProgramError, failWith, readArgs } from "std/solana";
import { args } from "std/solana/macro";

struct UploadArgs {
	chunk: Bytes;
	index: uint16;
}

function upload(): Result<uint64, ProgramError> {
	const read = try args<UploadArgs>();
	return Result.ok(read.index as uint64);
}

function main(): void {
	const result = upload();
	if (!result.ok) { failWith(result.error); }
}

main();
