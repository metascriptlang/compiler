import { resetBuildState } from "../../compiler/buildSession";
import {
	MapEntry, createMapProvider, loadModuleGraph, canonicalModulePath,
} from "../../module/loader";
import { checkModuleGraph } from "../../checker/orchestrator";
import { hasErrors } from "../../checker/context";
import { lookupModuleCtx, lookupModuleProgram } from "../../checker/instantiate";
import {
	generateRaiserProject, lowerForRaiser, RaiserModuleInput,
} from "../../codegen/raiser/rgen";
import { createContext, load, execute } from "../../raiser/context";

test "packed source: a namespace producer supplies its actual body result to packed consumers" {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: canonicalModulePath("/sourceNamespace/a.ms"), entrySource:
			`import * as api from "./b";
			 const p = api.make(4); export default p.x * 10 + p.y;` },
		{ entryPath: canonicalModulePath("/sourceNamespace/b.ms"), entrySource:
			`export struct Pair { x: int64; y: int64; }
			 @noinline export function make(n: int64): Pair { return { x: n, y: n + 1 }; }` },
	];
	const graph = loadModuleGraph(entries[0].entryPath, createMapProvider(entries));
	checkModuleGraph(graph, "");
	const modules: RaiserModuleInput[] = [];
	for (const path of graph.loadOrder) {
		const ctx = lookupModuleCtx(path);
		const program = lookupModuleProgram(path);
		assert ctx != null && program != null;
		assert !hasErrors(ctx);
		modules.push({ modulePath: path, program: lowerForRaiser(program, ctx) });
	}
	const ctx = createContext();
	load(ctx, generateRaiserProject(modules, graph.dispatchRegistry));
	execute(ctx);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 45;
}
