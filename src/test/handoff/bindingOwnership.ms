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
		{ name: "moving an owned element read afterwards is rejected at the move", source: "\nclass N { id: int32 = 0; }\nexport function run(): int32 {\n\tlet kids: Vec<Owned<N>> = [new N(), new N()];\n\tconst k = move kids[0];\n\treturn k.id + kids[0].id;\n}\n", expected: -1 },
		{ name: "moving a nested element out of a return is rejected", source: "\nexport function run(): string {\n\tconst grid: string[][] = [[\"a\" + String(1), \"b\"], [\"c\"]];\n\treturn move grid[0][1];\n}\n", expected: -1 },
		{ name: "moving an element into a sink argument is rejected", source: "\ninterface Leaf { v: string; }\nexport function run(): string {\n\tconst arr: Leaf[] = [{ v: \"a\" }, { v: \"b\" }];\n\tconst out: Leaf[] = [];\n\tout.push(move arr[1]);\n\treturn out[0].v;\n}\n", expected: -1 },
		{ name: "moving a field still compiles", source: "\nclass H { f: string = \"\"; }\nexport function run(): string {\n\tconst h = new H();\n\th.f = \"x\" + String(1);\n\tconst t = move h.f;\n\treturn t + h.f;\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "bindingOwnership: an explicit move out of a path needs a location the mover may write" {
	const shapes = "struct Node { kids: Vec<int32>; }\nstruct Tree { nodes: Vec<Node>; kids: Vec<int32>; }\nclass Box { readonly kids: Vec<int32> = []; }\n";
	const refused = [
		{ name: "a for-of element binding", body: "export function run(t: Tree): int32 { let n: int32 = 0; for (const node of t.nodes) { const k = move node.kids; n += k.length; } return n; }", refusal: "cannot mutate value-type loop variable 'node'" },
		{ name: "a value parameter", body: "export function run(t: Tree): int32 { const k = move t.kids; return k.length; }", refusal: "cannot mutate value-type parameter 't'" },
		{ name: "a const binding", body: "export function run(): int32 { const t: Tree = { nodes: [], kids: [1] }; const k = move t.kids; return k.length; }", refusal: "cannot write 't.kids' — 't' is const" },
		{ name: "a readonly field", body: "export function run(b: Box): int32 { const k = move b.kids; return k.length; }", refusal: "cannot assign to 'kids' because it is a read-only property" },
	];
	for (const item of refused) {
		const result = compileToC(shapes + item.body);
		assert !result.ok && result.error.contains(item.refusal), item.name + (result.ok ? " compiled" : ": " + result.error);
	}
	const kept = [
		{ name: "a const identifier", body: "export function run(): int32 { const v: Vec<int32> = [1]; const k = move v; return k.length; }" },
		{ name: "a let binding's field", body: "export function run(): int32 { let t: Tree = { nodes: [], kids: [1] }; const k = move t.kids; return k.length; }" },
		{ name: "a ref parameter's field", body: "export function run(ref t: Tree): int32 { const k = move t.kids; return k.length; }" },
		{ name: "an indexed element's field", body: "export function run(): int32 { let t: Tree = { nodes: [{ kids: [1] }], kids: [] }; const k = move t.nodes[0].kids; return k.length; }" },
	];
	for (const item of kept) {
		const result = compileToC(shapes + item.body);
		assert result.ok, item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "bindingOwnership: an explicit move of a variable a closure captures is refused, naming the variable" {
	const shapes = "class Box { n: string = \"\"; }\n";
	const refused = [
		{ name: "an arrow reads it", body: "export function run(): string { const x = new Box(); const f = () => x.n; const k = move x; return f() + k.n; }", variable: "x" },
		{ name: "a nested function reads it", body: "export function run(): string { const y = \"y\" + String(1); function g(): string { return y; } const z = move y; return g() + z; }", variable: "y" },
		{ name: "the closure itself moves it", body: "export function run(): string { const w = new Box(); const f = () => { const k = move w; return k.n; }; return f(); }", variable: "w" },
		{ name: "an arrow declared after the move reads it", body: "export function run(): string { const x = new Box(); const k = move x; const f = () => x.n; return f() + k.n; }", variable: "x" },
		{ name: "a nested function declared after the move reads it", body: "export function run(): string { const y = \"y\" + String(1); const z = move y; function g(): string { return y; } return g() + z; }", variable: "y" },
		{ name: "a parameter read by a function expression", body: "export function run(p: string): string { const f = function (): string { return p; }; const k = move p; return f() + k; }", variable: "p" },
	];
	for (const item of refused) {
		const result = compileToC(shapes + item.body);
		assert !result.ok && result.error.contains("cannot move '" + item.variable + "': a closure captures it"), item.name + (result.ok ? " compiled" : ": " + result.error);
	}
	const kept = [
		{ name: "no closure", body: "export function run(): string { const x = new Box(); const k = move x; return k.n; }" },
		{ name: "a closure over another variable", body: "export function run(): string { const x = new Box(); const o = new Box(); const f = () => o.n; const k = move x; return f() + k.n; }" },
		{ name: "a variable the closure declares", body: "export function run(): string { const f = () => { const x = new Box(); const k = move x; return k.n; }; return f(); }" },
		{ name: "a field of a captured variable", body: "export function run(): string { const x = new Box(); const f = () => x.n; const k = move x.n; return f() + k; }" },
	];
	for (const item of kept) {
		const result = compileToC(shapes + item.body);
		assert result.ok, item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "bindingOwnership: a move of a captured variable in a generic body instantiated from another module is refused" {
	const libs = [
		{ name: "a generic function, closure before the move", lib: "export function f<T>(x: T): T { const read = (): T => x; const y = move x; read(); return y; }", use: "f(new Box());" },
		{ name: "a generic function, closure after the move", lib: "export function f<T>(x: T): T { const y = move x; const read = (): T => x; read(); return y; }", use: "f(new Box());" },
		{ name: "a generic method", lib: "export class H<T> { run(x: T): T { const read = (): T => x; const y = move x; read(); return y; } }", use: "new H<Box>().run(new Box());" },
	];
	for (const item of libs) {
		const main = "import { " + (item.use.startsWith("f(") ? "f" : "H") + " } from \"./lib\";\nclass Box { n: string = \"\"; }\n" + item.use;
		let hits = 0;
		for (const m of checkProjectDiagnostics([{ entryPath: "src/lib.ms", entrySource: item.lib }, { entryPath: "src/main.ms", entrySource: main }], "src/main.ms")) {
			if (m.indexOf("cannot move 'x': a closure captures it") >= 0) hits += 1;
		}
		assert hits == 1, item.name + ": " + String(hits) + " refusals";
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

test "binding ownership: default diagnostics belong to their declaring module, once per declaration" {
	for (const use of [
		"import { f } from \"./defaultLibrary\"; const result: int32 = f();",
		"import { Option } from \"./defaultLibrary\"; const result: int32 = new Option().n;",
	]) {
		const graph = defaultGraph(use, false);
		assert moduleErrors(graph, "/src/defaultLibrary.ms") == 2, use;
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
