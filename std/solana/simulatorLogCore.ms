const BASE58_ALPHABET: string = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const BASE64_ALPHABET: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const HEX_DIGITS: string = "0123456789abcdef";
const SMALLEST_BY_EXTRA: uint32[] = [0, 0x80, 0x800, 0x10000];

export const LOG_BUDGET: uint64 = 10000;
export const TRUNCATED_LINE: string = "Log truncated";
export const OPENING_LINE_BYTES: uint64 = 19;

export interface LogBook {
	lines: string[];
	bytes: uint64;
	truncated: boolean;
}

export function newLogBook(): LogBook {
	return { lines: [], bytes: 0, truncated: false };
}

// host.c msSolHostBase58
export function base58(key: Readonly<Span<uint8>>): string {
	const digits: uint8[] = [];
	for (let index = 0; index < key.length; index++) {
		let carry: uint32 = key[index] as uint32;
		for (let digit = 0; digit < digits.length; digit++) {
			carry += (digits[digit] as uint32) << 8;
			digits[digit] = (carry % 58) as uint8;
			carry = carry / 58;
		}
		while (carry > 0) {
			digits.push((carry % 58) as uint8);
			carry = carry / 58;
		}
	}
	let text = "";
	for (let index = 0; index < key.length && key[index] == 0; index++) { text += "1"; }
	for (let digit = digits.length - 1; digit >= 0; digit--) { text += BASE58_ALPHABET[digits[digit]]; }
	return text;
}

// host.c msSolHostLogData
export function base64(bytes: Readonly<Span<uint8>>): string {
	let text = "";
	for (let index = 0; index < bytes.length; index += 3) {
		let group: uint32 = (bytes[index] as uint32) << 16;
		if (index + 1 < bytes.length) { group |= (bytes[index + 1] as uint32) << 8; }
		if (index + 2 < bytes.length) { group |= bytes[index + 2] as uint32; }
		text += BASE64_ALPHABET[(group >> 18) & 63];
		text += BASE64_ALPHABET[(group >> 12) & 63];
		text += index + 1 < bytes.length ? BASE64_ALPHABET[(group >> 6) & 63] : "=";
		text += index + 2 < bytes.length ? BASE64_ALPHABET[group & 63] : "=";
	}
	return text;
}

// host.c msSolHostLog64 prints each word as %llx
export function hex(value: uint64): string {
	if (value == 0) { return "0"; }
	let text = "";
	let rest = value;
	while (rest != 0) {
		text = HEX_DIGITS[(rest & 15) as int32] + text;
		rest = rest >> 4;
	}
	return text;
}

export function words(a: uint64, b: uint64, c: uint64, d: uint64, e: uint64): string {
	return `Program log: 0x${hex(a)}, 0x${hex(b)}, 0x${hex(c)}, 0x${hex(d)}, 0x${hex(e)}`;
}

// host.c msSolHostIsUtf8
export function isUtf8(bytes: Readonly<Span<uint8>>): boolean {
	let at: uint32 = 0;
	while (at < (bytes.length as uint32)) {
		const lead = bytes[at] as uint32;
		let extra: uint32 = 4;
		if (lead < 0x80) { extra = 0; }
		else if ((lead & 0xe0) == 0xc0) { extra = 1; }
		else if ((lead & 0xf0) == 0xe0) { extra = 2; }
		else if ((lead & 0xf8) == 0xf0) { extra = 3; }
		if (extra == 4 || extra >= (bytes.length as uint32) - at) { return false; }
		let point: uint32 = extra == 0 ? lead : lead & (0x3f >> extra);
		for (let index: uint32 = 1; index <= extra; index++) {
			const next = bytes[at + index] as uint32;
			if ((next & 0xc0) != 0x80) { return false; }
			point = (point << 6) | (next & 0x3f);
		}
		if (point < SMALLEST_BY_EXTRA[extra] || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) { return false; }
		at += extra + 1;
	}
	return true;
}

// host.c msSolHostRecordLog; `size` is the line's UTF-8 byte count, which the budget counts
export function recordLine(book: LogBook, line: string, size: uint64): void {
	if (book.bytes + size >= LOG_BUDGET) {
		if (book.truncated) { return; }
		book.truncated = true;
		book.lines.push(TRUNCATED_LINE);
		return;
	}
	book.bytes += size;
	book.lines.push(line);
}
