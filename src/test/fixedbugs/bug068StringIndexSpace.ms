// bug068 — TS-tier string ops must be UTF-16 code-unit indexed (both backends)
//
// Symptom:    On non-ASCII strings the TS-named surface fell out of the
//             LANG.md "Index-Space Contract" (TypeScript semantics):
//             C: padStart/padEnd counted the TARGET in bytes ("héxlo"
//             .padStart(6,".") returned unpadded — byteLength 6 >= 6);
//             charAt/s[i] on an astral half returned the WHOLE 4-byte glyph;
//             slice with a boundary inside a surrogate pair returned EMPTY
//             (the unit-position walk could never match mid-pair).
//             JS: length/indexOf/lastIndexOf/padStart ran in BYTE space and
//             charAt on an astral half emitted NaN bytes (fromJSStr re-encoded
//             a lone surrogate through the pair branch).
//
// Root cause: One UTF-8 byte buffer, two index spaces, no contract. The C
//             runtime was unit-indexed except padStart/PadEnd (byte targets)
//             and half-splitting ops; the JS std mixed native delegation
//             (unit space) with byte loops (byte space) per function.
//
// Fix:        runtime/core/string.c — msWtf8EncodeSurrogate; msStringCharAt
//             exact half; msStringSlice unit-space walk with half inclusion;
//             msStringPadStart/PadEnd via msStringLength + msPadEmitUnits.
//             index.jms — native delegation for indexOf/lastIndexOf/pad*,
//             fromJSStr lone-surrogate WTF-8 fallback, msStringLength;
//             transform/coercion/stringLengthJS.ms (jsBackend) — `.length`
//             on String → msStringLength, non-range s[i] → charAt.
//
// Oracle: neon probe/stringSpecOracle.ms — 45 rows vs node, both backends.
// Lone surrogate halves are asserted via charCodeAt (numeric), never via
// printed text: node writes them as U+FFFD, C writes raw WTF-8.

test "bug068: length is UTF-16 code units" {
	assert "axbxc".length == 5;
	assert "héxlo".length == 5;
	assert "a—xb".length == 4;
	assert "日本語x".length == 4;
	assert "👍x".length == 3;
}

test "bug068: indexOf/lastIndexOf are unit-indexed" {
	assert "héxlo".indexOf("x") == 2;
	assert "a—xb".indexOf("x") == 2;
	assert "日本語x".indexOf("x") == 3;
	assert "👍x".indexOf("x") == 2;
	assert "a—xb".lastIndexOf("x") == 2;
}

test "bug068: padStart/padEnd targets are unit counts" {
	assert "héxlo".padStart(6, ".") == ".héxlo";
	assert "a—xb".padStart(6, ".") == "..a—xb";
	assert "日本語x".padEnd(6, ".") == "日本語x..";
	assert "👍x".padStart(6, ".") == "...👍x";
}

test "bug068: charAt and s[i] return the exact astral half" {
	assert "👍x".charAt(1).charCodeAt(0) == 56320 + 77;
	assert "👍x"[1].charCodeAt(0) == 56320 + 77;
	assert "👍x".charAt(0).charCodeAt(0) == 55296 + 61;
	assert "héxlo"[1] == "é";
}

test "bug068: slice keeps the half at a mid-pair boundary" {
	const cut = "👍x".slice(1, 3);
	assert cut.charCodeAt(0) == 56320 + 77;
	assert cut.charCodeAt(1) == 120;
	assert "👍x".slice(0, 1).charCodeAt(0) == 55296 + 61;
}
