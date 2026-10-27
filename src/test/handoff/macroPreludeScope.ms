import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function project(lib: string, scope: string, body: string): MapEntry[] {
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
	const found = checkProjectDiagnostics(entries, "test/main.ms").filter((m: string): boolean => !m.endsWith("is declared but never used") && !m.endsWith("is imported but never used"));
	if (found.length > 0) return label + ": " + found.join(" | ");
	const c = compileProjectToCWithStd(entries, "test/main.ms");
	if (c.indexOf("ERROR", 0) >= 0) return label + ": " + c;
	const js = compileProjectToJSWithStd(entries, "test/main.ms");
	if (js.indexOf("ERROR", 0) >= 0) return label + ": " + js;
	return "";
}

const noLib = "export const unused = 0;";
const namesakeLib = `export function error(msg: string): number { return 7; }\nexport function splice(n: number): number { return n + 1; }`;
const checkErr = `if (x.kind == NodeKind.StringLiteral) error("wants a number", x);`;

test "macroPrelude: an intrinsic written without an import is std/meta's declaration" {
	const bad = [
		buildFailure(project(noLib, "", checkErr), "error"),
		buildFailure(project(noLib, "", `if (x.kind == NodeKind.StringLiteral) warning("note", x);`), "warning"),
	].filter((r: string): boolean => r != "");
	assert bad.length == 0, bad.join("\n");
}

test "macroPrelude: a module's own namesake is an ordinary call" {
	const bad = buildFailure(project(noLib, `function error(msg: string): number { return 7; }`,
		`if (error("a") != 7) throw new Error("own error not ordinary");`), "own");
	assert bad == "", bad;
}

test "macroPrelude: an alias import of the std/meta declaration is the intrinsic" {
	const bad = buildFailure(project(noLib, `import { error as fail } from "std/meta";`,
		`if (x.kind == NodeKind.StringLiteral) fail("wants a number", x);`), "alias");
	assert bad == "", bad;
}

test "macroPrelude: a namesake exported by another user module is an ordinary call, imported or aliased" {
	const bad = [
		buildFailure(project(namesakeLib, `import { error } from "./lib";`,
			`if (error("a") != 7) throw new Error("imported namesake not ordinary");`), "imported"),
		buildFailure(project(namesakeLib, `import { splice as bump } from "./lib";`,
			`if (bump(1) != 2) throw new Error("aliased namesake not ordinary");`), "aliased"),
	].filter((r: string): boolean => r != "");
	assert bad.length == 0, bad.join("\n");
}
