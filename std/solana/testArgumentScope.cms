import { ScopedKeyArgs } from "./testChainScope";
import { args } from "./macro";
import { ProgramError } from "./error";

export function scopedKeysResult(): Result<uint64, ProgramError> {
	const decoded = try args<ScopedKeyArgs>();
	let checksum: uint64 = 0;
	for (const key of decoded.one) {
		for (const byte of key.bytes) { checksum = checksum + (byte as uint64); }
	}
	for (const key of decoded.two) {
		for (const byte of key.bytes) { checksum = checksum + (byte as uint64); }
	}
	return Result.ok(checksum + (decoded.empty.length as uint64));
}
