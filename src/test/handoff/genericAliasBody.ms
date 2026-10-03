// Route 15e: Checker — a generic alias instance carries its substituted body whatever the body kind

import { strictErrorCount, hasError, errorCount, checkSource } from "./helpers";
import { compileToC, compileToJS } from "../helpers";
import { lookupSymbol } from "../../checker/symbol";
import { Type, TypeKind } from "../../ast/node";

const SETTER = "type Setter<T> = (v: T) => void;\n";
const BOX = "type Box<T> = T[];\n";
const PAIR = "type Pair<T> = [T, T];\n";
const CONSTRAINED = "type Gauge<T extends number> = { value: T };\n";
const TAGGED = "type Tagged<T> = T;\nfunction stamp<T>(o: T): Tagged<T> { return o; }\n";
const COUNTER = "class Counter { n: int32 = 3; bump(): int32 { this.n = this.n + 1; return this.n; } }\n";
const OFFSET = "struct Offset { x: int32; y: int32; }\n";
const NAMED = "class Plain { n: int32 = 7; }\ntype Aliased<T> = Plain;\n";
const ENCLOSED = "type Enclosed<T> = { v: T };\nfunction enclose<T>(o: T): Enclosed<T> { return { v: o }; }\n";

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

// ===== Function body =====

test "a generic alias over a function type accepts a matching arrow in a field" {
	assert strictErrorCount(SETTER + "interface Cell<T> { set: Setter<T>; }\nconst c: Cell<int32> = { set: (v: int32) => {} };") == 0;
}

test "a generic alias over a function type is callable with the substituted parameter" {
	assert strictErrorCount(SETTER + "const s: Setter<int32> = (v: int32) => {};\ns(1);") == 0;
	assert strictErrorCount(SETTER + "const s: Setter<int32> = (v: int32) => {};\ns(\"x\");") == 1;
}

test "a generic alias over a function type flows into the matching function slot" {
	assert strictErrorCount(SETTER + "function take(f: (v: int32) => void): void { f(1); }\nconst s: Setter<int32> = (v: int32) => {};\ntake(s);") == 0;
}

test "a generic alias over a function type rejects a different instantiation" {
	assert strictErrorCount(SETTER + "function take(f: Setter<string>): void {}\nconst s: Setter<int32> = (v: int32) => {};\ntake(s);") == 1;
}

test "a generic alias over a function type returns from a generic function" {
	assert strictErrorCount(SETTER + "function mk<T>(): [() => T, Setter<T>] { let cur: T = 0 as T; return [() => cur, (v: T) => { cur = v; }]; }\nconst [g, s] = mk<int32>();\ns(2);\nconst n: int32 = g();") == 0;
}

// ===== Array and tuple bodies =====

test "a generic alias over an array type returns from a generic function" {
	assert strictErrorCount(BOX + "function mk<T>(x: T): Box<T> { return [x]; }\nconst xs: Box<int32> = mk<int32>(1);\nconst n: int32 = xs.length;") == 0;
}

test "a generic alias over a tuple type indexes to the substituted element" {
	assert strictErrorCount(PAIR + "function mk<T>(x: T): Pair<T> { return [x, x]; }\nconst p: Pair<int32> = mk<int32>(1);\nconst a: int32 = p[0];") == 0;
}

// ===== Distinct stays nominal =====

test "a generic distinct over a function type still refuses a bare arrow" {
	assert hasError("type Thunk<T> = distinct (() => T);\nconst t: Thunk<int32> = () => 1;", "is not assignable to type 'Thunk<int32>'");
}

test "a generic alias whose parameter carries a constraint substitutes its argument into the body" {
	assert strictErrorCount(CONSTRAINED + "const g: Gauge<int32> = { value: 42 };\nconst n: int32 = g.value;") == 0;
	assert hasError(CONSTRAINED + "const g: Gauge<int32> = { value: 42 };\nconst s: string = g.value;", "Type 'int32' is not assignable to type 'string'");
}

test "a bare-parameter alias instance returned by a generic function keeps the alias name" {
	assert headedBy(declared(TAGGED + "const o = stamp({ x: 1 });\n", "o"), "Tagged");
	assert headedBy(declared(TAGGED + "const n = stamp(5);\n", "n"), "Tagged");
}

test "a bare-parameter alias instance written as an annotation keeps the alias name" {
	assert headedBy(declared(TAGGED + "const a: Tagged<int32> = 3;\n", "a"), "Tagged");
}

test "a bare-parameter alias instance types as its argument" {
	assert errorCount(TAGGED + "const n: int32 = stamp(5) + 1;\nconst s: string = stamp(\"x\");\nconst o = stamp({ x: 1 });\nconst k: int32 = o.x;\n") == 0;
	assert errorCount(TAGGED + "const a: Tagged<string> = 3;\n") == 1;
}

test "a bare-parameter alias instance resolves the members of its argument" {
	assert errorCount(TAGGED + COUNTER + "const c = stamp(new Counter());\nconst n: int32 = c.bump() + c.n;\n") == 0;
	assert errorCount(TAGGED + "const s = stamp(\"hi\");\nconst u: string = s.toUpperCase();\nconst k: int32 = s.length;\n") == 0;
}

test "an extension called on a bare-parameter alias instance is a call of the extension" {
	const src = TAGGED + "function doubled(this x: int32): int32 { return x * 2; }\nconst v = stamp(7);\nconsole.log(stamp(5).doubled() + v.doubled());\n";
	const js = emitJs(src);
	assert js.indexOf("error:", 0) < 0, js;
	assert js.indexOf(".doubled(", 0) < 0, js;
	const c = emitC(src);
	assert c.indexOf("error:", 0) < 0, c;
	assert c.indexOf(".doubled(", 0) < 0, c;
}

test "a destructured bare-parameter alias instance binds its fields" {
	assert declared(TAGGED + "const { x } = stamp({ x: 3 });\n", "x").kind != TypeKind.Inferred;
}

test "C binds a destructured class held through a bare-parameter alias instance by pointer" {
	const out = emitC(TAGGED + COUNTER + "const { n } = stamp(new Counter());\nconsole.log(n);\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("dollardestr_0_->n", 0) >= 0, out;
}

test "C treats an array of bare-parameter alias instances of a class as an array of the class" {
	const out = emitC(TAGGED + COUNTER + "const arr: Tagged<Counter>[] = [new Counter()];\narr.push(new Counter());\narr.length = 1;\nconsole.log(arr[0].n);\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("Destroy(Tagged", 0) < 0, out;
	assert out.indexOf("msRefArraySetLen(", 0) >= 0, out;
}

test "C names an array of bare-parameter alias instances of a struct after the struct" {
	const out = emitC(TAGGED + OFFSET + "const pts: Tagged<Offset>[] = [{ x: 1, y: 2 }];\nconsole.log(pts[0].x);\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("OffsetArray { int64_t len", 0) >= 0, out;
	assert !mentionsBoth(out, "Tagged", "Array"), out;
}

test "an alias whose body names a class is that class and carries no alias head" {
	assert !headedBy(declared(NAMED + "const a: Aliased<string> = new Plain();\n", "a"), "Aliased");
	assert errorCount(NAMED + "const a: Aliased<string> = new Plain();\nconst p: Plain = a;\n") == 0;
}

test "an alias whose body is a struct literal type carries no alias head" {
	assert !headedBy(declared(ENCLOSED + "const w = enclose(7);\n", "w"), "Enclosed");
	assert errorCount(ENCLOSED + "const w = enclose(7);\nconst n: int32 = w.v;\n") == 0;
}
