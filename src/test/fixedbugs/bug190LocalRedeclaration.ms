// bug190 — a second `const`/`let` of one name in one local scope merged into the first
//
// Symptom:    `const t = 1; const a = t; const t = 2;` compiled: C printed 12
//             because the lambda-lifting rename happened to split the two,
//             the JS lane emitted `const t` twice (SyntaxError), and with two
//             different types clang refused the build.
// Cause:      `checkVariableDecl` treats a symbol already in the scope as the
//             one pass 1 collected (or the self-recursion pre-registration)
//             for THIS declaration, and retyped it — whoever had declared it.
// Reference:  Nim reports a redefinition in one scope (`lookups.nim`
//             `wrongRedefinition` via `addInterfaceDecl`); module scope here
//             already said `Duplicate symbol`. A symbol found in the scope is
//             this declaration's own only when its declNode is this node.
import { compileToCWithStd, compileProjectToCWithStd, MapEntry } from "../helpers";

function errorOf(source: string): string {
	const c = compileToCWithStd(source);
	return c.ok ? "" : c.error;
}

test "bug190: a second const of one name in one block is a duplicate" {
	const e = errorOf(`
function f(): int32 { const t = 1; const a = t; const t = 2; return a * 10 + t; }
function main(): void { console.log(f().toString()); }
`);
	assert e.contains("Duplicate symbol 't'"), e;
}

test "bug190: a second let is a duplicate too" {
	const e = errorOf(`
function f(): int32 { let t = 1; const a = t; let t = 2; return a * 10 + t; }
function main(): void { console.log(f().toString()); }
`);
	assert e.contains("Duplicate symbol 't'"), e;
}

test "bug190: a second declaration of another type never reaches the C compiler" {
	const e = errorOf(`
function f(): string { const t = 1; const a = t; const t = "two"; return a.toString() + t; }
function main(): void { console.log(f()); }
`);
	assert e.contains("Duplicate symbol 't'"), e;
}

test "bug190: two statics of one name in one body are duplicates" {
	const e = errorOf(`
function mk(tag: string): string { return tag; }
function f(): string { static const t = mk("A"); const a = t; static const t = mk("B"); return a + t; }
function main(): void { console.log(f()); }
`);
	assert e.contains("Duplicate symbol 't'"), e;
}

test "bug190: a nested block still shadows" {
	const e = errorOf(`
function f(): int32 { const t = 1; { const t = 2; if (t != 2) return 0; } return t; }
function main(): void { console.log(f().toString()); }
`);
	assert e == "", e;
}

test "bug190: a self-recursive closure still binds to its own pre-registered symbol" {
	const e = errorOf(`
function f(): int32 { const fact = (n: int32): int32 => n <= 1 ? 1 : n * fact(n - 1); return fact(5); }
function main(): void { console.log(f().toString()); }
`);
	assert e == "", e;
}

test "bug190: sibling blocks may reuse a name" {
	const e = errorOf(`
function f(flag: boolean): int32 { if (flag) { const t = 1; return t; } else { const t = 2; return t; } }
function main(): void { console.log(f(true).toString()); }
`);
	assert e == "", e;
}

const PAIR_LIB = `
import { Node, NodeKind, DeclKind } from "std/meta";

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

function withPair(body: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/pair.ms", entrySource: PAIR_LIB },
		{ entryPath: "test/main.ms", entrySource: `import { pair } from "./pair";\n` + body },
	];
	return compileProjectToCWithStd(entries, "test/main.ms");
}

test "bug190: the declarations a statement macro injects are its own, not duplicates" {
	const out = withPair(`
function sum(): int32 { pair(); return a * 10 + b; }
function main(): void { console.log(sum().toString()); }
`);
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
}

test "bug190: injecting the same names twice into one block is a duplicate" {
	const out = withPair(`
function sum(): int32 { pair(); pair(); return a * 10 + b; }
function main(): void { console.log(sum().toString()); }
`);
	assert out.contains("Duplicate symbol 'a'"), out.slice(0, 400);
	assert out.contains("Duplicate symbol 'b'"), out.slice(0, 400);
}

test "bug190: a module-level duplicate is reported once" {
	const e = errorOf(`
const t = 1;
const t = 2;
function main(): void { console.log((t).toString()); }
`);
	assert e.split("Duplicate symbol 't'").length == 2, e;
}
