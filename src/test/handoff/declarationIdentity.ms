import { compileToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function one(source: string): MapEntry[] {
	return [{ entryPath: "test/main.ms", entrySource: source }];
}

test "a user class spelled Type or Symbol keeps deep Readonly" {
	for (const name of ["Type", "Symbol"]) {
		const source = `
class ${name} { n: int32 = 0; }
class Holder { t: ${name} = new ${name}(); }
function poke(h: Readonly<Holder>): void { const t = h.t; t.n = 5; }
poke(new Holder());
`;
		const c = compileToCWithStd(source);
		assert !c.ok && c.error.contains("PARALOCK E24"), name;
		const js = compileProjectToJSWithStd(one(source), "test/main.ms");
		assert js.startsWith("ERROR:") && js.contains("PARALOCK E24"), name;
	}
}

test "a user class spelled Type or Symbol may hold a user Node and be written through" {
	for (const name of ["Type", "Symbol"]) {
		const source = `
class Node { x: int32 = 0; }
class ${name} { node: Node = new Node(); }
const t = new ${name}();
t.node.x = 7;
console.log(t.node.x);
`;
		const c = compileToCWithStd(source);
		assert c.ok, name + ": " + (c.ok ? "" : c.error);
		const js = compileProjectToJSWithStd(one(source), "test/main.ms");
		assert !js.startsWith("ERROR:"), name + ": " + js;
	}
}

test "two function-typed distinct aliases of one name in two modules are two types" {
	const a = `export type Cb = distinct ((x: int32) => int32);\nexport function mk(): Cb { return ((x: int32) => x + 1) as Cb; }`;
	const b = `export type Cb = distinct ((s: string) => string);\nexport function mkS(): Cb { return ((s: string) => s + "!") as Cb; }`;
	const entries = (main: string): MapEntry[] => [
		{ entryPath: "test/a.ms", entrySource: a },
		{ entryPath: "test/b.ms", entrySource: b },
		{ entryPath: "test/main.ms", entrySource: main },
	];
	const wrong = checkProjectDiagnostics(entries(`
import { Cb, mk } from "./a";
import { mkS } from "./b";
function run(f: Cb): int32 { return f(41); }
console.log(run(mk()), run(mkS()));
`), "test/main.ms");
	assert wrong.length == 1 && wrong[0].contains("Cb"), wrong.join("\n");
	const sameAsParam = checkProjectDiagnostics(entries(`
import { Cb, mk } from "./a";
function run(f: Cb): int32 { return f(41); }
console.log(run(mk()));
`), "test/main.ms");
	assert sameAsParam.length == 0, sameAsParam.join("\n");
}

test "a branded primitive is one type wherever its brand and base are spelled alike, and two types when the base differs" {
	const decls = `type EntityId = string & { __brand: "EntityId" };
type EntityAlias = string & { __brand: "EntityId" };
type EntityCount = int32 & { __brand: "EntityId" };
function entity(value: EntityId): string { return value as string; }
`;
	const errors = (use: string): string[] => checkProjectDiagnostics(one(decls + use), "test/main.ms").filter((m: string): boolean => !m.endsWith("is declared but never used"));
	const same = errors(`console.log(entity("k" as EntityAlias));\n`);
	assert same.length == 0, same.join("\n");
	const other = errors(`console.log(entity(7 as EntityCount));\n`);
	assert other.length == 1 && other[0].contains("EntityCount"), other.join("\n");
}

test "union variants holding two classes of one name from two modules differ in layout" {
	const entries = (itemB: string, nameB: string): MapEntry[] => [
		{ entryPath: "test/a.ms", entrySource: "export class Item { n: int32 = 1; }" },
		{ entryPath: "test/b.ms", entrySource: itemB },
		{ entryPath: "test/main.ms", entrySource: `
import { Item as AItem } from "./a";
import { ${nameB} as BItem } from "./b";
type U = { v: AItem } | { v: BItem };
function f(u: U): string { return u.v.s; }
console.log(1);
` },
	];
	for (const name of ["Item", "Other"]) {
		const diags = checkProjectDiagnostics(entries(`export class ${name} { s: string = "x"; }`, name), "test/main.ms");
		assert diags.length > 0 && diags[0].contains("different offsets"), name + ": " + diags.join("\n");
	}
}

test "a computed bindSym miss used as a callee is one error, not a crash" {
	const lib = `
import { Node, NodeKind, bindSym } from "std/meta";
export macro first(x: Node): Node {
	const name = "no" + "such";
	const bound = bindSym(name);
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column, callee: bound!,
		arguments: [x], isDirectCall: false, resolvedOverloadIdx: -1 };
}
`;
	for (const use of ["console.log(first(4));", "first(4);"]) {
		const diags = checkProjectDiagnostics([
			{ entryPath: "test/lib.ms", entrySource: lib },
			{ entryPath: "test/main.ms", entrySource: `import { first } from "./lib";\n${use}\n` },
		], "test/main.ms");
		assert diags.length == 1 && diags[0].contains("null callee"), use + ": " + diags.join("\n");
	}
}
