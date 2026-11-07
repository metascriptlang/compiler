// A string's JSON text appended to the output, one byte at a time, on every backend.

function hexDigit(n: number): string {
	if (n < 10) return fromCodePoint("0".code + n);
	return fromCodePoint("a".code + n - 10);
}

// A surrogate code point encodes as ED A0..BF xx in WTF-8; well-formed UTF-8
// never produces that pair, so this signature identifies exactly the code
// points that have no valid UTF-8 encoding and must leave as \uXXXX escapes.
const WTF8_SURROGATE_LEAD: int32 = 237;

function isWtf8SurrogateCont(b: int32): boolean {
	return b >= 160 && b <= 191;
}

export function appendEscapedPortable(ref result: string, s: string): void {
	result += "\"";
	const b = s.asBytes();
	let i = 0;
	const len = b.length;
	// Walk byte-by-byte; every escape-relevant byte is ASCII. Plain content
	// (including multi-byte UTF-8) is copied in RUNS — runs only break at
	// ASCII escape bytes so slices stay on char boundaries and multi-byte
	// sequences are never split.
	let runStart = 0;
	while (i < len) {
		const ch = b[i] as int32;
		if (ch == WTF8_SURROGATE_LEAD && i + 2 < len && isWtf8SurrogateCont(b[i + 1] as int32)) {
			if (runStart < i) result += s.byteSlice(runStart, i);
			const cp = ((ch & 15) << 12) | (((b[i + 1] as int32) & 63) << 6) | ((b[i + 2] as int32) & 63);
			result += "\\u" + hexDigit((cp >> 12) & 15) + hexDigit((cp >> 8) & 15)
				+ hexDigit((cp >> 4) & 15) + hexDigit(cp & 15);
			i = i + 3;
			runStart = i;
			continue;
		}
		if (ch == "\"".code || ch == "\\".code || ch < 32) {
			if (runStart < i) result += s.byteSlice(runStart, i);
			result += match (ch) {
				"\"".code => "\\\"",
				"\\".code => "\\\\",
				"\n".code => "\\n",
				"\r".code => "\\r",
				"\t".code => "\\t",
				8 => "\\b",
				12 => "\\f",
				_ => "\\u00" + hexDigit((ch >> 4) & 15) + hexDigit(ch & 15),
			};
			runStart = i + 1;
		}
		i = i + 1;
	}
	if (runStart == 0) result += s;
	else if (runStart < len) result += s.byteSlice(runStart, len);
	result += "\"";
}
