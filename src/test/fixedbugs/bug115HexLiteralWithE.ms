// bug115 — hex literal containing 'e'/'E' inferred as float64
//
// Symptom:    `0xe0 | 1` failed with "bitwise operator '|' requires integer
//             type, got 'float64'" while `0x80 | 1` compiled fine — any hex
//             literal whose digits contain e or E (0xe0, 0xE0, 0xbeef, 0xffee)
//             was classified float; a-f minus e (0xb0, 0xff) were not.
// Root cause: the NumberLiteral isFloat heuristic in the parser
//             (expressions/core.ms, match.ms, util.ms) tested the raw token
//             text for '.'/'e'/'E' without accounting for the 0x prefix, so
//             the hex digit 'e' read as a decimal exponent marker.
// Fix:        numericLiteralIsFloat() in utils/string.ms is prefix-aware and
//             all three parser sites now use it.

test "bug115: hex literal with e is an integer" {
	const a = 0xe0 | 1;
	assert a == 225;
	const b = 0xE0 | 1;
	assert b == 225;
	const c = 0xbeef & 0xffff;
	assert c == 48879;
	const d: int32 = 0xffee;
	assert d == 65518;
	assert 0xe0 == 224;
	assert 0xE1 == 225;
}
