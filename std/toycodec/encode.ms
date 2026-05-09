// ToyCodec encode macro — emits inline string-concat expression at call site.
//
// Day 1 SMOKE: macro returns hardcoded string. Verifies pipeline end-to-end
// before building real encode logic.

import { Node, NodeKind } from "std/meta";

export macro toyEncode(t: Node): Node {
	// Smoke: always returns "smoke" regardless of t. Verifies the macro
	// dispatch + pipeline + return-shape works through compileToC.
	return {
		kind: NodeKind.StringLiteral,
		line: t.line,
		column: t.column,
		value: "smoke",
	};
}
