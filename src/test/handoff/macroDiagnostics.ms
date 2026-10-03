import { compileToCWithStd } from "../helpers";

test "macro diagnostics: rejection crosses frames once and cannot be caught" {
	const bodies = [
		'error("rejected input", node);',
		'function reject(n: Node): void { error("rejected input", n); } reject(node);',
		'function reject(n: Node): Node[] { error("rejected input", n); return []; } const values = reject(node);',
		'function reject(n: Node): void { error("rejected input", n); } try { reject(node); } catch (e) {}',
	];
	for (const body of bodies) {
		const source = 'import { Node } from "std/meta"; macro requireValid(node: Node): Node { '
			+ body + ' error("continued after rejection", node); return node; } const value = requireValid(1);';
		const result = compileToCWithStd(source);
		assert !result.ok, body;
		assert result.error.split("rejected input").length == 2, result.error;
		assert !result.error.contains("continued after rejection"), result.error;
		assert !result.error.contains("possible recursive macro"), result.error;
	}
}

test "macro diagnostics: a number literal that contradicts itself is refused at the invocation" {
	const header = 'import { Node, NodeKind } from "std/meta"; macro bad(node: Node): Node { ';
	const cases = [
		{ body: 'return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 3.5, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };', says: "Macro 'bad': a NumberLiteral declares isFloat: false, and its value 3.5 is not an integer" },
		{ body: 'const n: int64 = 7; return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 2.5, isFloat: true, intVal: n, outOfRangeText: "", isBitPattern: false };', says: "Macro 'bad': a NumberLiteral declares isFloat: true and intVal 7" },
	];
	for (const c of cases) {
		const result = compileToCWithStd(header + c.body + ' } const value = bad(0);');
		assert !result.ok, c.body;
		assert result.error.contains(c.says), result.error;
	}
}

test "macro diagnostics: nested helper errors and wrapper errors both survive compilation" {
	const cases = [
		{ body: 'function helper(n: Node): string { return "ok"; } macro use(n: Node): Node { const bad = n.missingField; const s = helper(n); return n; }', dependency: "missingField" },
		{ body: 'function helper(n: Node): Node { return missingHelper(n); } macro use(n: Node): Node { return helper(n); }', dependency: "helper" },
	];
	for (const item of cases) {
		const result = compileToCWithStd('import { Node } from "std/meta"; ' + item.body + ' const value = use(1);');
		assert !result.ok, item.body;
		assert result.error.contains(item.dependency), result.error;
	}
	const healthy = compileToCWithStd('import { Node } from "std/meta"; function helper(n: Node): Node { return n; } macro use(n: Node): Node { return helper(n); } const value: int32 = use(42);');
	assert healthy.ok;
}

test "macro diagnostics: ordinary exceptions retain their payload" {
	const result = compileToCWithStd('import { Node } from "std/meta"; macro reject(n: Node): Node { throw new Error("macro exception payload"); return n; } const value = reject(1);');
	assert !result.ok;
	assert result.error.contains("macro exception payload"), result.error;
}

const mutableStateSource = `
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

test "macro unsupported evaluation: mutable module state identifies the unavailable dependency" {
	const c = compileToCWithStd(mutableStateSource);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("COUNTER");
	}
}

const unbridgedCallSource = `
import { Node, NodeKind } from "std/meta";

export macro usesDead(node: Node): Node {
	const v = "Hello".substring(1, 3);
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = usesDead(0);
	console.log(x);
}
main();
`;

test "macro unsupported evaluation: unbridged externs identify the unavailable host function" {
	const c = compileToCWithStd(unbridgedCallSource);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("msStringSubstring");
	}
}

const objectCallMacro = `
import { Node, NodeKind } from "std/meta";

interface S { width: number | null; }

export function idS(s: S): S { return s; }

export macro mk(node: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: node.line, column: node.column,
		callee: { kind: NodeKind.Identifier, line: node.line, column: node.column, name: "idS" },
		arguments: [node],
	};
}

`;

test "macro diagnostics: emitted object calls enforce keys before emission" {
	const cases = [
		{ object: "{ width: 1 }", accepted: true },
		{ object: "{ widht: 1 }", accepted: false },
		{ object: "{ width: 1, width: 2 }", accepted: false },
	];
	for (const item of cases) {
		const result = compileToCWithStd(objectCallMacro + "const value = mk(" + item.object + ");");
		assert result.ok == item.accepted, item.object;
	}
}

test "macro expansion identity: unresolved bound symbols fail before emission" {
	const result = compileToCWithStd('import { Node, NodeKind } from "std/meta"; macro unresolved(n: Node): Node { return { kind: NodeKind.CallExpr, line: n.line, column: n.column, callee: bindSym("absentHelper"), arguments: [n] }; } const value = unresolved(1);');
	assert !result.ok;
	assert result.error.contains("absentHelper"), result.error;
}

test "macro exception operands: only error values and strings enter catch" {
	const refused = [
		"function f(): void { throw 7; }",
		"function f(n: number): void { throw n; }",
		"function f(): void { throw null; }",
		"function f(value: Error | null): void { throw value; }",
		"function f(value: unknown): void { throw value; }",
	];
	for (const source of refused) assert !compileToCWithStd(source).ok, source;
	const accepted = [
		'function f(): void { throw new Error("x"); }',
		'function f(value: Error | null): void { if (value !== null) throw value; }',
		'function f(): void { try { f(); } catch (e) { throw e; } }',
		'function f(): void { throw "x"; }',
		'function f(value: string): void { throw value; }',
		'function f(value: int32): void { throw `value=${value}`; }',
	];
	for (const source of accepted) assert compileToCWithStd(source).ok, source;
}
