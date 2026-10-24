import { compileToCWithStd } from "../helpers";
import { engineCompiledNames } from "../../codegen/raiser/eval";

test "a std routine with a host callback is called through it, never compiled from its body" {
	const before = engineCompiledNames().length;
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro stringCallbacks(node: Node): Node {
	const s = "  Hello, Callbacks  ";
	const v = s.trim() + "|" + s.trimStart().toUpperCase() + "|" + s.trimEnd().toLowerCase() + "|" + "ab".repeat(2) + "|" + "abc".reverse();
	if (v !== "Hello, Callbacks|HELLO, CALLBACKS  |  hello, callbacks|abab|cba") { error("callback mismatch: " + v, node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = stringCallbacks(0);
	console.log(x);
}
`);
	assert result.ok, result.ok ? "" : result.error;
	const compiled = engineCompiledNames().slice(before);
	for (const name of ["trim", "trimStart", "trimEnd", "toUpperCase", "toLowerCase", "repeat", "reverse", "isSpaceByte", "clampIndex", "byteSlice"]) {
		assert !compiled.includes(name), `the body of '${name}' was compiled`;
	}
}
