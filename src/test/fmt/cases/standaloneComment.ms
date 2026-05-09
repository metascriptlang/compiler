// Standalone comment between two statements stays standalone.
//
// Symptom:    Source:
//                 assert c.ok;
//                 // Should use (*d).kind, NOT d.kind
//                 doSomething();
//             Format:
//                 assert c.ok; // Should use (*d).kind, NOT d.kind
//                 doSomething();
//             The standalone comment got merged as a trailing comment
//             of the previous stmt, breaking attribution.
// Root cause: printNode comment-wrapper classifies any comment with
//             `line >= node.location.line` as "trailing" — same line
//             OR after. But a comment on the NEXT line is standalone,
//             not trailing.
// Fix:        Trailing = comment on the SAME line. Below = comment on
//             a later line — emit as a standalone line.

import { assertFmtContains } from "../roundtrip";

test "fmt: comment after stmt stays standalone" {
	assertFmtContains(
		"function f(): void {\n\tlet x = 1;\n\t// standalone\n\tlet y = 2;\n}",
		"// standalone",
	);
	// Verify the comment is NOT merged onto x's line.
	assertFmtContains(
		"function f(): void {\n\tlet x = 1;\n\t// standalone\n\tlet y = 2;\n}",
		"let x = 1;\n",
	);
}
