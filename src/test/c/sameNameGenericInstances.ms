import { compileProjectToC, MapEntry } from "../helpers";

const LIB_PATH = "test/sameNameGenericInstances/lib.ms";
const MAIN_PATH = "test/sameNameGenericInstances/main.ms";
const LIB_FACTORY = `export function mkA(): Box<string> { return { v: "a" }; }\n`;
const MAIN_IMPORT = `import { mkA } from "./lib";\n`;
const MAIN_CONSUMER = `const m: Box<string> = { n: 7, w: "m" };\nconsole.log(m.w, mkA().v);\n`;

function project(libSource: string, mainSource: string): string {
	const entries: MapEntry[] = [
		{ entryPath: LIB_PATH, entrySource: libSource },
		{ entryPath: MAIN_PATH, entrySource: mainSource },
	];
	return compileProjectToC(entries, MAIN_PATH);
}

function instanceNames(cCode: string, base: string, suffix: string): string[] {
	const names: string[] = [];
	const head = "struct ";
	const marker = head + base + "_";
	let at = cCode.indexOf(marker, 0);
	while (at >= 0) {
		const nameStart = at + head.length;
		const name = cCode.slice(nameStart, cCode.indexOf(" ", nameStart));
		if (name.endsWith(suffix) && names.indexOf(name) < 0) names.push(name);
		at = cCode.indexOf(marker, at + 1);
	}
	return names;
}

test "same-named generics of two modules emit one C struct per declaration" {
	const rows = [
		{
			name: "aliases with equal parameter names",
			libSource: `export type Box<T> = { v: T };\n` + LIB_FACTORY,
			mainSource: MAIN_IMPORT + `type Box<T> = { n: int32, w: T };\n` + MAIN_CONSUMER,
		},
		{
			name: "aliases with different parameter names",
			libSource: `export type Box<U> = { v: U };\n` + LIB_FACTORY,
			mainSource: MAIN_IMPORT + `type Box<T> = { n: int32, w: T };\n` + MAIN_CONSUMER,
		},
		{
			name: "interfaces with different parameter names",
			libSource: `export interface Box<U> { v: U; }\n` + LIB_FACTORY,
			mainSource: MAIN_IMPORT + `interface Box<T> { n: int32; w: T; }\n` + MAIN_CONSUMER,
		},
	];
	for (const row of rows) {
		const cCode = project(row.libSource, row.mainSource);
		assert !cCode.startsWith("ERROR"), row.name + ": " + cCode;
		assert instanceNames(cCode, "Box", "__string").length == 2, row.name;
	}
}
