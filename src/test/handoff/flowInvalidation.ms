import { strictErrorCount } from "./helpers";
import { checkModuleGraph, getPreludeContext } from "../../checker/orchestrator";
import { GcMode } from "../../checker/context";
import { hostTargetInfo } from "../../checker/types";
import { findModule, ErrorSeverity } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";
import { platform } from "std/process";

test "flowInvalidation: narrowing survives only while its dependency path is unchanged" {
	const cases = [
		{ name: "assigning the object a variant was read through drops the narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nclass Box { d: D = { kind: K.Str, text: \"s\" }; tag: int32 = 0; }\nfunction f(first: Box, other: Box): string {\n\tlet b = first;\n\tif (b.d.kind == K.Str) { b = other; return b.d.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "assigning a deeper prefix drops the narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nclass Box { d: D = { kind: K.Str, text: \"s\" }; tag: int32 = 0; }\nclass Outer { inner: Box = new Box(); }\nfunction f(o: Outer, other: Box): string {\n\tif (o.inner.d.kind == K.Str) { o.inner = other; return o.inner.d.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "assigning or stepping the index variable drops the element narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction f(xs: D[]): string {\n\tlet i: int32 = 0;\n\tif (xs[i].kind == K.Str) { i = 1; return xs[i].text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "assigning or stepping the index variable drops the element narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction f(xs: D[]): string {\n\tlet i: int32 = 0;\n\tif (xs[i].kind == K.Str) { i++; return xs[i].text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "a write beside the narrowed reference keeps the narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nclass Box { d: D = { kind: K.Str, text: \"s\" }; tag: int32 = 0; }\nfunction f(b: Box, xs: D[]): string {\n\tlet i: int32 = 0;\n\tlet j: int32 = 0;\n\tif (b.d.kind == K.Str && xs[i].kind == K.Str) { b.tag = 3; j = j + 1; return b.d.text + xs[i].text; }\n\treturn \"\";\n}\n", expected: 0 },
		{ name: "a write after the alias drops its narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction f(first: D, other: D, flag: boolean): string {\n\tlet d: D = first;\n\tconst isStr = d.kind == K.Str;\n\tif (flag) { d = other; }\n\tif (isStr) { return d.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "a write to a field the alias was read through drops its narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nclass Box { d: D = { kind: K.Str, text: \"s\" }; }\nfunction f(b: Box, other: D): string {\n\tconst isStr = b.d.kind == K.Str;\n\tb.d = other;\n\tif (isStr) { return b.d.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "a write on the loop back edge drops the narrowing inside the loop", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction f(xs: D[]): string {\n\tlet d: D = xs[0];\n\tconst isStr = d.kind == K.Str;\n\tlet out = \"\";\n\tfor (const x of xs) { if (isStr) { out = out + d.text; } d = x; }\n\treturn out;\n}\n", expected: -1 },
		{ name: "an alias computed after the last write, or over a const, keeps narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction f(first: D, second: D): string {\n\tlet d: D = first;\n\td = second;\n\tconst isStr = d.kind == K.Str;\n\tconst fixed: D = first;\n\tconst fixedStr = fixed.kind == K.Str;\n\tlet out = \"\";\n\tif (isStr) { out = out + d.text; }\n\tif (fixedStr) { out = out + fixed.text; }\n\treturn out;\n}\n", expected: 0 },
		{ name: "a local passed to a ref or out parameter loses its narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction setNum(ref x: D): void { x = { kind: K.Num, a: 3 }; }\nfunction f(first: D): string {\n\tlet d: D = first;\n\tif (d.kind == K.Str) { setNum(d); return d.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "a local passed to a ref or out parameter loses its narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction setNum(ref x: D): void { x = { kind: K.Num, a: 3 }; }\nfunction fill(out x: D): void { x = { kind: K.Num, a: 3 }; }\nfunction f(first: D): string {\n\tlet d: D = first;\n\tif (d.kind == K.Str) { fill(out d); return d.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "a field passed to a ref parameter loses its narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction setNum(ref x: D): void { x = { kind: K.Num, a: 3 }; }\nstruct Holder { d: D; }\nfunction f(first: D): string {\n\tlet h: Holder = { d: first };\n\tif (h.d.kind == K.Str) { setNum(h.d); return h.d.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "a mutating array method drops the narrowing of an element", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction setNum(ref x: D): void { x = { kind: K.Num, a: 3 }; }\nfunction f(xs: D[]): string {\n\tif (xs[0].kind == K.Str) { xs.splice(0, 1); return xs[0].text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "a by-value argument keeps the narrowing", source: "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\nfunction setNum(ref x: D): void { x = { kind: K.Num, a: 3 }; }\nfunction show(x: D): int32 { return x.kind == K.Str ? 1 : 0; }\nfunction f(first: D, xs: D[]): string {\n\tlet d: D = first;\n\tif (d.kind == K.Str && xs[0].kind == K.Str) { show(d); show(xs[0]); return d.text + xs[0].text; }\n\treturn \"\";\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "flowInvalidation: unreachable values have no readable members" {
	const cases = [
		{ name: "a member read on a parameter narrowed to never is refused", source: "function f(v: int32): int32 {\n\tif (typeof v === \"string\") { return v.length; }\n\treturn 0;\n}\n", expected: -1 },
		{ name: "a member read on a union or a let narrowed to never is refused", source: "function f(v: int32 | boolean): int32 {\n\tif (typeof v === \"string\") { return v.length; }\n\treturn 0;\n}\n", expected: -1 },
		{ name: "a member read on a union or a let narrowed to never is refused", source: "function f(): int32 {\n\tlet v: int32 | string = 12345;\n\tif (typeof v === \"string\") { const n: int32 = v.length + 1; return n; }\n\treturn 0;\n}\n", expected: -1 },
		{ name: "passing never along and a generic typeof arm stay accepted", source: "function f(v: int32): int32 {\n\tif (typeof v === \"string\") { console.log(v); return 1; }\n\treturn 0;\n}\nfunction g<T>(x: T): int32 {\n\tif (typeof x === \"number\") { return 1; }\n\treturn 0;\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "flowInvalidation: nondefaultable locals require assignment on every incoming path" {
	const cases = [
		{ name: "reading a class local assigned on one branch only is refused", source: "class Foo { x: int32 = 7; }\nfunction f(flag: boolean): int32 {\n\tlet o: Foo;\n\tif (flag) { o = new Foo(); }\n\treturn o.x;\n}\n", expected: -1 },
		{ name: "a function local, an array local and a struct holding a function are refused", source: "function f(flag: boolean): int32 {\n\tlet cb: () => int32;\n\tif (flag) { cb = (): int32 => 42; }\n\treturn cb();\n}\n", expected: -1 },
		{ name: "a function local, an array local and a struct holding a function are refused", source: "function f(n: int32): int32 {\n\tlet xs: int32[];\n\tfor (let i = 0; i < n; i++) { xs = [i]; }\n\treturn xs.length;\n}\n", expected: -1 },
		{ name: "a function local, an array local and a struct holding a function are refused", source: "struct S { cb: () => int32; }\nfunction f(flag: boolean): int32 {\n\tlet s: S;\n\tif (flag) { s = { cb: (): int32 => 1 }; }\n\treturn s.cb();\n}\n", expected: -1 },
		{ name: "every branch assigning, a later closure read and a number stay accepted", source: "class Foo { x: int32 = 7; }\nenum E { A, B }\nfunction f(flag: boolean, e: E): int32 {\n\tlet o: Foo;\n\tif (flag) { o = new Foo(); } else { o = new Foo(); }\n\tlet p: Foo;\n\tmatch (e) { E.A => { p = new Foo(); }, E.B => { p = new Foo(); } };\n\tlet cb: () => int32;\n\tcb = (): int32 => 3;\n\tconst g = (): int32 => cb();\n\tlet n: int32;\n\tif (flag) { n = 1; }\n\treturn o.x + p.x + g() + n;\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "flowInvalidation: mixed representation unions expose only a stable discriminant" {
	const cases = [
		{ name: "the discriminant of a mixed union reads without narrowing", source: "struct Pt { kind: \"pt\"; name: string; x: int32 }\ninterface Nd { kind: \"nd\"; name: string }\ntype Mixed = Pt | Nd;\nfunction tag(m: Mixed): string { return m.kind; }\n", expected: 0 },
		{ name: "the discriminant of a mixed union reads without narrowing", source: "struct Ok { ok: true; v: int32 }\ninterface Er { ok: false; msg: string }\ntype Res = Ok | Er;\nfunction okOf(r: Res): boolean { return r.ok; }\n", expected: 0 },
		{ name: "a shared field of an inline and a reference variant needs narrowing", source: "struct Pt { kind: \"pt\"; name: string; x: int32 }\ninterface Nd { kind: \"nd\"; name: string }\ntype Mixed = Pt | Nd;\nfunction nameOf(m: Mixed): string { return m.name; }\n", expected: -1 },
		{ name: "a shared field of an inline and a reference variant needs narrowing", source: "struct Pt { kind: \"pt\"; name: string; x: int32 }\ninterface Nd { kind: \"nd\"; name: string }\ntype Mixed = Pt | Nd;\nfunction nameOf(m: Mixed): string {\n\tif (m.kind === \"pt\") return m.name;\n\treturn m.name;\n}\n", expected: 0 },
		{ name: "a discriminant at different offsets stays refused", source: "struct A { x: int32; kind: \"a\" }\nstruct B { kind: \"b\"; y: int32 }\ntype AB = A | B;\nfunction k(u: AB): string { return u.kind; }\n", expected: -1 },
		{ name: "a write to a string or boolean discriminant is refused", source: "struct Pt { kind: \"pt\"; name: string; x: int32 }\ninterface Nd { kind: \"nd\"; name: string }\ntype Mixed = Pt | Nd;\nfunction setPt(m: Mixed): void { m.kind = \"pt\"; }\n", expected: -1 },
		{ name: "a write to a string or boolean discriminant is refused", source: "struct Pt { kind: \"pt\"; name: string; x: int32 }\ninterface Nd { kind: \"nd\"; name: string }\ntype Mixed = Pt | Nd;\nfunction relabel(m: Mixed): void {\n\tif (m.kind === \"nd\") {\n\t\tm.kind = \"nd\";\n\t}\n}\n", expected: -1 },
		{ name: "a write to a string or boolean discriminant is refused", source: "struct Ok { ok: true; v: int32 }\ninterface Er { ok: false; msg: string }\ntype Res = Ok | Er;\nfunction flip(r: Res): void { r.ok = false; }\n", expected: -1 },
		{ name: "the enum discriminant of a mixed union reads without narrowing", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32; name: string }\nstruct Av { kind: K.A; x: int32; name: string }\ntype E = Bv | Av;\nfunction isA(e: E): boolean { return e.kind === K.A; }\n", expected: 0 },
		{ name: "the enum discriminant of a mixed union reads without narrowing", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32; name: string }\nstruct Av { kind: K.A; x: int32; name: string }\ntype E = Bv | Av;\nfunction tagOf(e: E): K { return e.kind; }\n", expected: 0 },
		{ name: "the enum discriminant of a mixed union reads without narrowing", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32; name: string }\nstruct Av { kind: K.A; x: int32; name: string }\ntype E = Bv | Av;\nfunction nm(e: E): string { return match (e.kind) { K.A => \"a\", K.B => \"b\" }; }\n", expected: 0 },
		{ name: "the enum discriminant of a mixed union reads without narrowing", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32; name: string }\nstruct Av { kind: K.A; x: int32; name: string }\ntype E = Bv | Av;\nfunction xOf(e: E): int32 {\n\tif (e.kind === K.A) return e.x;\n\treturn e.y;\n}\n", expected: 0 },
		{ name: "the enum discriminant reads in either variant order and through an unaliased union", source: "enum K { A, B }\nstruct Av { kind: K.A; x: int32 }\ninterface Bv { kind: K.B; y: int32 }\ntype E = Av | Bv;\nfunction isA(e: E): boolean { return e.kind == K.A; }\n", expected: 0 },
		{ name: "the enum discriminant reads in either variant order and through an unaliased union", source: "enum K { A, B }\nstruct Av { kind: K.A; x: int32 }\ninterface Bv { kind: K.B; y: int32 }\nfunction isA(e: Bv | Av): boolean { return e.kind == K.A; }\n", expected: 0 },
		{ name: "the enum discriminant reads in either variant order and through an unaliased union", source: "interface Nd { kind: \"nd\"; y: int32 }\nstruct Pt { kind: \"pt\"; x: int32 }\nfunction isPt(m: Nd | Pt): boolean { return m.kind == \"pt\"; }\n", expected: 0 },
		{ name: "a shared field that is not the discriminant still needs narrowing", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32; name: string }\nstruct Av { kind: K.A; x: int32; name: string }\ntype E = Bv | Av;\nfunction nm(e: E): string { return e.name; }\n", expected: -1 },
		{ name: "a shared field that is not the discriminant still needs narrowing", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32; name: string }\nstruct Av { kind: K.A; x: int32; name: string }\ntype E = Bv | Av;\nfunction nm(e: E): string {\n\tif (e.kind === K.A) return e.name;\n\treturn e.name;\n}\n", expected: 0 },
		{ name: "a write to an enum discriminant is refused", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32; name: string }\nstruct Av { kind: K.A; x: int32; name: string }\ntype E = Bv | Av;\nfunction flip(e: E): void { e.kind = K.B; }\n", expected: -1 },
		{ name: "a write to an enum discriminant is refused", source: "enum K { A, B }\ninterface Bv { kind: K.B; y: int32 }\ninterface Av { kind: K.A; x: int32 }\ntype E = Bv | Av;\nfunction flip(e: E): void { e.kind = K.B; }\n", expected: -1 },
		{ name: "a write to an enum discriminant is refused", source: "enum S { A, B }\ntype D = match (kind: S) { S.A => { x: int32 }, S.B => { y: string } };\nfunction flip(d: D): void { d.kind = S.B; }\n", expected: -1 },
		{ name: "a write to an enum discriminant is refused", source: "enum S { A, B }\ntype D = match (kind: S) { S.A => { x: int32 }, S.B => { y: string } };\nfunction keep(d: D): void {\n\tif (d.kind == S.A) {\n\t\td.kind = S.A;\n\t}\n}\n", expected: -1 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

function strictWarnings(source: string, strictDefs: boolean, strictNil: boolean): int32 {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: "/src/strictPolicy.ms", entrySource: source },
		{ entryPath: "/src/strictEntry.ms", entrySource: "import \"./strictPolicy\";" },
	];
	const graph = loadModuleGraph("/src/strictEntry.ms", createMapProvider(entries));
	checkModuleGraph(graph, "", ".cms", platform, hostTargetInfo(), GcMode.Orc, null, null, strictDefs, strictNil);
	const mod = findModule(graph, "/src/strictPolicy.ms");
	if (mod == null) return -1;
	let warnings: int32 = 0;
	for (const error of mod.errors) if (error.severity == ErrorSeverity.Warning) warnings += 1;
	return warnings;
}

test "flow invalidation: strict policies reach dependencies and do not leak into later checks" {
	const unassigned = "function f(flag: boolean): int32 { let n: int32; if (flag) { n = 5; } return n; }";
	const nullable = "class Box { x: int32 = 7; } function f(): int32 { let box: Box | null = new Box(); const read = (): int32 => box.x; return read(); }";
	const nonnull = "class Box { x: int32 = 7; } function f(box: Box): int32 { return box.x; }";
	const relaxedDefs = strictWarnings(unassigned, false, false);
	assert relaxedDefs >= 0;
	assert strictWarnings(unassigned, true, false) > relaxedDefs;
	const relaxedNil = strictWarnings(nullable, false, false);
	assert relaxedNil >= 0;
	assert strictWarnings(nullable, false, true) > relaxedNil;
	assert strictWarnings(nonnull, false, true) == strictWarnings(nonnull, false, false);
	strictWarnings(unassigned, true, true);
	assert strictWarnings(unassigned, false, false) == relaxedDefs;
	const prelude = getPreludeContext();
	assert prelude != null && !prelude.strictDefs && !prelude.strictNullChecks;
}
