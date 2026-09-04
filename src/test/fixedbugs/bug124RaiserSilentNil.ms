// bug124 — raiser bytecode compiler silently spliced nil for constructs it
// could not compile
//
// Symptom:    a macro body referencing a module-level const (or any symbol
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

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind } from "std/meta";

const TABLE = "ABC";

export macro usesConst(node: Node): Node {
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: TABLE };
}

function main(): void {
	const x = usesConst(0);
	console.log(x);
}
main();
`;

test "bug124: unresolvable comptime identifier errors loudly with a span" {
	const c = compileToCWithStd(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("cannot evaluate 'TABLE' at comptime");
	}
}
