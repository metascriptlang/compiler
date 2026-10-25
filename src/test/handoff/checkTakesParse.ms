import { platform } from "std/process";
import { Node } from "../../ast/node";
import { checkModuleGraph, createCheckSession, CheckSession } from "../../checker/orchestrator";
import { GcMode } from "../../checker/context";
import { hostTargetInfo } from "../../checker/types";
import { lookupModuleProgram } from "../../checker/instantiate";
import { dbParse } from "../../compiler/transam/index";
import { ModuleGraph, findModule } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

const LIB = "export function twice(n: int32): int32 { return n * 2; }";
const MAIN = "import { twice } from \"./lib\";\nconst v: int32 = twice(3);\n";

function load(entries: MapEntry[]): ModuleGraph {
	return loadModuleGraph(entries[entries.length - 1].entryPath, createMapProvider(entries));
}

function checksLoaderTrees(entries: MapEntry[], session: CheckSession | null): string {
	const graph = load(entries);
	const trees: Node[] = [];
	for (const e of entries) trees.push(findModule(graph, e.entryPath).program!);
	checkModuleGraph(graph, "", ".cms", platform, hostTargetInfo(), GcMode.Orc, null, session);
	for (let i = 0; i < entries.length; i += 1) {
		const mod = findModule(graph, entries[i].entryPath);
		if (mod.errors.length > 0) return `${mod.path}: ${mod.errors[0].message}`;
		if (lookupModuleProgram(mod.path) != trees[i]) return `${mod.path} was checked on a copy of its parse`;
	}
	return "";
}

test "a build checks each module on the tree the loader parsed" {
	resetBuildState();
	const imported = checksLoaderTrees([{ entryPath: "/src/lib.ms", entrySource: LIB }, { entryPath: "/src/main.ms", entrySource: MAIN }], null);
	assert imported == "", imported;
	resetBuildState();
	const cycle = checksLoaderTrees([
		{ entryPath: "/cyc/b.ms", entrySource: "import { a } from \"./a\";\nexport function b(n: int32): int32 { return n > 0 ? a(n - 1) : 0; }" },
		{ entryPath: "/cyc/a.ms", entrySource: "import { b } from \"./b\";\nexport function a(n: int32): int32 { return b(n); }\nconst r: int32 = a(2);\n" },
	], null);
	assert cycle == "", cycle;
}

test "a session rechecks an unchanged module on the tree its next load parsed" {
	resetBuildState();
	const session = createCheckSession();
	const first = checksLoaderTrees([{ entryPath: "/s/lib.ms", entrySource: LIB }, { entryPath: "/s/main.ms", entrySource: MAIN }], session);
	assert first == "", first;
	const edited = "export function twice(n: int32): int32 { return n + n; }";
	const second = checksLoaderTrees([{ entryPath: "/s/lib.ms", entrySource: edited }, { entryPath: "/s/main.ms", entrySource: MAIN }], session);
	assert second == "", second;
	assert session.rechecked.has("/s/main.ms");
}

test "reading a parse the check took fails loud" {
	resetBuildState();
	const session = createCheckSession();
	const checked = checksLoaderTrees([{ entryPath: "/r/lib.ms", entrySource: LIB }, { entryPath: "/r/main.ms", entrySource: MAIN }], session);
	assert checked == "", checked;
	let refused = "";
	try {
		dbParse(session.db!, "/r/main.ms");
	} catch (e) {
		refused = e.message;
	}
	assert refused.indexOf("internal: dbParse") == 0, refused;
}
