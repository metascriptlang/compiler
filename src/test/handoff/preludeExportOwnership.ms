import { compileProjectToCWithStd, MapEntry } from "../helpers";

struct ExportCase {
	module: string;
	name: string;
	use: string;
	accepted: boolean;
}

test "prelude names belong to their exporting module through imports and reexports" {
	const cases: ExportCase[] = [
		{ module: "std/core/struct", name: "hashString", use: "console.log(alias(\"a\"));", accepted: true },
		{ module: "std/core/array", name: "push", use: "const a: number[] = []; alias(a, 7); console.log(a.length);", accepted: true },
		{ module: "std/core/json", name: "parseJson", use: "console.log(alias(\"1\").ok);", accepted: true },
		{ module: "std/core/array", name: "nope", use: "", accepted: false },
		{ module: "std/core/struct", name: "push", use: "", accepted: false },
	];
	for (const c of cases) {
		for (const viaHub of [false, true]) {
			const from = viaHub ? "./hub" : c.module;
			const name = viaHub ? "alias" : c.name + " as alias";
			const entries: MapEntry[] = [
				{ entryPath: "exports/hub.ms", entrySource: `export { ${c.name} as alias } from "${c.module}"; export const keep = 7;` },
				{ entryPath: "exports/main.ms", entrySource: `import { ${name} } from "${from}"; ` + c.use },
			];
			const code = compileProjectToCWithStd(entries, "exports/main.ms");
			assert !code.startsWith("ERROR:") == c.accepted, c.module + ":" + c.name + (viaHub ? " through hub" : " direct");
		}
	}
}
