import { assertFmtIdempotent, fmt } from "../roundtrip";

const OBJ = "const o = { alphaAlphaAlpha: 1, betaBetaBeta: 2, gammaGammaGamma: 3, deltaDelta: 4 };\nconst z = 1;\n";

const JSX = "const l = <panel title=\"a fairly long title value\" subtitle=\"another long value\" onClose={handleCloseOfThePanel}>body</panel>;\nconst z = 1;\n";

test "fmt: a statement that breaks across lines gains no blank line on the next pass" {
	assert assertFmtIdempotent(OBJ);
	assert assertFmtIdempotent(JSX);
}

test "fmt: the blank line between statements is kept when the source had one" {
	assert fmt("const o = { a: 1,\n  b: 2 };\n\nconst z = 1;\n").contains("};\n\nconst z");
	assert fmt("const o = { a: 1,\n  b: 2 };\nconst z = 1;\n").contains("};\nconst z");
}
