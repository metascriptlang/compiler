// macroNodeFieldTyped — flat Node-field reads inside a macro body are TYPED.
//
// The macro VM's wire format flattens NodeData payload fields (jsxAttrName,
// jsxTag, ...) onto the Node object. Before the macroParamTypes fix the engine
// wrapper left macro params untyped (fnParamTypes all ""), so every flat read
// was Unknown and chained calls dispatched blind: a.jsxAttrName.startsWith("on")
// evaluated to its ARGUMENT ("on"), which the element macro spliced into the
// tree as a child — neon counter.test's msString-into-void* clang wreck.
// Fix: macroParamTypes/macroDeclModule registries → wrapper fnParamTypes +
// engine-mode virtual resolution of flat reads against the NodeData union
// (LANG.md "unique field name" DU access rule) + decl-module seed symbols.
// Sibling negative guard: src/test/guard/macroNodeBogusField.ms.

import { Node, NodeKind } from "std/meta";

export macro mgClassify(n: Node): Node {
	let out = "";
	for (const a of n.jsxAttrs) {
		if (a.kind === NodeKind.JSXAttribute) {
			const c = a.jsxAttrName.startsWith("on") ? "evt" : "attr";
			out = out + c + ";";
		}
	}
	return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: out };
}

export macro mgTag(n: Node): Node {
	return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: n.jsxTag };
}

test "macro flat startsWith chain is typed (evt/attr classification)" {
	const cls = mgClassify(<div onClick="x" class="box">hi</div>);
	assert cls === "evt;attr;", "got: " + cls;
}

test "macro flat direct read returns the true field value" {
	const tag = mgTag(<div onClick="x" class="box">hi</div>);
	assert tag === "div", "got: " + tag;
}
