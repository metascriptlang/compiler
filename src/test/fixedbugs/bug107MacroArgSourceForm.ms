// bug107 — a macro argument's NESTED nodes kept their checker-inserted wrappers
//
// Symptom:    `probe([{ width: 1 }, { height: 2 }])` handed the macro an
//             ArrayLiteral whose elements were HiddenSubConv with childCount 0
//             and a convExpr that read back as the ENCLOSING array — the macro
//             could neither identify nor descend into the object literals, so
//             a compile-time merge was impossible and callers fell back to a
//             runtime fold (Neon style layering).
// Root cause: stripMacroArgWrappers lived in expand.ms and was applied by the
//             CALLER (expandMacro, one call on the root argument), while the
//             marshaller that actually walks the tree — nodeToValue in
//             bridge.ms — never applied it while descending. nodeToASTLiteral,
//             the sibling mirror in expand.ms, stripped at every node because
//             it calls the helper on entry and recurses; the two marshallers
//             disagreed. The bridge has no serialization arm for the conv
//             kinds by design, so an unstripped conv reached the wire with no
//             payload at all.
// Fix:        the helper moved to bridge.ms beside nodeToValue and runs on
//             entry there, so every recursion strips — restoring the invariant
//             the helper's own comment states ("a macro sees the source-form
//             AST"). Nim parity: an `untyped` macro parameter is pre-sem AST
//             with no nkHiddenStdConv/nkHiddenSubConv in it.

import { compileToCWithStd } from "../helpers";

test "bug107: array-literal elements reach a macro as source-form ObjectLiterals" {
	const c = compileToCWithStd(`
import { Node, NodeKind, childCount } from "std/meta";

function kn(k: NodeKind): string {
	if (k === NodeKind.ObjectLiteral) { return "OBJ"; }
	if (k === NodeKind.HiddenSubConv) { return "SUBCONV"; }
	if (k === NodeKind.HiddenStdConv) { return "STDCONV"; }
	return "OTHER";
}

macro sawElements(node: Node): Node {
	let s = "";
	for (const raw of node.elements) {
		s = s + kn(raw.kind) + ":" + childCount(raw).toString() + " ";
	}
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: s };
}

console.log(sawElements([{ width: 1 }, { height: 2 }]));
`);
	assert c.ok;
	assert c.value.indexOf("OBJ:1 OBJ:1 ", 0) >= 0;
}

// Shape pin only — nested array elements take no conversion, so this cell
// stays green under the one-line mutation that reddens the cell above.
test "bug107: a nested array argument keeps its ArrayLiteral/ObjectLiteral shape" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

function kn(k: NodeKind): string {
	if (k === NodeKind.ObjectLiteral) { return "OBJ"; }
	if (k === NodeKind.ArrayLiteral) { return "ARR"; }
	if (k === NodeKind.HiddenSubConv) { return "SUBCONV"; }
	if (k === NodeKind.HiddenStdConv) { return "STDCONV"; }
	return "OTHER";
}

macro sawNested(node: Node): Node {
	let s = "";
	for (const outer of node.elements) {
		s = s + kn(outer.kind) + "(";
		for (const inner of outer.elements) { s = s + kn(inner.kind) + " "; }
		s = s + ")";
	}
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: s };
}

console.log(sawNested([[{ width: 1 }], [{ height: 2 }]]));
`);
	assert c.ok;
	assert c.value.indexOf("ARR(OBJ )ARR(OBJ )", 0) >= 0;
}
