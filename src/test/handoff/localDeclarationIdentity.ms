import { compileToCWithStd, compileProjectToCWithStd, MapEntry } from "../helpers";
import { strictErrorCount } from "./helpers";

test "declaration identity: local declaration kinds honor their supported scope boundary" {
	const cases = [
		{ name: "local class shadowing a module-level class is rejected (was: silent wrong answer)", source: `
class L { x: number = 1 }
function f(): number {
	class L { x: number = 2 }
	return new L().x;
}
console.log(f());
`, accepted: false },
		{ name: "unique-name local class with ctor and method works", source: `
function f(): number {
	class M {
		x: number = 0;
		constructor(x: number) { this.x = x; }
		twice(): number { return this.x * 2; }
	}
	return new M(3).twice();
}
console.log(f());
`, accepted: true },
		{ name: "unique-name local class with ctor and method works", source: `
function f(): void { class R { x: number = 1 } }
function g(): void { class R { x: string = "a" } }
`, accepted: false },
		{ name: "local enum / interface / type alias / struct / extern / actor rejected", source: "enum E { A = 1 }\nfunction f(): number { enum E { A = 2 } return 0 }", accepted: false },
		{ name: "local enum / interface / type alias / struct / extern / actor rejected", source: "interface I { x: string }\nfunction f(): void { interface I { x: number } }", accepted: false },
		{ name: "local enum / interface / type alias / struct / extern / actor rejected", source: "function f(): void { type P<T> = T[]; }", accepted: false },
		{ name: "local enum / interface / type alias / struct / extern / actor rejected", source: "struct S { x: string }\nfunction f(): void { struct S { x: number } }", accepted: false },
		{ name: "local enum / interface / type alias / struct / extern / actor rejected", source: "extern function puts(s: cstring): number from \"puts\";\nfunction f(): void { extern function puts(s: cstring): number from \"puts\"; }", accepted: false },
		{ name: "local enum / interface / type alias / struct / extern / actor rejected", source: "actor A { x: number = 1 }\nfunction f(): number { actor A { x: number = 2 } return 5 }", accepted: false },
		{ name: "local extern function and extern const are admitted", source: "function f(): number { extern function myAbs(x: number): number from \"abs\"; return myAbs(0 - 7) }", accepted: true },
		{ name: "local extern function and extern const are admitted", source: "function f(): void { extern const myCVar: number from \"myCVar\"; }", accepted: true },
		{ name: "local extern function and extern const are admitted", source: `
function f(): void { extern function dup(x: number): number from "abs"; }
function g(): void { extern function dup(x: string): number from "atoi"; }
`, accepted: false },
		{ name: "local extern function and extern const are admitted", source: "extern const shared: number from \"shared\";\nfunction f(): void { extern const shared: number from \"shared\"; }", accepted: false },
		{ name: "local macro is admitted, a shadowing one is not", source: `
import { Node } from "std/meta";
function f(): void {
	macro m(): Node {
		return null;
	}
}
`, accepted: true },
		{ name: "local macro is admitted, a shadowing one is not", source: `
import { Node } from "std/meta";
macro m(): Node {
	return null;
}
function f(): void {
	macro m(): Node {
		return null;
	}
}
`, accepted: false },
		{ name: "local actor is admitted", source: "function f(): number { actor A { x: number = 1 } return 5 }", accepted: true },
		{ name: "local actor is admitted", source: "function f(): number { actor A { x: number = 1; get(): number { return this.x; } } const a = new A(); return a.pid != 0 ? 1 : 0; }\nconsole.log(f());", accepted: true },
		{ name: "bare top-level block and arrow body are non-module scopes too", source: "{ class L { x: number = 3 } }", accepted: true },
		{ name: "bare top-level block and arrow body are non-module scopes too", source: "const g = (): number => { class L { x: number = 3 } return 0 };", accepted: true },
		{ name: "bare top-level block and arrow body are non-module scopes too", source: "class L { x: number = 1 }\n{ class L { x: number = 3 } }", accepted: false },
		{ name: "local plain type alias resolves and shadows a module-level alias", source: `
type T = string;
function f(): number {
	type T = number;
	const x: T = 5;
	return x;
}
console.log(f());
`, accepted: true },
		{ name: "local plain type alias resolves and shadows a module-level alias", source: "{ type B = number; const y: B = 1; console.log(y); }", accepted: true },
		{ name: "local plain type alias resolves and shadows a module-level alias", source: "function g(): void { const z: Q = 1; type Q = number; }", accepted: false },
		{ name: "unique-name local interface and struct work; sibling duplicate rejected", source: `
function f(): number {
	interface P { x: number }
	const p: P = { x: 7 };
	return p.x;
}
function g(): number {
	struct Q { y: number }
	const q: Q = { y: 4 };
	return q.y;
}
console.log(f() + g());
`, accepted: true },
		{ name: "unique-name local interface and struct work; sibling duplicate rejected", source: `
function f(): void { interface R { x: number } }
function g(): void { interface R { x: string } }
`, accepted: false },
		{ name: "unique-name local enum works", source: `
function f(): number {
	enum Level { Low = 2, High = 9 }
	const v: Level = Level.High;
	return v as number;
}
console.log(f());
`, accepted: true },
		{ name: "module-level decls and nested functions unaffected", source: `
class L { x: number = 3 }
enum E { A = 1 }
interface I { x: number }
type T = number;
function f(): number {
	function g(): number { return new L().x }
	return g();
}
console.log(f());
`, accepted: true },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == item.accepted, item.name + ": " + item.source;
	}
}

test "declaration identity: duplicate source declarations differ from valid nested scopes" {
	const cases = [
		{ source: "function f(): int32 { const t = 1; const a = t; const t = 2; return a * 10 + t; }", accepted: false },
		{ source: "function f(): int32 { let t = 1; const a = t; let t = 2; return a * 10 + t; }", accepted: false },
		{ source: 'function f(): string { const t = 1; const a = t; const t = "two"; return a.toString() + t; }', accepted: false },
		{ source: 'function mk(s: string): string { return s; } function f(): string { static const t = mk("a"); const a = t; static const t = mk("b"); return a + t; }', accepted: false },
		{ source: "function f(): int32 { const t = 1; { const t = 2; if (t != 2) return 0; } return t; }", accepted: true },
		{ source: "function f(): int32 { const fact = (n: int32): int32 => n <= 1 ? 1 : n * fact(n - 1); return fact(5); }", accepted: true },
		{ source: "function f(flag: boolean): int32 { if (flag) { const t = 1; return t; } else { const t = 2; return t; } }", accepted: true },
	];
	for (const item of cases) {
		assert compileToCWithStd(item.source).ok == item.accepted, item.source;
	}
	assert strictErrorCount("const t = 1; const t = 2;") == 1;
}

const injectedDeclarations = `
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

test "declaration identity: statement injection owns each declared name once" {
	for (const duplicate of [false, true]) {
		const entries: MapEntry[] = [
			{ entryPath: "test/pair.ms", entrySource: injectedDeclarations },
			{ entryPath: "test/main.ms", entrySource: 'import { pair } from "./pair"; function sum(): int32 { pair(); ' + (duplicate ? 'pair(); ' : '') + 'return a * 10 + b; } console.log(sum());' },
		];
		const result = compileProjectToCWithStd(entries, "test/main.ms");
		assert result.contains("ERROR") == duplicate, result;
	}
}
