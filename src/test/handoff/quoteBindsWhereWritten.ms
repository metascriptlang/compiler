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
`;

function callerOf(decls: string, use: string): MapEntry {
	return { entryPath: "test/main.ms", entrySource: `import { m } from "./lib";\n${decls}\nconst r: int32 = ${use};\nconsole.log(r);\n` };
}

test "quoteBindsWhereWritten: a const, a call and a new in a quote name the macro module's declarations" {
	const lib: MapEntry = { entryPath: "test/lib.ms", entrySource: libWith("LIMIT") };
	const bad = failures([
		buildFailure([lib, callerOf(callerNamesakes, "m(0)")], "const"),
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
