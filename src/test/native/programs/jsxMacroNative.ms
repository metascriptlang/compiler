// End-to-end JSX → macro → native: a user `macro jsx(node)` consumes the JSX `Node` the parser
// produced and emits a StringLiteral, so building this program natively exercises the full
// parse → check → macro-expand → codegen pipeline. Every tag form (element, member `Foo.Bar`,
// namespace `svg:rect`, and a tag with attributes + children) must round-trip through the macro.

import { Node, NodeKind } from "std/meta";

macro jsxTag(node: Node): Node {
	return {
		kind: NodeKind.StringLiteral,
		line: node.line,
		column: node.column,
		value: node.jsxTag,
	};
}

function main(): void {
	let ok = true;
	if (jsxTag(<View/>) !== "View") { ok = false; }
	if (jsxTag(<Foo.Bar/>) !== "Foo.Bar") { ok = false; }
	if (jsxTag(<svg:rect/>) !== "svg:rect") { ok = false; }
	if (jsxTag(<Counter id="x">hi {1}<Item/></Counter>) !== "Counter") { ok = false; }
	if (ok) { console.log("jsx-macro-native PASS"); }
	else { console.log("jsx-macro-native FAIL"); }
}
main();
