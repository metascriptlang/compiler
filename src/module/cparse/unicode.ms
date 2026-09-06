// cparse — UTF-8 + Unicode helpers
//
// All functions use byteAt/byteLength for O(1) byte-level access.
// MS strings store UTF-8 bytes internally — byteAt gives raw bytes.

// Decode one UTF-8 code point starting at byte position `pos`.
// Returns [codePoint, bytesConsumed]. Invalid sequence → [0xFFFD, 1].
export function decodeUtf8(source: string, pos: int32): int32[] {
	const ch = source.byteAt(pos);
	if (ch < 0) return [0xFFFD, 1]; // out of range
	if (ch < 0x80) return [ch, 1];
	if (ch < 0xC0) return [0xFFFD, 1]; // unexpected continuation

	let cp: int32 = 0;
	let len: int32 = 0;
	if (ch >= 0xF0) { len = 4; cp = ch & 0x07; }
	else if (ch >= 0xE0) { len = 3; cp = ch & 0x0F; }
	else { len = 2; cp = ch & 0x1F; }

	let i = 1;
	while (i < len) {
		const b = source.byteAt(pos + i);
		if (b < 0 || (b >> 6) != 2) return [0xFFFD, 1];
		cp = (cp << 6) | ((b as int32) & 0x3F);
		i = i + 1;
	}
	return [cp, len];
}

// C11 Annex D identifier-start characters.
function inRange(ranges: int32[], cp: int32): boolean {
	let i = 0;
	while (i < ranges.length) {
		if (cp >= ranges[i] && cp <= ranges[i + 1]) return true;
		i = i + 2;
	}
	return false;
}

const IDENT1_RANGES: int32[] = [
	"_".code, "_".code, "a".code, "z".code, "A".code, "Z".code, "$".code, "$".code,
	0x00A8, 0x00A8, 0x00AA, 0x00AA, 0x00AD, 0x00AD, 0x00AF, 0x00AF,
	0x00B2, 0x00B5, 0x00B7, 0x00BA, 0x00BC, 0x00BE, 0x00C0, 0x00D6,
	0x00D8, 0x00F6, 0x00F8, 0x00FF, 0x0100, 0x02FF, 0x0370, 0x167F,
	0x1681, 0x180D, 0x180F, 0x1DBF, 0x1E00, 0x1FFF, 0x200B, 0x200D,
	0x202A, 0x202E, 0x203F, 0x2040, 0x2054, 0x2054, 0x2060, 0x206F,
	0x2070, 0x20CF, 0x2100, 0x218F, 0x2460, 0x24FF, 0x2776, 0x2793,
	0x2C00, 0x2DFF, 0x2E80, 0x2FFF, 0x3004, 0x3007, 0x3021, 0x302F,
	0x3031, 0x303F, 0x3040, 0xD7FF, 0xF900, 0xFD3D, 0xFD40, 0xFDCF,
	0xFDF0, 0xFE1F, 0xFE30, 0xFE44, 0xFE47, 0xFFFD,
	0x10000, 0x1FFFD, 0x20000, 0x2FFFD, 0x30000, 0x3FFFD, 0x40000, 0x4FFFD,
	0x50000, 0x5FFFD, 0x60000, 0x6FFFD, 0x70000, 0x7FFFD, 0x80000, 0x8FFFD,
	0x90000, 0x9FFFD, 0xA0000, 0xAFFFD, 0xB0000, 0xBFFFD, 0xC0000, 0xCFFFD,
	0xD0000, 0xDFFFD, 0xE0000, 0xEFFFD,
];

const IDENT2_EXTRA: int32[] = [
	"0".code, "9".code, "$".code, "$".code,
	0x0300, 0x036F, 0x1DC0, 0x1DFF, 0x20D0, 0x20FF, 0xFE20, 0xFE2F,
];

export function isIdent1(cp: int32): boolean {
	return inRange(IDENT1_RANGES, cp);
}

export function isIdent2(cp: int32): boolean {
	return isIdent1(cp) || inRange(IDENT2_EXTRA, cp);
}

// Hex digit value (0-15). Returns -1 for non-hex.
export function fromHex(ch: int32): int32 {
	if (ch >= "0".code && ch <= "9".code) return ch - "0".code;
	if (ch >= "a".code && ch <= "f".code) return ch - "a".code + 10;
	if (ch >= "A".code && ch <= "F".code) return ch - "A".code + 10;
	return -1;
}

// Read a universal character: 4 hex digits for \u, 8 for \U. Returns -1 if invalid.
export function readUniversalChar(source: string, pos: int32, len: int32): int32 {
	let cp: int32 = 0;
	let i = 0;
	while (i < len) {
		const h = fromHex(source.byteAt(pos + i));
		if (h < 0) return -1;
		cp = (cp << 4) | (h as int32);
		i = i + 1;
	}
	return cp;
}

// Strip UTF-8 BOM (EF BB BF) if present at start.
export function stripBom(source: string): string {
	if (source.byteLength >= 3 &&
		source.byteAt(0) == 0xEF &&
		source.byteAt(1) == 0xBB &&
		source.byteAt(2) == 0xBF) {
		return source.byteSlice(3, source.byteLength);
	}
	return source;
}

// Canonicalize newlines: \r\n -> \n, \r -> \n.
export function canonicalizeNewline(source: string): string {
	let parts: string[] = [];
	let start = 0;
	let i = 0;
	const len = source.byteLength;
	while (i < len) {
		const ch = source.byteAt(i);
		if (ch == "\r".code) {
			parts.push(source.byteSlice(start, i));
			parts.push("\n");
			if (i + 1 < len && source.byteAt(i + 1) == "\n".code) {
				i = i + 2;
			} else {
				i = i + 1;
			}
			start = i;
		} else {
			i = i + 1;
		}
	}
	if (start == 0) return source; // no \r found — return original
	parts.push(source.byteSlice(start, len));
	let result = "";
	for (const p of parts) result = result + p;
	return result;
}

// Remove backslash-newline continuations, preserving line count.
export function removeBackslashNewline(source: string): string {
	let parts: string[] = [];
	let start = 0;
	let pending = 0;
	let i = 0;
	const len = source.byteLength;
	while (i < len) {
		if (source.byteAt(i) == "\\".code && i + 1 < len && source.byteAt(i + 1) == "\n".code) {
			parts.push(source.byteSlice(start, i));
			i = i + 2;
			pending = pending + 1;
			start = i;
		} else if (source.byteAt(i) == "\n".code) {
			i = i + 1;
			// Emit pending blank lines after this real newline
			if (pending > 0) {
				parts.push(source.byteSlice(start, i));
				while (pending > 0) {
					parts.push("\n");
					pending = pending - 1;
				}
				start = i;
			}
		} else {
			i = i + 1;
		}
	}
	if (start == 0 && pending == 0) return source;
	parts.push(source.byteSlice(start, len));
	while (pending > 0) {
		parts.push("\n");
		pending = pending - 1;
	}
	let result = "";
	for (const p of parts) result = result + p;
	return result;
}

// Replace \uXXXX and \UXXXXXXXX with corresponding UTF-8 bytes.
export function convertUniversalChars(source: string): string {
	let parts: string[] = [];
	let start = 0;
	let i = 0;
	const len = source.byteLength;
	while (i < len) {
		if (source.byteAt(i) == "\\".code && i + 1 < len) {
			const next = source.byteAt(i + 1);
			if (next == "u".code) {
				const cp = readUniversalChar(source, i + 2, 4);
				if (cp >= 0) {
					parts.push(source.byteSlice(start, i));
					parts.push(fromCodePoint(cp));
					i = i + 6;
					start = i;
					continue;
				}
			} else if (next == "U".code) {
				const cp = readUniversalChar(source, i + 2, 8);
				if (cp >= 0) {
					parts.push(source.byteSlice(start, i));
					if (cp <= 0xFFFF) {
						parts.push(fromCodePoint(cp));
					} else {
						// Supplementary plane — encode as surrogate pair for JS/MS string
						const hi: int32 = 0xD800 + ((cp - 0x10000 as int32) >> 10);
						const lo: int32 = 0xDC00 + ((cp - 0x10000 as int32) & 0x3FF);
						parts.push(fromCodePoint(hi));
						parts.push(fromCodePoint(lo));
					}
					i = i + 10;
					start = i;
					continue;
				}
			}
			// Not a valid UCN — skip the backslash + next byte
			i = i + 2;
		} else {
			i = i + 1;
		}
	}
	if (start == 0) return source;
	parts.push(source.byteSlice(start, len));
	let result = "";
	for (const p of parts) result = result + p;
	return result;
}

// === Tests ===

test "decodeUtf8 ASCII" {
	const r = decodeUtf8("A", 0);
	assert r[0] == 65;
	assert r[1] == 1;
}

test "isIdent1 underscore" {
	assert isIdent1("_".code) == true;
}

test "isIdent1 digit false" {
	assert isIdent1("0".code) == false;
}

test "isIdent2 digit" {
	assert isIdent2("0".code) == true;
}

test "fromHex valid" {
	assert fromHex("a".code) == 10;
	assert fromHex("F".code) == 15;
	assert fromHex("0".code) == 0;
}

test "fromHex invalid" {
	assert fromHex("g".code) == -1;
}

test "canonicalizeNewline" {
	assert canonicalizeNewline("a\r\nb\rc") == "a\nb\nc";
}

test "canonicalizeNewline no change" {
	assert canonicalizeNewline("abc\ndef") == "abc\ndef";
}

test "removeBackslashNewline" {
	// "a\<newline>b" → backslash-newline removed → "ab" + trailing compensating \n
	assert removeBackslashNewline("a\\\nb") == "ab\n";
}

test "removeBackslashNewline no change" {
	assert removeBackslashNewline("abc") == "abc";
}

test "convertUniversalChars \\u" {
	const s = convertUniversalChars("\\u0041");
	assert s == "A";
}

test "stripBom no bom" {
	assert stripBom("hello") == "hello";
}
