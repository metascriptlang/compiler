import { checkModuleGraph } from "../../checker/orchestrator";
import { findModule } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph, moduleParseCount } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

function parsesToCheck(main: string): int32 {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: "/src/lib.ms", entrySource: "export function twice(n: int32): int32 { return n * 2; }" },
		{ entryPath: "/src/main.ms", entrySource: main },
	];
	const before = moduleParseCount();
	const graph = loadModuleGraph("/src/main.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	return moduleParseCount() - before;
}

function parseErrors(main: string): string[] {
	resetBuildState();
	const entries: MapEntry[] = [{ entryPath: "/src/main.ms", entrySource: main }];
	const graph = loadModuleGraph("/src/main.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const out: string[] = [];
	for (const e of findModule(graph, "/src/main.ms").errors) if (e.message.indexOf("Parse") >= 0) out.push(e.message);
	return out;
}

test "a check parses each module's source once" {
	const parses = parsesToCheck("import { twice } from \"./lib\";\nconst v: int32 = twice(3);\n");
	assert parses == 2, `${parses} parses for 2 modules`;
}

test "a module with a parse error is parsed once and reports the error once" {
	const parses = parsesToCheck("import { twice } from \"./lib\";\nconst v: int32 = ;\n");
	assert parses == 2, `${parses} parses for 2 modules`;
	const errors = parseErrors("const v: int32 = ;\nconst w: int32 = 1;\n");
	assert errors.length == 1, errors.join(" | ");
}
