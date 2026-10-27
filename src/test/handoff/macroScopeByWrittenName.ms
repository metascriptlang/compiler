import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function problems(entries: MapEntry[]): string[] {
	const kept: string[] = [];
	for (const m of checkProjectDiagnostics(entries, "test/main.ms")) {
		if (!m.endsWith("is declared but never used") && !m.endsWith("is imported but never used")) kept.push(m);
	}
	return kept;
}

function macroProject(lib: string, scope: string, body: string): MapEntry[] {
	const mac = `
import { Node, NodeKind } from "std/meta";
${scope}
export macro m(x: Node): Node {
	${body}
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: 1 };
}
`;
	return [
		{ entryPath: "test/lib.ms", entrySource: lib },
		{ entryPath: "test/mac.ms", entrySource: mac },
		{ entryPath: "test/main.ms", entrySource: `import { m } from "./mac";\nconsole.log(m(1));\n` },
	];
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

const helperLib = "export function helper(): number { return 41; }";
const importHelper = `import { helper as h } from "./lib";`;

test "macroScope: a macro body sees an import by the name its module wrote" {
	const bad = failures([
		buildFailure(macroProject(helperLib, importHelper, `if (h() != 41) throw new Error("alias bound wrong");`), "function"),
		buildFailure(macroProject("export class Box { n: int32 = 5; }", `import { Box as B } from "./lib";`,
			`const b = new B(); if (b.n != 5) throw new Error("alias class wrong");`), "class"),
		buildFailure(macroProject("export type Num = int32;", `import { Num as N } from "./lib";`,
			`const a: N = 3; if (a != 3) throw new Error("alias type wrong");`), "type alias"),
	]);
	assert bad == "", bad;
}

test "macroScope: an alias and a local of the original spelling stay two names in a macro body" {
	const bad = failures([
		buildFailure(macroProject(helperLib, `${importHelper}\nfunction helper(): number { return 7; }`,
			`if (h() != 41) throw new Error("alias bound wrong"); if (helper() != 7) throw new Error("local bound wrong");`), "function"),
		buildFailure(macroProject("export class Box { n: int32 = 5; }", `import { Box as B } from "./lib";\nclass Box { n: int32 = 9; }`,
			`const b = new B(); const l = new Box(); if (b.n != 5) throw new Error("alias class wrong"); if (l.n != 9) throw new Error("local class wrong");`), "class"),
		buildFailure(macroProject("export type Num = int32;", `import { Num as N } from "./lib";\ntype Num = string;`,
			`const a: N = 3; const s: Num = "s"; if (a != 3) throw new Error("alias type wrong"); if (s != "s") throw new Error("local type wrong");`), "type alias"),
	]);
	assert bad == "", bad;
}

test "macroScope: a helper the macro reaches binds names as its own module wrote them" {
	const scope = `${importHelper}\nfunction helper(): number { return 7; }\nfunction both(): number { return h() * 100 + helper(); }`;
	const bad = buildFailure(macroProject(helperLib, scope, `if (both() != 4107) throw new Error("helper bound wrong");`), "helper");
	assert bad == "", bad;
}

function comptimeProject(lib: string, main: string): MapEntry[] {
	return [
		{ entryPath: "test/lib.ms", entrySource: lib },
		{ entryPath: "test/main.ms", entrySource: main },
	];
}

test "macroScope: a @comptime block sees an import by its alias beside a local of the original name" {
	const main = `
import { K as B } from "./lib";
const K: number = 7;
const v: number = @comptime {
	if (B != 300) throw new Error("alias bound wrong");
	if (K != 7) throw new Error("local bound wrong");
	return B;
};
console.log(v);
`;
	const bad = buildFailure(comptimeProject("export const K: number = 300;", main), "const");
	assert bad == "", bad;
}

test "macroScope: a @comptime function reaches an alias and a local of the original name" {
	const main = `
import { digits as baseDigits } from "./lib";
@comptime function digits(): number { return 7; }
@comptime function check(): number {
	if (digits() != 7) throw new Error("local bound wrong");
	if (baseDigits() != 300) throw new Error("alias bound wrong");
	return 1;
}
const ok: number = check();
console.log(ok, digits(), baseDigits());
`;
	const bad = buildFailure(comptimeProject("export @comptime function digits(): number { return 300; }", main), "function");
	assert bad == "", bad;
}

test "macroScope: a function-local const shadows a module namesake in a @comptime block" {
	const main = `
const K: number = 10;
function f(): number {
	const K: number = 20;
	return @comptime {
		if (K != 20) throw new Error("local bound wrong");
		return K;
	};
}
console.log(f(), K);
`;
	const bad = buildFailure(comptimeProject("", main), "local const");
	assert bad == "", bad;
}

test "macroScope: a parameter or mutable local read in a @comptime block is refused, not read from a module namesake" {
	const param = `
const p: number = 5;
function g(p: number): number {
	return @comptime { p };
}
console.log(g(9), p);
`;
	const refusedParam = checkProjectDiagnostics(comptimeProject("", param), "test/main.ms");
	assert refusedParam.length > 0 && refusedParam.join("\n").contains("cannot evaluate 'p' at comptime"), refusedParam.join(" | ");
	const mutable = `
const q: number = 5;
function g(): number {
	let q: number = 9;
	return @comptime { q };
}
console.log(g(), q);
`;
	const refusedMutable = checkProjectDiagnostics(comptimeProject("", mutable), "test/main.ms");
	assert refusedMutable.length > 0 && refusedMutable.join("\n").contains("cannot evaluate 'q' at comptime"), refusedMutable.join(" | ");
}
