// bug124 — raiser bytecode compiler silently spliced nil for constructs it
// could not compile
//
// Symptom:    a macro body referencing a module-level variable (or any symbol
//             with no local/function/enum/builtin binding) compiled clean,
//             expanded, and produced a nil value — build green, output
//             silently wrong. Same for unsupported node kinds via the
//             catch-all arm.
// Root cause: compileExpr's identifier fallback and its `_` arm emitted
//             LoadConst nil with no diagnostic (codegen/raiser/expressions.ms).
// Fix:        both arms queue a "cannot evaluate/cannot compile ... at
//             comptime" error (context.ms queue); eval.ms drains it into
//             EngineMacroResult.errors; expand.ms renders it with span —
//             the cannotEval shape.
// Adapted:    the original repro used `const TABLE`; module-level consts now
//             INLINE their initializer (bug126) and fold legally, so the
//             guard rides on a mutable `let` — the remaining shape of this
//             bug class.

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind } from "std/meta";

let COUNTER = "ABC";

export macro usesVar(node: Node): Node {
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: COUNTER };
}

function main(): void {
	const x = usesVar(0);
	console.log(x);
}
main();
`;

test "bug124: unresolvable comptime identifier errors loudly with a span" {
	const c = compileToCWithStd(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("cannot evaluate 'COUNTER' at comptime");
	}
}
