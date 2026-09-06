// @maxrss: 30
// @stdout: jsx-macro-native PASS
// note: End-to-end JSX → macro → native (the closed cycle, Phases 3+4+7). A user `macro jsx(node)` consumes JSX `Node` values the parser produced and the checker typed compile-time-only, reads the serialized `jsxTag`, and emits a StringLiteral. The macro expands while THIS program compiles to native, so the build exercises parse → check → macro-expand → codegen; the marker prints only if every tag form — element, member (`Foo.Bar`), namespace (`svg:rect`), and a tag with attributes + expr container + nested children — round-tripped through the macro. ~2MB drc+orc. Proves JSX is usable end-to-end, not just parseable. (This toy macro reads only the scalar `jsxTag` by design — a minimal marker. Macro array-field access works: `for..of`, indexing, and `node.jsxChildren.length` all return correct values from a macro body; the jsxDom reference macro exercises full array navigation, guarded by jsxdom-native.)

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
	if (jsxTag(<View/>) != "View") { ok = false; }
	if (jsxTag(<Foo.Bar/>) != "Foo.Bar") { ok = false; }
	if (jsxTag(<svg:rect/>) != "svg:rect") { ok = false; }
	if (jsxTag(<Counter id="x">hi {1}<Item/></Counter>) != "Counter") { ok = false; }
	if (ok) { console.log("jsx-macro-native PASS"); }
	else { console.log("jsx-macro-native FAIL"); }
}
main();
