import { wellFormedString } from "std/core/string/bytes";
import { utf8StepAt } from "std/core/string/utf8Repair";
import { FOLD_CODES, FOLD_OFFSETS, FOLD_VALUES } from "./fileCaseFoldData";

function mappingAt(code: int32): int32 {
	let low: int32 = 0;
	let high = FOLD_CODES.length as int32;
	while (low < high) {
		const middle = low + (high - low) / 2;
		if (FOLD_CODES[middle] < code) { low = middle + 1; }
		else { high = middle; }
	}
	return low < FOLD_CODES.length && FOLD_CODES[low] == code ? low : -1;
}

function scalar(
	data: Readonly<Span<uint8>>, at: int64, width: int64,
): int32 {
	if (width == 1) { return data[at] as int32; }
	const mask: int32 = width == 2 ? 31 : width == 3 ? 15 : 7;
	let code = (data[at] as int32) & mask;
	for (let i: int64 = 1; i < width; i += 1) {
		code = (code << 6) | ((data[at + i] as int32) & 63);
	}
	return code;
}

function appendScalar(out: uint8[], code: int32): void {
	if (code < 0x80) {
		out.push(code as uint8);
	} else if (code < 0x800) {
		out.push((0xc0 | (code >> 6)) as uint8);
		out.push((0x80 | (code & 63)) as uint8);
	} else if (code < 0x10000) {
		out.push((0xe0 | (code >> 12)) as uint8);
		out.push((0x80 | ((code >> 6) & 63)) as uint8);
		out.push((0x80 | (code & 63)) as uint8);
	} else {
		out.push((0xf0 | (code >> 18)) as uint8);
		out.push((0x80 | ((code >> 12) & 63)) as uint8);
		out.push((0x80 | ((code >> 6) & 63)) as uint8);
		out.push((0x80 | (code & 63)) as uint8);
	}
}

export function foldFileName(text: string): Result<string, string> {
	const bytes = text.asBytes();
	const out: uint8[] = [];
	let at: int64 = 0;
	while (at < bytes.length) {
		const width = utf8StepAt(bytes, at, true);
		if (width < 0) {
			return Result.err("file casefold requires well-formed WTF-8");
		}
		const code = scalar(bytes, at, width);
		const found = mappingAt(code);
		if (found < 0) {
			for (let i: int64 = 0; i < width; i += 1) {
				out.push(bytes[at + i]);
			}
		} else {
			for (let i = FOLD_OFFSETS[found]; i < FOLD_OFFSETS[found + 1];
				i += 1) {
				appendScalar(out, FOLD_VALUES[i]);
			}
		}
		at += width;
	}
	return Result.ok(wellFormedString(out));
}
