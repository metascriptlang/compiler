import { readFileBytes } from "std/fs";
import { wellFormedString } from "std/core/string/bytes";
import { wellFormedPrefix } from "std/core/string/utf8Repair";

export function readUtf8File(path: string): Result<string, string> {
	const read = readFileBytes(path);
	if (!read.ok) {
		return Result.err("cannot read " + path + ": " + read.error.message);
	}
	const data: Readonly<Span<uint8>> = read.value;
	if (wellFormedPrefix(data, 0, false) != data.length) {
		return Result.err("not UTF-8: " + path);
	}
	return Result.ok(wellFormedString(data));
}
