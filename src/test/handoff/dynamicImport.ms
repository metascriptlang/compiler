import { checkModuleGraph } from "../../checker/orchestrator";
import { findModule, ErrorSeverity } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";
import { hostTargetInfo } from "../../checker/types";
import { GcMode } from "../../checker/context";

const lib = "export function hi(): string { return \"hi\"; }\nexport let answer: int32 = 42;";

function importErrors(main: string, targetOs: string = "macos", appMode: string = "console"): string[] {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: "/src/lib.ms", entrySource: lib },
		{ entryPath: "/src/main.ms", entrySource: main },
	];
	const graph = loadModuleGraph("/src/main.ms", createMapProvider(entries));
	checkModuleGraph(graph, "", ".cms", targetOs, hostTargetInfo(), GcMode.Drc, null, null, false, appMode);
	const mod = findModule(graph, "/src/main.ms");
	const out: string[] = [];
	if (mod == null) return ["no module"];
	for (const e of mod.errors) if (e.severity == ErrorSeverity.Error) out.push(e.message);
	return out;
}

test "import() of a module is a promise of that module's namespace" {
	for (const source of [
		"async function f(): Promise<string> { const m = await import(\"./lib\"); return m.hi(); }",
		"import * as L from \"./lib\";\nconst p: Promise<typeof L> = import(\"./lib\");",
		"async function f(): Promise<int32> { return (await import(\"./lib\")).answer; }",
		"import(\"./lib\");",
	]) {
		const errors = importErrors(source);
		assert errors.length == 0, source + " => " + errors.join(" | ");
	}
}

test "import() loads its module into the graph as a dynamic edge" {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: "/src/lib.ms", entrySource: lib },
		{ entryPath: "/src/main.ms", entrySource: "async function f(): Promise<void> { await import(\"./lib\"); }" },
	];
	const graph = loadModuleGraph("/src/main.ms", createMapProvider(entries));
	const main = findModule(graph, "/src/main.ms");
	assert main != null && main.imports.length == 1;
	assert main.imports[0].sourcePath == "/src/lib.ms" && main.imports[0].dynamic;
	assert findModule(graph, "/src/lib.ms") != null;
}

test "import() refuses what the compiler cannot build or run" {
	for (const item of [
		{ source: "const s = \"./lib\";\nimport(s);", message: "must be a string literal" },
		{ source: "import(\"./lib\", { with: { type: \"json\" } });", message: "import attributes are not supported" },
		{ source: "import();", message: "takes one module specifier" },
		{ source: "async function f(): Promise<void> { const m = await import(\"./lib\"); m.answer = 1; }", message: "read-only property of a module namespace" },
		{ source: "async function f(): Promise<void> { const m = await import(\"./lib\"); const s = `${m}`; }", message: "has no text form here" },
	]) {
		const errors = importErrors(item.source);
		assert errors.length > 0, item.source;
		for (const e of errors) assert e.indexOf(item.message) >= 0, item.source + " => " + errors.join(" | ");
	}
}

test "import() is refused where no event loop can run a module's initialization later" {
	const source = "import(\"./lib\");";
	for (const os of ["solana", "bare"]) {
		const errors = importErrors(source, os);
		assert errors.length == 1 && errors[0].indexOf(`not supported on the ${os} target`) >= 0, os + " => " + errors.join(" | ");
	}
	for (const mode of ["lib", "staticlib"]) {
		const errors = importErrors(source, "macos", mode);
		assert errors.length == 1 && errors[0].indexOf(`not supported with --app=${mode}`) >= 0, mode + " => " + errors.join(" | ");
	}
}
