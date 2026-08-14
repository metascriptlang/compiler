// bug106 — local declarations: the collect pass never sees non-module-scope decls
//
// Symptom:    a class/enum/interface/type/struct/extern/actor/macro declared
//             inside a function body, arrow body, bare block, or test block is
//             parsed but never collected. Unique names die at the USE site
//             ("Undefined variable 'L'" — nothing at the decl); a local decl
//             SHADOWING a same-named module-level decl silently binds the
//             OUTER one: C printed the outer field value (1), JS printed
//             undefined (raw nested emit, colliding mangled name), vs 2 for
//             TS/Nim. Local extern passed the checker and died at link
//             ("undefined symbol: _dollarfn_f_1_").
// Root cause: collectTopLevel (collectPass.ms) walks only programStmts;
//             checkStmt's decl arms either no-op silently (Interface/Struct/
//             Enum/TypeAlias/Extern group) or return on a null lookupSymbol
//             (checkClassDecl:592) — the MS silent fallthrough where Nim is
//             loud (internalError shape). Nim enters type symbols into the
//             CURRENT scope: typeDefLeftSidePass (semstmts.nim:1444) ->
//             addInterfaceDeclAt(c, c.currentScope, sym) (lookups.nim:435).
// Fix:        Stage 1 (this): located error at the decl for the eight decl
//             kinds when the current scope is not Module/Global — Nim
//             loud-fallthrough parity. Stage 2 (separate arc): true local
//             support = register in current scope + per-block lifted mangling
//             (NIM-REF "Test-block local declarations" residual mechanism,
//             scope-qualified mangle keys).

import { compileToC, compileToCWithStd } from "../helpers";

test "bug106: local class shadowing a module-level class is rejected (was: silent wrong answer)" {
	const c = compileToC(`
class L { x: number = 1 }
function f(): number {
	class L { x: number = 2 }
	return new L().x;
}
console.log(f());
`);
	assert !c.ok;
	assert c.error.indexOf("local class", 0) >= 0;
}

test "bug106 stage2: unique-name local class with ctor and method works" {
	const c = compileToC(`
function f(): number {
	class M {
		x: number = 0;
		constructor(x: number) { this.x = x; }
		twice(): number { return this.x * 2; }
	}
	return new M(3).twice();
}
console.log(f());
`);
	assert c.ok;

	const cSibling = compileToC(`
function f(): void { class R { x: number = 1 } }
function g(): void { class R { x: string = "a" } }
`);
	assert !cSibling.ok;
	assert cSibling.error.indexOf("local class", 0) >= 0;
}

test "bug106: local enum / interface / type alias / struct / extern / actor rejected" {
	const cEnum = compileToC("enum E { A = 1 }\nfunction f(): number { enum E { A = 2 } return 0 }");
	assert !cEnum.ok;
	assert cEnum.error.indexOf("local enum", 0) >= 0;

	const cIface = compileToC("interface I { x: string }\nfunction f(): void { interface I { x: number } }");
	assert !cIface.ok;
	assert cIface.error.indexOf("local interface", 0) >= 0;

	const cAliasGeneric = compileToC("function f(): void { type P<T> = T[]; }");
	assert !cAliasGeneric.ok;
	assert cAliasGeneric.error.indexOf("local type alias", 0) >= 0;

	const cStruct = compileToC("struct S { x: string }\nfunction f(): void { struct S { x: number } }");
	assert !cStruct.ok;
	assert cStruct.error.indexOf("local struct", 0) >= 0;

	const cExtern = compileToC("extern function puts(s: cstring): number from \"puts\";\nfunction f(): void { extern function puts(s: cstring): number from \"puts\"; }");
	assert !cExtern.ok;
	assert cExtern.error.indexOf("local extern function", 0) >= 0;

	const cActor = compileToC("actor A { x: number = 1 }\nfunction f(): number { actor A { x: number = 2 } return 5 }");
	assert !cActor.ok;
	assert cActor.error.indexOf("local actor", 0) >= 0;
}

test "bug106 stage2: local extern function and extern const are admitted" {
	const cFn = compileToC("function f(): number { extern function myAbs(x: number): number from \"abs\"; return myAbs(0 - 7) }");
	assert cFn.ok;

	const cConst = compileToC("function f(): void { extern const myCVar: number from \"myCVar\"; }");
	assert cConst.ok;

	const cSibling = compileToC(`
function f(): void { extern function dup(x: number): number from "abs"; }
function g(): void { extern function dup(x: string): number from "atoi"; }
`);
	assert !cSibling.ok;
	assert cSibling.error.indexOf("local extern function", 0) >= 0;

	const cVarShadow = compileToC("extern const shared: number from \"shared\";\nfunction f(): void { extern const shared: number from \"shared\"; }");
	assert !cVarShadow.ok;
	assert cVarShadow.error.indexOf("local extern", 0) >= 0;
}

test "bug106 stage2: local macro is admitted, a shadowing one is not" {
	const c = compileToCWithStd(`
import { Node } from "std/meta";
function f(): void {
	macro m(): Node {
		return null;
	}
}
`);
	assert c.ok;

	const cShadow = compileToCWithStd(`
import { Node } from "std/meta";
macro m(): Node {
	return null;
}
function f(): void {
	macro m(): Node {
		return null;
	}
}
`);
	assert !cShadow.ok;
	assert cShadow.error.indexOf("local macro", 0) >= 0;
}

test "bug106 stage2: local actor is admitted" {
	const c = compileToC("function f(): number { actor A { x: number = 1 } return 5 }");
	assert c.ok;
}

test "bug106: bare top-level block and arrow body are non-module scopes too" {
	const cBlock = compileToC("{ class L { x: number = 3 } }");
	assert cBlock.ok;

	const cArrow = compileToC("const g = (): number => { class L { x: number = 3 } return 0 };");
	assert cArrow.ok;

	const cBlockShadow = compileToC("class L { x: number = 1 }\n{ class L { x: number = 3 } }");
	assert !cBlockShadow.ok;
	assert cBlockShadow.error.indexOf("local class", 0) >= 0;
}

test "bug106 stage2: local plain type alias resolves and shadows a module-level alias" {
	const c = compileToC(`
type T = string;
function f(): number {
	type T = number;
	const x: T = 5;
	return x;
}
console.log(f());
`);
	assert c.ok;

	const cBlock = compileToC("{ type B = number; const y: B = 1; console.log(y); }");
	assert cBlock.ok;

	const cUseBefore = compileToC("function g(): void { const z: Q = 1; type Q = number; }");
	assert !cUseBefore.ok;
}

test "bug106 stage2: unique-name local interface and struct work; sibling duplicate rejected" {
	const c = compileToC(`
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
`);
	assert c.ok;

	const cSibling = compileToC(`
function f(): void { interface R { x: number } }
function g(): void { interface R { x: string } }
`);
	assert !cSibling.ok;
	assert cSibling.error.indexOf("local interface", 0) >= 0;
}

test "bug106 stage2: unique-name local enum works" {
	const c = compileToC(`
function f(): number {
	enum Level { Low = 2, High = 9 }
	const v: Level = Level.High;
	return v as number;
}
console.log(f());
`);
	assert c.ok;
}

test "bug106: module-level decls and nested functions unaffected" {
	const c = compileToC(`
class L { x: number = 3 }
enum E { A = 1 }
interface I { x: number }
type T = number;
function f(): number {
	function g(): number { return new L().x }
	return g();
}
console.log(f());
`);
	assert c.ok;
}
