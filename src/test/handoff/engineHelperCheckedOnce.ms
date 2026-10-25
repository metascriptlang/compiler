import { compileProjectToCWithStd, compileProjectToJSWithStd, MapEntry } from "../helpers";
import { engineRecheckCount } from "../../codegen/raiser/eval";

const HELPERS = `
export function firstOf<T>(xs: T[]): T { return xs[0]; }
export function lastOf<T>(xs: T[]): T { return xs[xs.length - 1]; }
export function pairUp<T>(a: T, b: T): T[] { const out: T[] = [a, b]; return out; }
export function tagged<T>(x: T, tag: string): string { return tag + ":" + firstOf([x]); }
`;

const EXPECTED = "A:c|y";
const CALLS = `tagged("c", "A") + "|" + lastOf(pairUp("x", "y"))`;
const IMPORTS = `import { firstOf, lastOf, pairUp, tagged } from "./lib";`;

const MACRO_MAIN = IMPORTS + `
import { Node, NodeKind } from "std/meta";

macro described(): Node {
	const t = getTypeArg();
	const v = ${CALLS} + (t.kind === NodeKind.TypeObject ? "" : "?");
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: v };
}

interface Shape { w: int32; }
console.log(described<Shape>());
`;

const COMPTIME_MAIN = IMPORTS + `
const V: string = @comptime { ${CALLS} };
console.log(V);
`;

function checkedOnce(main: string, js: boolean): string {
	const entries: MapEntry[] = [
		{ entryPath: "engineOnce/lib.ms", entrySource: HELPERS },
		{ entryPath: "engineOnce/main.ms", entrySource: main },
	];
	const before = engineRecheckCount();
	const code = js ? compileProjectToJSWithStd(entries, "engineOnce/main.ms") : compileProjectToCWithStd(entries, "engineOnce/main.ms");
	if (code.startsWith("ERROR:")) return code;
	if (!code.includes(EXPECTED)) return "the expansion is missing";
	const again = engineRecheckCount() - before;
	return again == 0 ? "" : `${again} instance bodies checked again for the engine`;
}

test "the generic instances a generic macro calls are lowered from their engine-checked bodies on C and JS" {
	const c = checkedOnce(MACRO_MAIN, false);
	assert c == "", "C: " + c;
	const js = checkedOnce(MACRO_MAIN, true);
	assert js == "", "JS: " + js;
}

test "the generic instances a comptime block calls are lowered from their engine-checked bodies on C and JS" {
	const c = checkedOnce(COMPTIME_MAIN, false);
	assert c == "", "C: " + c;
	const js = checkedOnce(COMPTIME_MAIN, true);
	assert js == "", "JS: " + js;
}
