// bug193 — code a macro emits narrowed when the macro was called by name, not when a converter asked for it
// Symptom: a macro emitting `const _o0 = v; if (_o0 !== null) { return f(_o0); }` compiled as
//          `orNone(<f>{v}</f>)` and reported "Argument type mismatch in 'f' arg 0: got Maybe_p…"
//          as bare `<f>{v}</f>` lowered by a converter. A guard written inside the JSX itself,
//          `<f>{v !== null ? f(v) : null}</f>`, failed the same way on both routes.
// Root cause: the binder had no arm for JSX or quote nodes, so they carried no program point and
//             their embedded expressions no flow. The converter boundary rewrites the JSX node in
//             place into the MacroInvocation, the expansion is re-bound from that node's program
//             point, and a missing one skipped the re-bind without a word.
// Fix: the binder walks JSX attributes, children and containers like any expression and stamps the
//      program point on JSX elements, fragments and quotes, the nodes a converter can rewrite.

import { compileToCWithStd } from "../helpers";

const PRELUDE = `
import { Node, NodeKind, DeclKind } from "std/meta";
type Thing = () => string;
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
export function show(s: string): string { return "got " + s; }
export function callIt(f: () => string): string { return f(); }
export function unbox(b: Box<string>): string { return b.v; }
macro orNone(n: Node): Node {
	const L = n.line;
	const C = n.column;
	const value = n.jsxChildren[0].jsxExpr;
	return {
		kind: NodeKind.ArrowFunction, line: L, column: C, arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "string",
		arrowBody: {
			kind: NodeKind.BlockStmt, line: L, column: C,
			statements: [
				{ kind: NodeKind.VariableDecl, line: L, column: C, declName: "_o0", declType: "", declKind: DeclKind.Const, initializer: value },
				{
					kind: NodeKind.IfStmt, line: L, column: C,
					condition: { kind: NodeKind.BinaryExpr, line: L, column: C, operator: "!==", left: { kind: NodeKind.Identifier, line: L, column: C, name: "_o0" }, right: { kind: NodeKind.NullLiteral, line: L, column: C } },
					consequent: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{ kind: NodeKind.ReturnStmt, line: L, column: C, argument: { kind: NodeKind.CallExpr, line: L, column: C, callee: { kind: NodeKind.Identifier, line: L, column: C, name: n.jsxTag }, arguments: [{ kind: NodeKind.Identifier, line: L, column: C, name: "_o0" }] } }] },
					alternate: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [] },
				},
				{ kind: NodeKind.ReturnStmt, line: L, column: C, argument: { kind: NodeKind.StringLiteral, line: L, column: C, value: "none" } },
			],
		},
	};
}
export converter jsxToThing(n: Node): Thing {
	return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: "orNone", macroArgs: [n] };
}
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(PRELUDE + body);
	if (r.ok) return "";
	return r.error;
}

test "bug193: a nullable string narrows in the expansion, by name and through the converter" {
	assert errorsOf("function f(m: string | null): Thing { return orNone(<show>{m}</show>); }") == "";
	assert errorsOf("function f(m: string | null): Thing { return <show>{m}</show>; }") == "";
}

test "bug193: a nullable function narrows in the expansion, by name and through the converter" {
	assert errorsOf("function f(h: (() => string) | null): Thing { return orNone(<callIt>{h}</callIt>); }") == "";
	assert errorsOf("function f(h: (() => string) | null): Thing { return <callIt>{h}</callIt>; }") == "";
}

test "bug193: a nullable generic instance narrows in the expansion, by name and through the converter" {
	assert errorsOf("function f(b: Box<string> | null): Thing { return orNone(<unbox>{b}</unbox>); }") == "";
	assert errorsOf("function f(b: Box<string> | null): Thing { return <unbox>{b}</unbox>; }") == "";
}

test "bug193: the converter narrows in a declaration slot and an argument slot too" {
	assert errorsOf("function f(m: string | null): string { const t: Thing = <show>{m}</show>; return t(); }") == "";
	assert errorsOf("function run(t: Thing): string { return t(); } function f(m: string | null): string { return run(<show>{m}</show>); }") == "";
}

test "bug193: a fragment lowered by the converter narrows" {
	const FRAG = "macro fragNone(n: Node): Node { return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: \"orNone\", macroArgs: [n.jsxFragChildren[0]] }; }\n";
	assert errorsOf(FRAG + "function f(m: string | null): Thing { return fragNone(<><show>{m}</show></>); }") == "";
}

test "bug193: a guard written inside the JSX narrows its own branch" {
	assert errorsOf("function f(m: string | null): Thing { return orNone(<show>{m !== null ? show(m) : null}</show>); }") == "";
	assert errorsOf("function f(m: string | null): Thing { return <show>{m !== null ? show(m) : null}</show>; }") == "";
}

test "bug193: a guard outside the JSX narrows a read inside it, by name and through the converter" {
	const FIRST = "macro first(n: Node): Node { return n.jsxChildren[0].jsxExpr; }\n"
		+ "export converter jsxToString(n: Node): string { return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: \"first\", macroArgs: [n] }; }\n";
	assert errorsOf(FIRST + "function f(m: string | null): string { if (m === null) return \"none\"; return first(<a>{show(m)}</a>); }") == "";
	assert errorsOf(FIRST + "function f(m: string | null): string { if (m === null) return \"none\"; return <a>{show(m)}</a>; }") == "";
}

test "bug193: an unguarded nullable passed straight through is still refused" {
	const e = errorsOf("function f(m: string | null): Thing { return <show>{show(m)}</show>; }");
	assert e.contains("Argument type mismatch in 'show' arg 0"), e;
}
