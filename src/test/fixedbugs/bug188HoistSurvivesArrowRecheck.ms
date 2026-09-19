// bug188 — a generic call re-checks an arrow it already expanded a macro in
//
// Symptom:    `run<T>({ row: (n) => memo() })` dies with `Undefined variable
//             'tpl'`, and `run<T>({ row: (n) => { static const t = mk(); … } })`
//             compiles but runs the initializer on every call.
// Cause:      once T is bound, `rearmLiteralForRecheck` clears the checker
//             state of every arrow field whose formal is generic and checks it
//             again. The second walk sees the arrow AFTER expansion: the value
//             is in place, the hoisted prefix is queued for the enclosing
//             statement list, and the symbol it declared lived in the scope of
//             the first walk. `clearCheckerState` also reset `flags` wholesale,
//             so a `static` written in the source lost its storage class.
//             A third owner lost the same prefix: the expander re-expands a
//             macro call found in another macro's output and flattened the
//             inner SpliceMany into whatever array held it, an array literal
//             included.
// Reference:  Nim keeps a macro's statements and value together in one
//             `nkStmtListExpr`, and a checked identifier is an `nkSym` that a
//             later sem pass never looks up by name again (semexprs.nim
//             `semSym`); pragmas are syntax and survive any re-sem. MetaScript
//             hoists instead of nesting (NIM-REF AN-4),
//             so the reference from the value to its own prefix has to travel
//             as a bound symbol, and syntax flags are not checker state.
import { compileToCWithStd, compileProjectToCWithStd, MapEntry } from "../helpers";

const MEMO_LIB = `
import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

export macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				flags: NodeFlag.StaticStorage,
				declName: "tpl",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" },
		],
	};
}

export macro memoInList(): Node {
	return {
		kind: NodeKind.CallExpr,
		line: 0,
		column: 0,
		callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "firstOf" },
		arguments: [{
			kind: NodeKind.ArrayLiteral,
			line: 0,
			column: 0,
			elements: [{ kind: NodeKind.MacroInvocation, line: 0, column: 0, macroName: "memo", macroArgs: [] }],
		}],
	};
}
`;

const MAIN_HEAD = `
import { memo, memoInList } from "./memo";

let builds: int32 = 0;
function build(): string { builds = builds + 1; return "T" + builds.toString(); }
function eachRow<T>(p: { each: T[]; row: (n: T) => string }): string { return p.row(p.each[0]); }
`;

function compileWithMemo(body: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/memo.ms", entrySource: MEMO_LIB },
		{ entryPath: "test/main.ms", entrySource: MAIN_HEAD + body },
	];
	return compileProjectToCWithStd(entries, "test/main.ms");
}

test "bug188: a hoisted prefix stays visible to its value when a generic call re-checks the arrow" {
	const out = compileWithMemo(`
function render(): string { return eachRow<int32>({ each: [1], row: (n) => memo() }); }
function main(): void { console.log(render() + render()); }
`);
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
	assert out.contains("__once");
}

test "bug188: the same holds when the type argument is inferred" {
	const out = compileWithMemo(`
function render(): string { return eachRow({ each: [1], row: (n) => memo() }); }
function main(): void { console.log(render() + render()); }
`);
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
}

test "bug188: a splice produced by a macro nested in another macro's output hoists at its expression position" {
	const out = compileWithMemo(`
function firstOf(items: string[]): string { return items[0]; }
function render(): string { return memoInList(); }
function main(): void { console.log(render() + render()); }
`);
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
	assert out.contains("__once");
}

test "bug188: a static declared in a re-checked arrow keeps its module storage" {
	const c = compileToCWithStd(`
let builds: int32 = 0;
function build(): string { builds = builds + 1; return "T" + builds.toString(); }
function eachRow<T>(p: { each: T[]; row: (n: T) => string }): string { return p.row(p.each[0]); }
function render(): string { return eachRow<int32>({ each: [1], row: (n) => { static const t = build(); return t; } }); }
function main(): void { console.log(render() + render()); }
`);
	assert c.ok, "must reach codegen: " + (c.ok ? "" : c.error);
	assert c.value.contains("__once");
}
