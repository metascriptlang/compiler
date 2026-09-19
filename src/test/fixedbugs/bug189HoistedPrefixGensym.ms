// bug189 — two expansions of one hoisting macro in one block shared a declaration
//
// Symptom:    `const a = memo(); const b = memo();` built on C only because the
//             lambda-lifting rename happened to split the second `tpl`; the JS
//             lane emitted `const tpl` twice (SyntaxError). At a statement
//             position `memoLog();` lost its value: the trailing expression
//             was put in the statement slot unchecked, so C dropped the call
//             and JS read an unbound name.
// Cause:      the prefix a value macro hoists was declared under the name the
//             macro spelled, in the caller's scope, once per expansion.
// Reference:  Nim declares what a template or macro emits as a gensym
//             (semtempl.nim `newGenSym`, vm.nim `opcGenSym`): it never enters
//             the scope (semstmts.nim:931) and the value reaches it as a
//             symbol. MetaScript's lift machinery is keyed by name, so the
//             gensym is a consistent rename of the declaration and its refs,
//             the same one `template` bodies already get.
import { compileProjectToCWithStd, compileProjectToJSWithStd, MapEntry } from "../helpers";

const MEMO_LIB = `
import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

export macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [{
			kind: NodeKind.VariableDecl, line: 0, column: 0,
			flags: NodeFlag.StaticStorage,
			declName: "tpl", declType: "string",
			initializer: {
				kind: NodeKind.CallExpr, line: 0, column: 0,
				callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
				arguments: [],
			},
			declKind: DeclKind.Const,
			nameLocation: { line: 0, column: 0 },
		}, { kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" }],
	};
}

export macro memoShow(): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [{
			kind: NodeKind.VariableDecl, line: 0, column: 0,
			flags: NodeFlag.StaticStorage,
			declName: "tpl", declType: "string",
			initializer: {
				kind: NodeKind.CallExpr, line: 0, column: 0,
				callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
				arguments: [],
			},
			declKind: DeclKind.Const,
			nameLocation: { line: 0, column: 0 },
		}, {
			kind: NodeKind.CallExpr, line: 0, column: 0,
			callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "show" },
			arguments: [{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" }],
		}],
	};
}

export macro pair(): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [
			{ kind: NodeKind.VariableDecl, line: 0, column: 0, declName: "a", declType: "int32",
			  initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 1, isFloat: false },
			  declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 } },
			{ kind: NodeKind.VariableDecl, line: 0, column: 0, declName: "b", declType: "int32",
			  initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 2, isFloat: false },
			  declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 } },
		],
	};
}
`;

const MAIN_HEAD = `
import { memo, memoShow, pair } from "./memo";

let builds: int32 = 0;
let seen: string = "";
function build(): string { builds = builds + 1; return "T" + builds.toString(); }
function show(s: string): void { seen = seen + s; }
`;

function project(body: string): MapEntry[] {
	return [
		{ entryPath: "test/memo.ms", entrySource: MEMO_LIB },
		{ entryPath: "test/main.ms", entrySource: MAIN_HEAD + body },
	];
}

function occurrences(hay: string, needle: string): int32 {
	return (hay.split(needle).length - 1) as int32;
}

test "bug189: two expansions at expression positions of one block get a slot each" {
	const out = compileProjectToCWithStd(project(`
function render(): string { const x = memo(); const y = memo(); return x + y; }
function main(): void { console.log(render() + render()); }
`), "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
	assert occurrences(out, "__once = MS_FALSE") == 2, "one guard per expansion";
}

test "bug189: the JS lane declares each expansion under its own name" {
	const out = compileProjectToJSWithStd(project(`
function render(): string { const x = memo(); const y = memo(); return x + y; }
function main(): void { console.log(render() + render()); }
`), "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
	assert occurrences(out, "__once = false") == 2, "one guard per expansion";
}

test "bug189: a value splice at a statement position keeps and checks its value" {
	const out = compileProjectToCWithStd(project(`
function render(): void { memoShow(); memoShow(); }
function main(): void { render(); render(); console.log(seen); }
`), "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
	assert occurrences(out, "__once = MS_FALSE") == 2, "one guard per expansion";
	assert occurrences(out, "show") >= 3, "both calls survive next to the definition";
}

test "bug189: the same holds at module top" {
	const out = compileProjectToCWithStd(project(`
memoShow();
memoShow();
console.log(seen);
`), "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
	assert occurrences(out, " = build") == 2, "one initializer per expansion";
}

test "bug189: an arrow with a block body that expands twice survives the generic re-check" {
	const out = compileProjectToJSWithStd(project(`
function eachRow<T>(p: { each: T[]; row: (n: T) => string }): string { return p.row(p.each[0]); }
function render(): string { return eachRow({ each: [1], row: (n) => { const x = memo(); const y = memo(); return x + y; } }); }
function main(): void { console.log(render() + render()); }
`), "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
	assert occurrences(out, "__once = false") == 2, "one guard per expansion";
}

test "bug189: a splice that ends in a declaration still injects every name it declares" {
	const out = compileProjectToCWithStd(project(`
function sum(): int32 { pair(); return a * 10 + b; }
function main(): void { console.log(sum().toString()); }
`), "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
}
