// bug126 — module-level consts were invisible to the comptime bytecode
// compiler
//
// Symptom:    a macro body referencing a module-level const either silently
//             spliced nil (before bug124) or errored "cannot evaluate 'X' at
//             comptime" (after bug124) — the const's value was never
//             readable at compile time.
// Root cause: compileExpr's identifier arm only knew locals, functions, and
//             enum members; const symbols (SymbolKind.Variable, not Mutable)
//             fell through to the fallback.
// Fix:       the reference skConst/astdef shape — inline the symbol's
//             defining initializer (declNode.initializer) at the use site.
//             Mutable module vars still error: their runtime value is not a
//             compile-time thing.

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind } from "std/meta";

const TABLE = "ABC";
const WIDTH = 5 * 100;

export macro usesConst(node: Node): Node {
	const v = TABLE + "-" + WIDTH.toString();
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = usesConst(0);
	console.log(x);
}
main();
`;

test "bug126: module-level consts fold inside macro bodies" {
	const c = compileToCWithStd(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("ABC-500");
	}
}
