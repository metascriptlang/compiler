// bug554 — an error a later module recorded against an earlier one was counted and never shown
//
// Symptom:    `msc check` printed "OK" while `msc build` stopped with "1 type error(s) found" and no
//             message, whenever a call filled a parameter default the callee's module declares wrongly
//             (`export function f(o: O = null)` in lib.ms, `f()` in main.ms); std's `fetch(url)` did it
//             to every program that called fetch. A constructor default was reported against the caller's
//             file at the library's line.
//
// Root cause: a filled default is checked in the ctx of the module that declares it, after that module's
//             errors were copied into its module record, which is all `check` and `build` render; the build
//             counted the ctx. A constructor default was checked in the caller's ctx.
//
// Fix:        the graph check copies each module's errors once every module is checked; a constructor
//             default is checked in its class's module, as a function default is.

import { checkModuleGraph } from "../../checker/orchestrator";
import { lookupModuleCtx } from "../../checker/instantiate";
import { Severity } from "../../checker/context";
import { ModuleGraph, findModule, ErrorSeverity } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";

const LIB554 = "export class O554 { a: int32 = 1; }\nexport function f554(o: O554 = null): int32 { return 1; }\nexport class Opt554 {\n\tn: int32;\n\tconstructor(o: O554 = null) { this.n = 2; }\n}\n";

function graphOf554(main: string): ModuleGraph {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/lib554.ms", entrySource: LIB554 });
	entries.push({ entryPath: "/src/main554.ms", entrySource: main });
	const graph = loadModuleGraph("/src/main554.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	return graph;
}

function reported554(graph: ModuleGraph, path: string, needle: string): int32 {
	const mod = findModule(graph, path);
	if (mod == null) return -1;
	let n: int32 = 0;
	for (const e of mod.errors) if (e.severity == ErrorSeverity.Error && e.message.indexOf(needle) >= 0) n += 1;
	return n;
}

function counted554(path: string): int32 {
	const ctx = lookupModuleCtx(path);
	if (ctx == null) return -1;
	let n: int32 = 0;
	for (const e of ctx.errors) if (e.severity == Severity.Error) n += 1;
	return n;
}

test "bug554: a default a later module fills is reported in the module that declares it" {
	const graph = graphOf554("import { f554 } from \"./lib554\";\nconst r: int32 = f554();\n");
	assert reported554(graph, "/src/lib554.ms", "'null' is not assignable") == 1;
	assert reported554(graph, "/src/lib554.ms", "") == counted554("/src/lib554.ms");
}

test "bug554: a constructor default is reported in the module that declares it" {
	const graph = graphOf554("import { Opt554 } from \"./lib554\";\nconst r: int32 = new Opt554().n;\n");
	assert reported554(graph, "/src/lib554.ms", "'null' is not assignable") == 1;
	assert reported554(graph, "/src/main554.ms", "") == 0;
}
