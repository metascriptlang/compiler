// cparse — UTF-8 + Unicode helpers
// Port of: ~/projects/chibicc unicode.c
//
// Provides decode/encode for UTF-8, identifier classification per C11 Annex D,
// and universal character name (\uXXXX, \UXXXXXXXX) conversion.

// Decode one UTF-8 code point starting at source[pos].
// Returns [codePoint, bytesConsumed]. On invalid sequence returns [0xFFFD, 1].
export function decodeUtf8(source: string, pos: number): number[] {
	const ch = source.charCodeAt(pos);
	if (ch < 0x80) return [ch, 1];
	if (ch < 0xC0) return [0xFFFD, 1]; // unexpected continuation byte

	let cp: number = 0;
	let len: number = 0;
	if (ch >= 0xF0) { len = 4; cp = ch & 0x07; }
	else if (ch >= 0xE0) { len = 3; cp = ch & 0x0F; }
	else { len = 2; cp = ch & 0x1F; }

	let i = 1;
	while (i < len) {
		if (pos + i >= source.length) return [0xFFFD, 1];
		const b = source.charCodeAt(pos + i);
		if ((b >> 6) !== 2) return [0xFFFD, 1]; // not a continuation byte
		cp = (cp << 6) | (b & 0x3F);
		i = i + 1;
	}
	return [cp, len];
}

// Encode a Unicode code point as a UTF-8 string.
export function encodeUtf8(cp: number): string {
	if (cp <= 0x7F) {
		return String.fromCharCode(cp);
	}
	if (cp <= 0x7FF) {
		return String.fromCharCode(0xC0 | (cp >> 6)) +
			String.fromCharCode(0x80 | (cp & 0x3F));
	}
	if (cp <= 0xFFFF) {
		return String.fromCharCode(0xE0 | (cp >> 12)) +
			String.fromCharCode(0x80 | ((cp >> 6) & 0x3F)) +
			String.fromCharCode(0x80 | (cp & 0x3F));
	}
	return String.fromCharCode(0xF0 | (cp >> 18)) +
		String.fromCharCode(0x80 | ((cp >> 12) & 0x3F)) +
		String.fromCharCode(0x80 | ((cp >> 6) & 0x3F)) +
		String.fromCharCode(0x80 | (cp & 0x3F));
}

// C11 Annex D identifier-start characters (is_ident1 in chibicc).
function inRange(ranges: number[], cp: number): boolean {
	let i = 0;
	while (i < ranges.length) {
		if (cp >= ranges[i] && cp <= ranges[i + 1]) return true;
		i = i + 2;
	}
	return false;
}

const IDENT1_RANGES: number[] = [
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

const IDENT2_EXTRA: number[] = [
	"0".code, "9".code, "$".code, "$".code,
	0x0300, 0x036F, 0x1DC0, 0x1DFF, 0x20D0, 0x20FF, 0xFE20, 0xFE2F,
];

export function isIdent1(cp: number): boolean {
	return inRange(IDENT1_RANGES, cp);
}

export function isIdent2(cp: number): boolean {
	return isIdent1(cp) || inRange(IDENT2_EXTRA, cp);
}

// Read a hex digit, returning its value (0-15). Returns -1 for non-hex.
export function fromHex(ch: number): number {
	if (ch >= "0".code && ch <= "9".code) return ch - "0".code;
	if (ch >= "a".code && ch <= "f".code) return ch - "a".code + 10;
	if (ch >= "A".code && ch <= "F".code) return ch - "A".code + 10;
	return -1;
}

// Read a universal character: 4 hex digits for \u, 8 for \U.
// Returns the code point, or -1 if invalid.
export function readUniversalChar(source: string, pos: number, len: number): number {
	let cp = 0;
	let i = 0;
	while (i < len) {
		if (pos + i >= source.length) return -1;
		const h = fromHex(source.charCodeAt(pos + i));
		if (h < 0) return -1;
		cp = (cp << 4) | h;
		i = i + 1;
	}
	return cp;
}

// Pre-tokenization: replace \uXXXX and \UXXXXXXXX with UTF-8 bytes.
export function convertUniversalChars(source: string): string {
	let result = "";
	let i = 0;
	while (i < source.length) {
		if (source.charAt(i) === "\\" && i + 1 < source.length) {
			if (source.charAt(i + 1) === "u") {
				const cp = readUniversalChar(source, i + 2, 4);
				if (cp >= 0) {
					result = result + encodeUtf8(cp);
					i = i + 6;
					continue;
				}
			} else if (source.charAt(i + 1) === "U") {
				const cp = readUniversalChar(source, i + 2, 8);
				if (cp >= 0) {
					result = result + encodeUtf8(cp);
					i = i + 10;
					continue;
				}
			}
			// Backslash followed by something else: keep both chars
			result = result + source.charAt(i);
			i = i + 1;
			if (i < source.length) {
				result = result + source.charAt(i);
				i = i + 1;
			}
		} else {
			result = result + source.charAt(i);
			i = i + 1;
		}
	}
	return result;
}

// Strip UTF-8 BOM (EF BB BF) if present at start.
export function stripBom(source: string): string {
	if (source.length >= 3 &&
		source.charCodeAt(0) === 0xEF &&
		source.charCodeAt(1) === 0xBB &&
		source.charCodeAt(2) === 0xBF) {
		return source.slice(3, source.length);
	}
	return source;
}

// Canonicalize newlines: \r\n → \n, \r → \n
export function canonicalizeNewline(source: string): string {
	let result = "";
	let i = 0;
	while (i < source.length) {
		if (source.charCodeAt(i) === "\r".code) {
			if (i + 1 < source.length && source.charCodeAt(i + 1) === "\n".code) {
				i = i + 2;
			} else {
				i = i + 1;
			}
			result = result + "\n";
		} else {
			result = result + source.charAt(i);
			i = i + 1;
		}
	}
	return result;
}

// Remove backslash-newline continuations, preserving line count.
export function removeBackslashNewline(source: string): string {
	let result = "";
	let pending = 0;
	let i = 0;
	while (i < source.length) {
		if (source.charCodeAt(i) === "\\".code &&
			i + 1 < source.length &&
			source.charCodeAt(i + 1) === "\n".code) {
			i = i + 2;
			pending = pending + 1;
		} else if (source.charCodeAt(i) === "\n".code) {
			result = result + source.charAt(i);
			i = i + 1;
			while (pending > 0) {
				result = result + "\n";
				pending = pending - 1;
			}
		} else {
			result = result + source.charAt(i);
			i = i + 1;
		}
	}
	while (pending > 0) {
		result = result + "\n";
		pending = pending - 1;
	}
	return result;
}

// === Tests ===

test "decodeUtf8 ASCII" {
	const r = decodeUtf8("A", 0);
	assert r[0] === 65;
	assert r[1] === 1;
}

test "decodeUtf8 2-byte" {
	// \xC3\xA9 = U+00E9 (e-acute)
	const s = "\xC3\xA9";
	const r = decodeUtf8(s, 0);
	assert r[0] === 0xE9;
	assert r[1] === 2;
}

test "isIdent1 underscore" {
	assert isIdent1("_".code) === true;
}

test "isIdent1 digit false" {
	assert isIdent1("0".code) === false;
}

test "isIdent2 digit" {
	assert isIdent2("0".code) === true;
}

test "fromHex valid" {
	assert fromHex("a".code) === 10;
	assert fromHex("F".code) === 15;
	assert fromHex("0".code) === 0;
}

test "fromHex invalid" {
	assert fromHex("g".code) === -1;
}

test "canonicalizeNewline" {
	assert canonicalizeNewline("a\r\nb\rc") === "a\nb\nc";
}

test "removeBackslashNewline" {
	assert removeBackslashNewline("a\\\nb") === "a\nb";
}

test "convertUniversalChars \\u" {
	const s = convertUniversalChars("\\u0041");
	assert s === "A";
}

test "stripBom no bom" {
	assert stripBom("hello") === "hello";
}
