import { assertFmtLossless, assertFmtIdempotent, fmt } from "../roundtrip";

const union = "export type DocData =\n\t| { text: string }        // Text\n\t// Literal variants\n\t| { lines: string[] };\n";

test "fmt: comments between union members of a type alias stay in place" {
	assert assertFmtLossless(union);
}

test "fmt: comments between union members of a type alias are stable" {
	assert assertFmtIdempotent(union);
}

test "fmt: a union alias with comments between its members is formatted around them" {
	assert fmt(union) == "export type DocData =\n\t| { text: string } // Text\n\t// Literal variants\n\t| { lines: string[] };\n", fmt(union);
	const blocks = "type   Pair = /* left */ int32|/* right */ string;\n";
	assert fmt(blocks) == "type Pair = /* left */ int32 | /* right */ string;\n", fmt(blocks);
	const ownLines = "type Shape =\n  // a circle\n  | {kind: \"c\"; r: float64}\n  // a square\n  | {kind: \"s\"; side: float64};\n";
	assert fmt(ownLines) == "type Shape =\n\t// a circle\n\t| { kind: \"c\"; r: float64 }\n\t// a square\n\t| { kind: \"s\"; side: float64 };\n", fmt(ownLines);
	for (const source of [union, blocks, ownLines]) {
		assert assertFmtLossless(source);
		assert assertFmtIdempotent(source);
	}
}

test "fmt: a union alias with a comment outside the gaps between its members prints as written" {
	for (const source of [
		"type /* name */ Pair   = int32|string;\n",
		"type Box = { a: int32 /* inside */ }   | string;\n",
		"type Lead = // after equals\n\t| int32\n\t| string;\n",
	]) {
		assert fmt(source) == source, fmt(source);
	}
}
