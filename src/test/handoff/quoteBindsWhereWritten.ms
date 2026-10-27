import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function problems(entries: MapEntry[]): string[] {
	const kept: string[] = [];
	for (const m of checkProjectDiagnostics(entries, "test/main.ms")) {
		if (!m.endsWith("is declared but never used") && !m.endsWith("is imported but never used")) kept.push(m);
	}
	return kept;
}

function buildFailure(entries: MapEntry[], label: string): string {
	const found = problems(entries);
	if (found.length > 0) return label + ": " + found.join(" | ");
	const c = compileProjectToCWithStd(entries, "test/main.ms");
	if (c.indexOf("ERROR", 0) >= 0) return label + ": " + c;
	const js = compileProjectToJSWithStd(entries, "test/main.ms");
	if (js.indexOf("ERROR", 0) >= 0) return label + ": " + js;
	return "";
}

function failures(cases: string[]): string {
	return cases.filter((r: string): boolean => r != "").join("\n");
}

const libDecls = `
export const LIMIT: int32 = 100;
export function helper(): int32 { return 100; }
export class Box { v: int32 = 100; }
export struct Pair { a: int64; b: int64; }
`;

function libWith(quoted: string): string {
	return `import { Node } from "std/meta";
${libDecls}
export macro m(x: Node): Node { return quote { ${quoted} }; }
`;
}

// The caller's namesakes have other types, so a name rebound at the expansion is a type error.
const callerNamesakes = `
const LIMIT: string = "caller";
function helper(): string { return "caller"; }
class Box { w: string = "caller"; }
class Pair { w: string = "caller"; }
`;

function callerOf(decls: string, use: string, type: string = "int32"): MapEntry {
	return { entryPath: "test/main.ms", entrySource: `import { m } from "./lib";\n${decls}\nconst r: ${type} = ${use};\nconsole.log(r);\n` };
}

test "quoteBindsWhereWritten: a const, a call and a new in a quote name the macro module's declarations" {
	const lib: MapEntry = { entryPath: "test/lib.ms", entrySource: libWith("LIMIT") };
	const bad = failures([
		buildFailure([lib, callerOf(callerNamesakes, "m(0)")], "const"),
		buildFailure([lib, callerOf(callerNamesakes + "function inBody(): int32 { const LIMIT: string = \"local\"; return m(0); }\n", "inBody()")], "const in a function body"),
		buildFailure([{ entryPath: "test/lib.ms", entrySource: libWith("helper()") }, callerOf(callerNamesakes, "m(0)")], "call"),
		buildFailure([{ entryPath: "test/lib.ms", entrySource: libWith("new Box().v") }, callerOf(callerNamesakes, "m(0)")], "new"),
	]);
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: a quote beside a local namesake in the same module names the module declaration" {
	const source = `import { Node } from "std/meta";
export const LIMIT: int32 = 100;
export function helper(): int32 { return 100; }
export macro m(x: Node): Node { return quote { LIMIT + helper() }; }
function use(): int32 {
	const LIMIT: string = "local";
	function helper(): string { return "local"; }
	const r: int32 = m(0);
	return r;
}
console.log(use());
`;
	const bad = buildFailure([{ entryPath: "test/main.ms", entrySource: source }], "same module");
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: a quote names an import of its macro module by the alias written there" {
	const lib = `import { Node } from "std/meta";
import { LIMIT as L, helper as h } from "./base";
export macro m(x: Node): Node { return quote { L + h() }; }
`;
	const base = libDecls;
	const bad = failures([
		buildFailure([
			{ entryPath: "test/base.ms", entrySource: base },
			{ entryPath: "test/lib.ms", entrySource: lib },
			callerOf(`const L: string = "caller";\nfunction h(): string { return "caller"; }`, "m(0)"),
		], "alias beside caller namesakes"),
		buildFailure([
			{ entryPath: "test/base.ms", entrySource: base },
			{ entryPath: "test/lib.ms", entrySource: lib },
			callerOf("", "m(0)"),
		], "alias with no caller namesake"),
	]);
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: a name unbound where the quote is written resolves where it expands" {
	const lib = `import { Node } from "std/meta";
export macro m(x: Node): Node { return quote { later() }; }
`;
	const bad = buildFailure([
		{ entryPath: "test/lib.ms", entrySource: lib },
		callerOf("function later(): int32 { return 5; }", "m(0)"),
	], "open name");
	assert bad == "", bad;
}

function stdLib(macros: string): MapEntry {
	return { entryPath: "test/lib.ms", entrySource: `import { Node } from "std/meta";\n${macros}\n` };
}

function stmtCaller(decls: string, use: string): MapEntry {
	return { entryPath: "test/main.ms", entrySource: `import { m } from "./lib";\n${decls}\n${use}\n` };
}

test "quoteBindsWhereWritten: a quote naming a std value, namespace or function is not captured by a caller namesake" {
	const bad = failures([
		buildFailure([
			stdLib(`export macro m(x: Node): Node { return quote { console.log(7) }; }`),
			stmtCaller(`const console = { log: (s: string): void => {} };`, "m(0);"),
		], "std value"),
		buildFailure([
			stdLib(`export macro m(x: Node): Node { return quote { Math.floor(2.5) }; }`),
			callerOf(`const Math = { floor: (n: number): string => "caller" };`, "m(0)", "number"),
		], "std namespace object"),
		buildFailure([
			stdLib(`export macro m(x: Node): Node { return quote { parseInt("5") }; }`),
			callerOf(`function parseInt(s: string): string { return "caller"; }`, "m(0)", "int64"),
		], "std function"),
		buildFailure([
			stdLib(`export macro m(x: Node): Node { return quote { Math.floor(2.5) }; }`),
			callerOf("", "m(0)", "number"),
		], "std namespace object with no caller namesake"),
	]);
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: identifiers inside a class declared in a quote name the declarations visible where it is written" {
	const lib = `import { Node } from "std/meta";
export const LIMIT: int32 = 100;
export function helper(): int32 { return 100; }
export macro m(x: Node): Node {
	return quote { (() => {
		class P {
			v: int32 = 0;
			constructor() { this.v = LIMIT; }
			read(): int32 { return helper() + this.v; }
		}
		return new P().read();
	})() };
}
`;
	const bad = failures([
		buildFailure([{ entryPath: "test/lib.ms", entrySource: lib }, callerOf(callerNamesakes, "m(0)")], "class members beside caller namesakes"),
		buildFailure([{ entryPath: "test/lib.ms", entrySource: lib }, callerOf("", "m(0)")], "class members with no caller namesake"),
	]);
	assert bad == "", bad;
}

function typeCases(quoted: string, use: string, type: string, label: string): string {
	const lib: MapEntry = { entryPath: "test/lib.ms", entrySource: libWith(quoted) };
	return failures([
		buildFailure([lib, callerOf(callerNamesakes, use, type)], label + " beside a caller namesake"),
		buildFailure([lib, callerOf("", use, type)], label + " with no caller namesake"),
		buildFailure([lib, callerOf(callerNamesakes + `function inGeneric<T>(x: T): ${type} { return ${use}; }\n`, "inGeneric(\"s\")", type)], label + " inside a generic function"),
	]);
}

test "quoteBindsWhereWritten: a type written in a quote names the macro module's declaration, not the caller's namesake" {
	const bad = [
		typeCases("(() => { const b: Box = new Box(); return b.v; })()", "m(0)", "int32", "variable annotation"),
		typeCases("(new Box() as Box).v", "m(0)", "int32", "as"),
		typeCases("(() => { const b: Box[] = [new Box()]; return b[0].v; })()", "m(0)", "int32", "nested array annotation"),
		typeCases("(() => { const m = new Map<string, Box>(); m.set(\"a\", new Box()); return m.get(\"a\")!.v; })()", "m(0)", "int32", "new Map type arguments"),
		typeCases("(() => { function id<T>(x: T): T { return x; } return id<Box>(new Box()).v; })()", "m(0)", "int32", "explicit type argument"),
		typeCases("(() => { function get(b: Box): int32 { return b.v; } return get(new Box()); })()", "m(0)", "int32", "nested function parameter"),
		typeCases("(() => { function mk(): Box { return new Box(); } return mk().v; })()", "m(0)", "int32", "nested function return"),
		typeCases("((b: Box) => b.v)(new Box())", "m(0)", "int32", "arrow parameter"),
		typeCases("((): Box => new Box())().v", "m(0)", "int32", "arrow return"),
		typeCases("(function (b: Box): int32 { return b.v; })(new Box())", "m(0)", "int32", "function expression parameter"),
		typeCases("((f: (b: Box, n: int32) => int32) => f(new Box(), 1))((b: Box, n) => b.v + n)", "m(0)", "int32", "mixed bound and contextually typed parameters"),
	].filter((r: string): boolean => r != "").join("\n");
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: a type on a member of a class declared in a quote names the macro module's declaration" {
	const bad = [
		typeCases("(() => { class P { b: Box = new Box(); } return new P().b.v; })()", "m(0)", "int32", "property"),
		typeCases("(() => { class P { pass(b: Box): Box { return b; } } return new P().pass(new Box()).v; })()", "m(0)", "int32", "method parameter and return"),
		typeCases("(() => { class P { v: int32 = 0; constructor(b: Box) { this.v = b.v; } } return new P(new Box()).v; })()", "m(0)", "int32", "constructor parameter"),
	].filter((r: string): boolean => r != "").join("\n");
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: a type text naming a quote's own type binds its other names where the quote is written" {
	const bad = [
		typeCases("(() => { function at<K>(m: Map<K, Box>, k: K): int32 { return m.get(k)!.v; } const mm = new Map<string, Box>(); mm.set(\"a\", new Box()); return at(mm, \"a\"); })()", "m(0)", "int32", "generic parameter beside a bound name"),
		typeCases("(() => { class Q { n: int32 = 1; } const t: [Q, Box] = [new Q(), new Box()]; return t[0].n + t[1].v - 1; })()", "m(0)", "int32", "quote class beside a bound name"),
	].filter((r: string): boolean => r != "").join("\n");
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: a predicate target and a sizeof operand in a quote name the macro module's declarations" {
	const bad = [
		typeCases("(() => { function isBox(x: Box | string): x is Box { return typeof x != \"string\"; } const u: Box | string = new Box(); return isBox(u) ? u.v : 0; })()", "m(0)", "int32", "predicate target"),
		typeCases("(() => { const n: int32 = sizeof Pair; return n; })()", "m(0)", "int32", "sizeof"),
	].filter((r: string): boolean => r != "").join("\n");
	assert bad == "", bad;
}

test "quoteBindsWhereWritten: a type parameter declared in the quote shadows the macro module's class of that name" {
	const lib = `import { Node } from "std/meta";
export class Box { v: int32 = 100; }
export macro m(x: Node): Node {
	return quote { (() => {
		function id<Box>(b: Box): Box { const c: Box = b; return c as Box; }
		const m = new Map<string, Box>();
		m.set("a", new Box());
		return id<int32>(7) + m.get("a")!.v;
	})() };
}
`;
	const bad = failures([
		buildFailure([{ entryPath: "test/lib.ms", entrySource: lib }, callerOf(callerNamesakes, "m(0)")], "quote type parameter beside a caller namesake"),
		buildFailure([{ entryPath: "test/lib.ms", entrySource: lib }, callerOf("", "m(0)")], "quote type parameter with no caller namesake"),
	]);
	assert bad == "", bad;
}
