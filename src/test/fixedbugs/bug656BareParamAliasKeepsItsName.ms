// bug656 — an instance of `type Brand<T> = T` lost its alias name, so a macro reading a node's type no longer saw it
//
// Symptom:    a macro that finds a value by the alias head of its type (`Theme<T>` in a style macro) matched
//             nothing once `Brand<X>` resolved to `X`; Neon theme styles lost their CSS entry on every lane.
//
// Root cause: resolveAnnotation sent an alias whose body is one of its own parameters through the path made for
//             a body that names another declared type, which returns that body and drops the alias.
//
// Fix:        a bare-parameter alias instance stays a GenericInstance headed by the alias while typing reads
//             through it, as Nim keeps a tyGenericInst wrapper that skipTypes strips: member access, method
//             lookup, destructuring, the C pointer decision and the array element forms peel it; an alias whose
//             body names a class, struct, interface, enum or another generic's instance still resolves to that body.
// Macro-visible and runnable on every lane: corpus 681.

import { checkSource, errorCount } from "../handoff/helpers";
import { compileToC, compileToJS } from "../helpers";
import { lookupSymbol } from "../../checker/symbol";
import { Type, TypeKind } from "../../ast/node";

const BRAND = "type Brand656<T> = T;\nfunction mk656<T>(o: T): Brand656<T> { return o; }\n";
const CELL = "class Cell656 { n: int32 = 3; bump(): int32 { this.n = this.n + 1; return this.n; } }\n";
const PT = "struct Pt656 { x: int32; y: int32; }\n";
const NAMED = "class Plain656 { n: int32 = 7; }\ntype Alias656<T> = Plain656;\n";
const WRAPPED = "type Wrapped656<T> = { v: T };\nfunction wrap656<T>(o: T): Wrapped656<T> { return { v: o }; }\n";

function declared(src: string, name: string): Type {
	return lookupSymbol(checkSource(src).table, name).symbolType;
}

function headedBy(t: Type, alias: string): boolean {
	return t.kind == TypeKind.GenericInstance && t.typeName == alias;
}

function emitC(src: string): string {
	const r = compileToC(src);
	return r.ok ? r.value : "error: " + r.error;
}

function emitJs(src: string): string {
	const r = compileToJS(src);
	return r.ok ? r.value : "error: " + r.error;
}

function mentionsBoth(out: string, a: string, b: string): boolean {
	for (const line of out.split("\n")) {
		if (line.indexOf(a, 0) >= 0 && line.indexOf(b, 0) >= 0) return true;
	}
	return false;
}

test "bug656: a bare-parameter alias instance returned by a generic function keeps the alias name" {
	assert headedBy(declared(BRAND + "const o = mk656({ x: 1 });\n", "o"), "Brand656");
	assert headedBy(declared(BRAND + "const n = mk656(5);\n", "n"), "Brand656");
}

test "bug656: a bare-parameter alias instance written as an annotation keeps the alias name" {
	assert headedBy(declared(BRAND + "const a: Brand656<int32> = 3;\n", "a"), "Brand656");
}

test "bug656: a bare-parameter alias instance types as its body" {
	assert errorCount(BRAND + "const n: int32 = mk656(5) + 1;\nconst s: string = mk656(\"x\");\nconst o = mk656({ x: 1 });\nconst k: int32 = o.x;\n") == 0;
	assert errorCount(BRAND + "const a: Brand656<string> = 3;\n") == 1;
}

test "bug656: a method and a field of a class held through a bare-parameter alias instance resolve" {
	assert errorCount(BRAND + CELL + "const c = mk656(new Cell656());\nconst n: int32 = c.bump() + c.n;\n") == 0;
	assert errorCount(BRAND + "const s = mk656(\"hi\");\nconst u: string = s.toUpperCase();\nconst k: int32 = s.length;\n") == 0;
}

test "bug656: an extension called on a bare-parameter alias instance is a call of the extension" {
	const src = BRAND + "function twice656(this x: int32): int32 { return x * 2; }\nconst v = mk656(7);\nconsole.log(mk656(5).twice656() + v.twice656());\n";
	const js = emitJs(src);
	assert js.indexOf("error:", 0) < 0, js;
	assert js.indexOf(".twice656(", 0) < 0, js;
	const c = emitC(src);
	assert c.indexOf("error:", 0) < 0, c;
	assert c.indexOf(".twice656(", 0) < 0, c;
}

test "bug656: a destructured bare-parameter alias instance binds its fields" {
	assert declared(BRAND + "const { x } = mk656({ x: 3 });\n", "x").kind != TypeKind.Inferred;
}

test "bug656: C reads a class held through a bare-parameter alias instance by pointer" {
	const out = emitC(BRAND + CELL + "function peek(c: Brand656<Cell656>): int32 { return c.n; }\nconsole.log(peek(mk656(new Cell656())));\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("(*c).n", 0) >= 0, out;
}

test "bug656: C binds a destructured class held through a bare-parameter alias instance by pointer" {
	const out = emitC(BRAND + CELL + "const { n } = mk656(new Cell656());\nconsole.log(n);\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("dollardestr_0_->n", 0) >= 0, out;
}

test "bug656: C treats an array of bare-parameter alias instances of a class as an array of the class" {
	const out = emitC(BRAND + CELL + "const arr: Brand656<Cell656>[] = [new Cell656()];\narr.push(new Cell656());\narr.length = 1;\nconsole.log(arr[0].n);\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("Destroy(Brand656", 0) < 0, out;
	assert out.indexOf("msRefArraySetLen(", 0) >= 0, out;
}

test "bug656: C names an array of bare-parameter alias instances of a struct after the struct" {
	const out = emitC(BRAND + PT + "const pts: Brand656<Pt656>[] = [{ x: 1, y: 2 }];\nconsole.log(pts[0].x);\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("Pt656Array { int64_t len", 0) >= 0, out;
	assert !mentionsBoth(out, "Brand656", "Array"), out;
}

test "bug656: an alias whose body names a class stays that class" {
	assert !headedBy(declared(NAMED + "const a: Alias656<string> = new Plain656();\n", "a"), "Alias656");
	assert errorCount(NAMED + "const a: Alias656<string> = new Plain656();\nconst p: Plain656 = a;\n") == 0;
}

test "bug656: an alias whose body is a struct literal type never carried a head" {
	assert !headedBy(declared(WRAPPED + "const w = wrap656(7);\n", "w"), "Wrapped656");
	assert errorCount(WRAPPED + "const w = wrap656(7);\nconst n: int32 = w.v;\n") == 0;
}
