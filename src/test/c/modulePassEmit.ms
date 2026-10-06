import { MapEntry } from "../../module/loader";
import { setExtraGlobalImports, setModulePasses } from "../../checker/prelude";
import { compileProjectToCWithStd, compileProjectToJSWithStd } from "../helpers";

const KEEP = `import { Node, NodeKind } from "std/meta";

export macro keepModule(mod: Node): Node { return mod; }

export macro wrongModule(mod: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: 1, column: 1, value: 1 };
}
`;

const UNITS = `import { Node, NodeKind } from "std/meta";

export struct Meters { v: number; }

export converter toMeters(n: Node): Meters {
	return {
		kind: NodeKind.ObjectLiteral, line: n.line, column: n.column,
		keys: ["v"], keyLocations: [],
		properties: [{ kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 3 }],
	};
}
`;

const MAIN = `import { Meters, toMeters } from "./units";

let builds: int32 = 0;

function mk(): int32 {
	builds = builds + 1;
	return builds;
}

function once(): int32 {
	static const t = mk();
	return t;
}

struct Cell { v: int32; }

const a = once();
const m: Meters = <meters/>;
let cells: Cell[1] = [{ v: 1 }];
const p = cells[0] as Ptr<Cell>;
p[].v = 9;
console.log(a.toString() + " " + m.v.toString() + " " + p[].v.toString());
`;

const ENTRIES: MapEntry[] = [
	{ entryPath: "/mpe/src/keep.ms", entrySource: KEEP },
	{ entryPath: "/mpe/src/units.ms", entrySource: UNITS },
	{ entryPath: "/mpe/src/main.ms", entrySource: MAIN },
];

function emitC(macro: string): string {
	setExtraGlobalImports(["/mpe/src/keep"], "/mpe/build.ms");
	if (macro != "") setModulePasses(["/mpe/src/keep"], [macro]);
	const out = compileProjectToCWithStd(ENTRIES, "/mpe/src/main.ms");
	setExtraGlobalImports([]);
	setModulePasses([], []);
	return out;
}

function emitJS(macro: string): string {
	setExtraGlobalImports(["/mpe/src/keep"], "/mpe/build.ms");
	if (macro != "") setModulePasses(["/mpe/src/keep"], [macro]);
	const out = compileProjectToJSWithStd(ENTRIES, "/mpe/src/main.ms");
	setExtraGlobalImports([]);
	setModulePasses([], []);
	return out;
}

test "the project helpers run a module pass named with its globalImports entry" {
	assert emitC("wrongModule").indexOf("module pass 'wrongModule' must return the module it was given", 0) >= 0;
	assert emitJS("wrongModule").indexOf("module pass 'wrongModule' must return the module it was given", 0) >= 0;
}

test "an identity module pass emits the same C as the same globalImports without a pass" {
	const plain = emitC("");
	assert !plain.startsWith("ERROR");
	assert emitC("keepModule") == plain;
}

test "an identity module pass emits the same JS as the same globalImports without a pass" {
	const plain = emitJS("");
	assert !plain.startsWith("ERROR");
	assert emitJS("keepModule") == plain;
}
