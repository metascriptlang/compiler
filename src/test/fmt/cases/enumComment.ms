// Trailing comments on enum members stay attached.
//
// Symptom:    `enum K { A, // foo\n B, // bar\n }` formats with all
//             comments hoisted to AFTER the closing brace, separated
//             from their members.
// Root cause: printEnumDecl ignored comments completely; the printNode
//             comment-wrapper then attached all comments as trailing
//             of the EnumDecl as a whole, dumping them at the end.
// Fix:        Mirror printStructLikeDecl — match comments to members
//             by source line number.

import { assertFmtContains } from "../roundtrip";

test "fmt: enum members keep trailing comments" {
	assert assertFmtContains(
		"enum K {\n\tA, // foo\n\tB, // bar\n}",
		"A, // foo",
	);
	assert assertFmtContains(
		"enum K {\n\tA, // foo\n\tB, // bar\n}",
		"B, // bar",
	);
}
