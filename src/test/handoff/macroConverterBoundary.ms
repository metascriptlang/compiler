import { compileToCWithStd } from "../helpers";

const numericConverter = `
import { Node, NodeKind } from "std/meta";
export converter toNum(n: Node): number {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}
`;

test "macro converter fit: source form and nullable slot use the payload converter" {
	const cases = [
		{ body: "const value: number = <x/>;", accepted: true },
		{ body: "const value: number | null = <x/>;", accepted: true },
		{ body: "function take(value: number | null): void {} take(<x/>);", accepted: true },
		{ body: "function take(value: { slot?: number | null }): void {} take({ slot: <x/> });", accepted: true },
		{ body: "const value: number = quote { 1 + 1 };", accepted: true },
		{ body: "const value: number | null = quote { 1 };", accepted: true },
		{ body: "function take(value: number): void {} take(quote { 1 });", accepted: true },
		{ body: "const value: string | null = <x/>;", accepted: false },
		{ body: "const value: number | string = <x/>;", accepted: false },
	];
	for (const item of cases) {
		const result = compileToCWithStd(numericConverter + item.body);
		assert result.ok == item.accepted, item.body;
	}
}

test "macro converter fit: reference payload lookup still validates the expansion" {
	const source = 'import { Node, NodeKind } from "std/meta"; class Box { value: int32 = 7; } function makeBox(): Box { return new Box(); } converter toBox(n: Node): Box { return { kind: NodeKind.CallExpr, line: n.line, column: n.column, callee: bindSym("makeBox"), arguments: [] }; }';
	assert compileToCWithStd(source + "const plain: Box = <x/>; const maybe: Box | null = <x/>;").ok;
	const invalid = 'import { Node, NodeKind } from "std/meta"; class Box { value: int32 = 7; } converter toBox(n: Node): Box { return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 }; }';
	assert !compileToCWithStd(invalid + "const value: Box | null = <x/>;").ok;
}

const flowConverterSource = `
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

function flowConverterErrors(body: string): string {
	const r = compileToCWithStd(flowConverterSource + body);
	if (r.ok) return "";
	return r.error;
}

test "macro converter flow: the converter narrows in a declaration slot and an argument slot too" {
	assert flowConverterErrors("function f(m: string | null): string { const t: Thing = <show>{m}</show>; return t(); }") == "";
	assert flowConverterErrors("function run(t: Thing): string { return t(); } function f(m: string | null): string { return run(<show>{m}</show>); }") == "";
}

test "macro converter flow: a fragment lowered by the converter narrows" {
	const FRAG = "macro fragNone(n: Node): Node { return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: \"orNone\", macroArgs: [n.jsxFragChildren[0]] }; }\n";
	assert flowConverterErrors(FRAG + "function f(m: string | null): Thing { return fragNone(<><show>{m}</show></>); }") == "";
}

test "macro converter flow: a guard written inside the JSX narrows its own branch" {
	assert flowConverterErrors("function f(m: string | null): Thing { return orNone(<show>{m !== null ? show(m) : null}</show>); }") == "";
	assert flowConverterErrors("function f(m: string | null): Thing { return <show>{m !== null ? show(m) : null}</show>; }") == "";
}

test "macro converter flow: a guard outside the JSX narrows a read inside it, by name and through the converter" {
	const FIRST = "macro first(n: Node): Node { return n.jsxChildren[0].jsxExpr; }\n"
		+ "export converter jsxToString(n: Node): string { return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: \"first\", macroArgs: [n] }; }\n";
	assert flowConverterErrors(FIRST + "function f(m: string | null): string { if (m === null) return \"none\"; return first(<a>{show(m)}</a>); }") == "";
	assert flowConverterErrors(FIRST + "function f(m: string | null): string { if (m === null) return \"none\"; return <a>{show(m)}</a>; }") == "";
}

test "macro converter flow: an unguarded nullable passed straight through is still refused" {
	const e = flowConverterErrors("function f(m: string | null): Thing { return <show>{show(m)}</show>; }");
	assert e != "", e;
}

test "macro converter flow: explicit and implicit expansion share nullable narrowing" {
	const values = [
		{ type: "string", callee: "show" },
		{ type: "(() => string)", callee: "callIt" },
		{ type: "Box<string>", callee: "unbox" },
	];
	for (const value of values) {
		for (const explicit of [false, true]) {
			const jsx = "<" + value.callee + ">{value}</" + value.callee + ">";
			const expr = explicit ? "orNone(" + jsx + ")" : jsx;
			const source = "function make(value: " + value.type + " | null): Thing { return " + expr + "; }";
			assert flowConverterErrors(source) == "", source;
		}
	}
}
