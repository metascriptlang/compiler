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

test "bug106: local class with a unique name errors at the decl, not only the use site" {
	const c = compileToC(`
function f(): number {
	class M { x: number = 3 }
	return new M().x;
}
`);
	assert !c.ok;
	assert c.error.indexOf("local class", 0) >= 0;
}

test "bug106: local enum / interface / type alias / struct / extern / actor rejected" {
	const cEnum = compileToC("function f(): number { enum E { A = 2 } return 0 }");
	assert !cEnum.ok;
	assert cEnum.error.indexOf("local enum", 0) >= 0;

	const cIface = compileToC("function f(): void { interface I { x: number } }");
	assert !cIface.ok;
	assert cIface.error.indexOf("local interface", 0) >= 0;

	const cAlias = compileToC("function f(): void { type T = number; }");
	assert !cAlias.ok;
	assert cAlias.error.indexOf("local type alias", 0) >= 0;

	const cStruct = compileToC("function f(): void { struct S { x: number } }");
	assert !cStruct.ok;
	assert cStruct.error.indexOf("local struct", 0) >= 0;

	const cExtern = compileToC("function f(): void { extern function puts(s: cstring): number from \"puts\"; }");
	assert !cExtern.ok;
	assert cExtern.error.indexOf("local extern", 0) >= 0;

	const cActor = compileToC("function f(): number { actor A { x: number = 1 } return 5 }");
	assert !cActor.ok;
	assert cActor.error.indexOf("local actor", 0) >= 0;
}

test "bug106: local macro rejected" {
	const c = compileToCWithStd(`
import { Node } from "std/meta";
function f(): void {
	macro m(): Node {
		return null;
	}
}
`);
	assert !c.ok;
	assert c.error.indexOf("local macro", 0) >= 0;
}

test "bug106: bare top-level block and arrow body are non-module scopes too" {
	const cBlock = compileToC("{ class L { x: number = 3 } }");
	assert !cBlock.ok;
	assert cBlock.error.indexOf("local class", 0) >= 0;

	const cArrow = compileToC("const g = (): number => { class L { x: number = 3 } return 0 };");
	assert !cArrow.ok;
	assert cArrow.error.indexOf("local class", 0) >= 0;
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
