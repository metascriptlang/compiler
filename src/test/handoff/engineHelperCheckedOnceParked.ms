// Parked: red until inbox card 2026-10-26-comptime-block-misses-imported-extension-on-c is fixed; not registered in handoff/index.ms.
// The fixing session moves these tests into engineHelperCheckedOnce.ms and deletes this file.
import { compileProjectToCWithStd, compileProjectToJSWithStd, MapEntry } from "../helpers";
import { engineRecheckReasons } from "../../codegen/raiser/eval";

const MAP_HELPERS = `
import { Map } from "std/core/struct";
export function storedThree(k: string): int32 { const m = new Map<string, int32>(); m.set(k, 3); return m.get(k) ?? -1; }
`;

function mapBuild(main: string, js: boolean): string {
	const entries: MapEntry[] = [
		{ entryPath: "engineMap/lib.ms", entrySource: MAP_HELPERS },
		{ entryPath: "engineMap/main.ms", entrySource: main },
	];
	return js ? compileProjectToJSWithStd(entries, "engineMap/main.ms") : compileProjectToCWithStd(entries, "engineMap/main.ms");
}

function mapRuns(main: string): string {
	const c = mapBuild(main, false);
	if (c.startsWith("ERROR:") || !c.includes("33")) return `C: ${c.slice(0, 300)} | rechecks: ${engineRecheckReasons().join(", ")}`;
	const js = mapBuild(main, true);
	if (js.startsWith("ERROR:") || !js.includes("33")) return `JS: ${js.slice(0, 300)} | rechecks: ${engineRecheckReasons().join(", ")}`;
	return "";
}

test "a comptime block runs an imported helper that calls Map extensions on C and JS" {
	const failure = mapRuns(`import { storedThree } from "./lib";\nconst V: int32 = @comptime { return storedThree("a") + 30; };\nconsole.log(V);\n`);
	assert failure == "", failure;
}

test "a comptime block runs a Map helper declared in its own module on C and JS" {
	const failure = mapRuns(`import { Map } from "std/core/struct";\nfunction storedThree(k: string): int32 { const m = new Map<string, int32>(); m.set(k, 3); return m.get(k) ?? -1; }\nconst V: int32 = @comptime { return storedThree("a") + 30; };\nconsole.log(V);\n`);
	assert failure == "", failure;
}
