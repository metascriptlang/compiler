import { asBytes, wellFormedString } from "std/core/string/bytes";
import { utf8StepAt } from "std/core/string/utf8Repair";
import {
	LOWER_SIMPLE,
	UPPER_SIMPLE,
	LOWER_FULL,
	UPPER_FULL,
	CASED_RANGES,
	CASE_IGNORABLE_RANGES,
} from "./unicodeCaseData";

function rowAt(
	data: Readonly<Span<int32>>, width: int32, code: int32,
): int32 {
	let low: int32 = 0;
	let high = (data.length as int32) / width;
	while (low < high) {
		const middle = low + (high - low) / 2;
		if (data[middle * width] <= code) { low = middle + 1; }
		else { high = middle; }
	}
	return low == 0 ? -1 : (low - 1) * width;
}

function inProperty(data: Readonly<Span<int32>>, code: int32): boolean {
	const at = rowAt(data, 3, code);
	return at >= 0 && code <= data[at + 1] &&
		(code - data[at]) % data[at + 2] == 0;
}

function scalar(data: Readonly<Span<uint8>>, at: int64, width: int64): int32 {
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

function fullMapping(
	data: Readonly<Span<int32>>, code: int32, out: uint8[],
): boolean {
	const at = rowAt(data, 5, code);
	if (at < 0 || data[at] != code) { return false; }
	for (let i: int32 = 0; i < data[at + 1]; i += 1) {
		appendScalar(out, data[at + 2 + i]);
	}
	return true;
}

function simpleMapping(data: Readonly<Span<int32>>, code: int32): int32 {
	const at = rowAt(data, 4, code);
	if (at < 0 || code > data[at + 1] ||
		(code - data[at]) % data[at + 2] != 0) { return code; }
	return code + data[at + 3];
}

function casedAfter(data: Readonly<Span<uint8>>, start: int64): boolean {
	let at = start;
	while (at < data.length) {
		const width = utf8StepAt(data, at, true);
		if (width < 0) { return false; }
		const code = scalar(data, at, width);
		at += width;
		if (!inProperty(CASE_IGNORABLE_RANGES, code)) {
			return inProperty(CASED_RANGES, code);
		}
	}
	return false;
}

function asciiCase(text: string, upper: boolean): string {
	const data = text.asBytes();
	let changed = false;
	for (const byte of data) {
		if (upper ? byte >= 97 && byte <= 122 : byte >= 65 && byte <= 90) {
			changed = true;
		}
	}
	if (!changed) { return text; }
	const out: uint8[] = [];
	for (const byte of data) {
		const mapped = upper
			? (byte >= 97 && byte <= 122 ? (byte as int32) - 32 : byte as int32)
			: (byte >= 65 && byte <= 90 ? (byte as int32) + 32 : byte as int32);
		out.push(mapped as uint8);
	}
	return wellFormedString(out);
}

function convert(text: string, upper: boolean): string {
	const data = text.asBytes();
	let ascii = true;
	for (const byte of data) {
		if (byte >= 128) { ascii = false; break; }
	}
	if (ascii) { return asciiCase(text, upper); }
	const out: uint8[] = [];
	let before = false;
	let at: int64 = 0;
	while (at < data.length) {
		const width = utf8StepAt(data, at, true);
		if (width < 0) {
			throw new Error("case conversion requires well-formed WTF-8");
		}
		const code = scalar(data, at, width);
		if (!upper && code == 0x3a3 && before &&
			!casedAfter(data, at + width)) {
			appendScalar(out, 0x3c2);
		} else {
			const expanded = upper
				? fullMapping(UPPER_FULL, code, out)
				: fullMapping(LOWER_FULL, code, out);
			if (!expanded) {
				const mapped = upper ? simpleMapping(UPPER_SIMPLE, code) :
					simpleMapping(LOWER_SIMPLE, code);
				if (mapped == code) {
					for (let i: int64 = 0; i < width; i += 1) {
						out.push(data[at + i]);
					}
				} else { appendScalar(out, mapped); }
			}
		}
		if (!upper && !inProperty(CASE_IGNORABLE_RANGES, code)) {
			before = inProperty(CASED_RANGES, code);
		}
		at += width;
	}
	return wellFormedString(out);
}

export function unicodeLower(text: string): string {
	return convert(text, false);
}

export function unicodeUpper(text: string): string {
	return convert(text, true);
}
