// bug101 — converter table keyed by syntactic target NAME: non-nominal targets dead
//
// Symptom:    a converter whose return annotation is a named alias of a
//             function type (or any non-struct type) never fires — JSX at a
//             settled boundary errors "must be consumed by a macro ...
//             targeting 'function'".
// Root cause: registerConverter (collectPass) keys the pair table with the
//             SYNTACTIC return-type string ("DirectMount"), while
//             tryConverterAtBoundary looks up typeDisplayName(expectedType),
//             which for an alias-of-function is "function" (typeNameOf
//             returns "" for Function BY DESIGN). The two keys can never meet.
// Fix:        Nim userConvMatch (sigmatch.nim:2297) walks resolved converter
//             symbols and requires dest typeRel in {isEqual}: the declaring
//             module now resolves the target annotation (checkPass MacroDecl,
//             line=0 so no new diagnostics), the resolved Type travels the
//             existing export/prelude plumbing, and the boundary falls back
//             to a sameType walk when the name fast-path misses.

import { compileToCWithStd, compileProjectToCWithStd, MapEntry } from "../helpers";

const LIB = `
import { Node, NodeKind } from "std/meta";

export type MkNum = () => number;

export function mkImpl(): number { return 7; }

export converter toThunk(n: Node): MkNum {
	return { kind: NodeKind.Identifier, line: n.line, column: n.column, name: "mkImpl" };
}
`;

test "bug101: converter fires at annotated decl typed with a function alias" {
	const c = compileToCWithStd(LIB + `
function main(): void {
	const f: MkNum = <div/>;
	console.log(f().toString());
}
`);
	assert c.ok;
}

test "bug101: converter fires at arg position typed with a function alias" {
	const c = compileToCWithStd(LIB + `
function use(f: MkNum): number { return f(); }
function main(): void {
	console.log(use(<div/>).toString());
}
`);
	assert c.ok;
}

test "bug101: converter fires for an alias of a primitive target" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";
type N = number;
export converter toNum(n: Node): N {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}
function main(): void {
	const x: N = <div/>;
	console.log(x.toString());
}
`);
	assert c.ok;
}

test "bug101: alias-target converter propagates through import" {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: LIB },
		{ entryPath: "src/main.ms", entrySource: `
import { MkNum, toThunk, mkImpl } from "./lib";
function main(): void {
	const f: MkNum = <span/>;
	console.log(f().toString());
}
main();
` },
	];
	const cCode = compileProjectToCWithStd(entries, "src/main.ms");
	assert !cCode.contains("ERROR:");
}
