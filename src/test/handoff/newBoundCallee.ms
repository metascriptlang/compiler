import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function lib(own: string, name: string, args: string, typeArg: string): string {
	return `import { Node, NodeKind, bindSym } from "std/meta";
${own}
export macro mk(x: Node): Node {
	const bound = bindSym("${name}");
	return { kind: NodeKind.NewExpr, line: x.line, column: x.column, newCallee: bound, newArguments: ${args}, typeArg: "${typeArg}" };
}
`;
}

function problemOf(libSource: string, main: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/lib.ms", entrySource: libSource },
		{ entryPath: "test/main.ms", entrySource: main },
	];
	const found = checkProjectDiagnostics(entries, "test/main.ms");
	if (found.length > 0) return found.join(" | ");
	const c = compileProjectToCWithStd(entries, "test/main.ms");
	if (c.startsWith("ERROR:")) return c;
	const js = compileProjectToJSWithStd(entries, "test/main.ms");
	if (js.startsWith("ERROR:")) return js;
	return "";
}

test "new of a bound class that shares a std name is the bound class: Arc and Promise" {
	const arc = lib("export class Arc { v: int32 = 1; constructor(a: int32) { this.v = a; } }", "Arc", "[x]", "");
	const promise = lib("export class Promise { v: int32 = 1; }", "Promise", "[]", "");
	const use = `import { mk } from "./lib";
const b = mk(0);
const n: int32 = b.v;
console.log(n);
`;
	assert problemOf(arc, use) == "", "Arc: " + problemOf(arc, use);
	assert problemOf(promise, use) == "", "Promise: " + problemOf(promise, use);
}

test "new of a bound class beside a caller class of the same name is the bound class: Box and Map" {
	const box = lib("export class Box { v: int32 = 1; }", "Box", "[]", "");
	const map = lib("", "Map", "[]", "string, int32");
	const boxUse = `import { mk } from "./lib";
class Box { v: string = "s"; }
const b = mk(0);
const n: int32 = b.v;
console.log(n);
`;
	const mapUse = `import { mk } from "./lib";
class Map { size: string = "s"; }
const m = mk(0);
const n: int32 = m.size;
console.log(n);
`;
	assert problemOf(box, boxUse) == "", "Box: " + problemOf(box, boxUse);
	assert problemOf(map, mapUse) == "", "Map: " + problemOf(map, mapUse);
}
