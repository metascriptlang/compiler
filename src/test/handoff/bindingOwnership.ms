import { compileToC, checkProjectDiagnostics, compileProjectToCWithStd, MapEntry } from "../helpers";
import { checkModuleGraph } from "../../checker/orchestrator";
import { lookupModuleCtx } from "../../checker/instantiate";
import { Severity } from "../../checker/context";
import { ModuleGraph, findModule, ErrorSeverity } from "../../module/graph";
import { createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

test "bindingOwnership: explicit moves require ownership transfer rather than implicit copying" {
	const cases = [
		{ name: "explicit move that would copy is rejected", source: "\nclass Foo {\n\tx: int32 = 1;\n}\n\nexport function moveThenUse(): int32 {\n\tconst a = new Foo();\n\tlet b = new Foo();\n\tb = move a;\n\treturn a.x + b.x;\n}\n", expected: -1 },
		{ name: "explicit move on a last use still compiles", source: "\nclass Foo {\n\tx: int32 = 1;\n}\n\nexport function moveAtLastUse(): int32 {\n\tconst a = new Foo();\n\tlet b = new Foo();\n\tb = move a;\n\treturn b.x;\n}\n", expected: 0 },
		{ name: "moving an element read afterwards is rejected at the move", source: "\ninterface Leaf { v: string; }\nexport function run(): string {\n\tconst arr: Leaf[] = [{ v: \"a\" }, { v: \"b\" }];\n\tconst x = move arr[0];\n\treturn x.v + (arr[0] == null ? \"null\" : \"kept\");\n}\n", expected: -1 },
		{ name: "moving a nested element out of a return is rejected", source: "\nexport function run(): string {\n\tconst grid: string[][] = [[\"a\" + String(1), \"b\"], [\"c\"]];\n\treturn move grid[0][1];\n}\n", expected: -1 },
		{ name: "moving an element into a sink argument is rejected", source: "\ninterface Leaf { v: string; }\nexport function run(): string {\n\tconst arr: Leaf[] = [{ v: \"a\" }, { v: \"b\" }];\n\tconst out: Leaf[] = [];\n\tout.push(move arr[1]);\n\treturn out[0].v;\n}\n", expected: -1 },
		{ name: "moving a field still compiles", source: "\nclass H { f: string = \"\"; }\nexport function run(): string {\n\tconst h = new H();\n\th.f = \"x\" + String(1);\n\tconst t = move h.f;\n\treturn t + h.f;\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "binding ownership: imports and implicit prelude visibility do not become exports" {
	const consumers = [
		{ module: "std/core/array", name: "push", source: "import { k, push } from \"./library\"; const a: number[] = []; push(a, k); a.push(k);" },
		{ module: "std/core/struct", name: "hashString", source: "import { k, hashString } from \"./library\"; console.log(hashString(\"a\").toString() + k.toString());" },
	];
	for (const consumer of consumers) {
		const policies = [
			{ prefix: "", exported: false },
			{ prefix: "import { " + consumer.name + " } from \"" + consumer.module + "\";", exported: false },
			{ prefix: "export { " + consumer.name + " } from \"" + consumer.module + "\";", exported: true },
			{ prefix: "export * from \"" + consumer.module + "\";", exported: true },
		];
		for (const policy of policies) {
			const entries: MapEntry[] = [
				{ entryPath: "src/library.ms", entrySource: policy.prefix + "\nexport const k = 7;" },
				{ entryPath: "src/main.ms", entrySource: consumer.source },
			];
			const diagnostics = checkProjectDiagnostics(entries, "src/main.ms");
			assert policy.exported ? diagnostics.length == 0 : diagnostics.length > 0, consumer.name + ": " + policy.prefix;
			if (policy.exported) {
				const c = compileProjectToCWithStd(entries, "src/main.ms");
				assert !c.startsWith("ERROR"), c;
			}
		}
	}
}

function defaultGraph(use: string, nullable: boolean): ModuleGraph {
	resetBuildState();
	const parameter = nullable ? "DefaultValue | null" : "DefaultValue";
	const library = "export class DefaultValue { n: int32 = 1; } export function f(o: " + parameter + " = null): int32 { return 1; } export class Option { n: int32; constructor(o: " + parameter + " = null) { this.n = 2; } }";
	const entries: MapEntry[] = [
		{ entryPath: "/src/defaultLibrary.ms", entrySource: library },
		{ entryPath: "/src/defaultEntry.ms", entrySource: use },
	];
	const graph = loadModuleGraph("/src/defaultEntry.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	return graph;
}

function moduleErrors(graph: ModuleGraph, path: string): int32 {
	const mod = findModule(graph, path);
	if (mod == null) return -1;
	let count: int32 = 0;
	for (const error of mod.errors) if (error.severity == ErrorSeverity.Error) count += 1;
	return count;
}

test "binding ownership: deferred default diagnostics belong to their declaring module exactly once" {
	for (const use of [
		"import { f } from \"./defaultLibrary\"; const result: int32 = f();",
		"import { Option } from \"./defaultLibrary\"; const result: int32 = new Option().n;",
	]) {
		const graph = defaultGraph(use, false);
		assert moduleErrors(graph, "/src/defaultLibrary.ms") == 1, use;
		assert moduleErrors(graph, "/src/defaultEntry.ms") == 0, use;
		const ctx = lookupModuleCtx("/src/defaultLibrary.ms");
		assert ctx != null;
		let contextErrors: int32 = 0;
		for (const error of ctx.errors) if (error.severity == Severity.Error) contextErrors += 1;
		assert contextErrors == moduleErrors(graph, "/src/defaultLibrary.ms"), use;
		const valid = defaultGraph(use, true);
		assert moduleErrors(valid, "/src/defaultLibrary.ms") == 0, use;
		assert moduleErrors(valid, "/src/defaultEntry.ms") == 0, use;
	}
}

test "binding ownership: imported static extensions belong to their receivers, not a bare overload set" {
	const library = "export struct Pet { hunger: uint16; } export struct Block { id: uint32; } export function create(x: int32): int32 { return x + 1; } export function create(this typeof Pet): Pet { return { hunger: 7 }; } export function create(this typeof Block): Block { return { id: 9 }; } export function make(this typeof Pet): Pet { return { hunger: 3 }; }";
	const cases = [
		{ source: "import { Pet, Block, create } from \"./library\"; const b: uint32 = Block.create().id; const p: uint16 = Pet.create().hunger; const n: int32 = create(4);", accepted: true },
		{ source: "import * as lib from \"./library\"; const b: uint32 = lib.Block.create().id; const p: uint16 = lib.Pet.create().hunger;", accepted: true },
		{ source: "import { Pet, make } from \"./library\"; const p: Pet = make();", accepted: false },
		{ source: "import { Pet, make } from \"./library\"; const p: uint16 = Pet.make().hunger;", accepted: true },
	];
	for (const item of cases) {
		const entries: MapEntry[] = [
			{ entryPath: "src/library.ms", entrySource: library },
			{ entryPath: "src/main.ms", entrySource: item.source },
		];
		const diagnostics = checkProjectDiagnostics(entries, "src/main.ms");
		assert item.accepted ? diagnostics.length == 0 : diagnostics.length > 0, item.source;
	}
}
