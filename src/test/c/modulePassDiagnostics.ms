import { MapEntry, createMapProvider, loadModule } from "../../module/loader";
import { createModuleGraph, ErrorSeverity } from "../../module/graph";
import { createDefaultConfig, Backend } from "../../module/resolver";
import { checkModuleGraph, loadStdGlobalImportModules, loadExtraGlobalImportModules } from "../../checker/orchestrator";
import { setExtraGlobalImports, setModulePasses } from "../../checker/prelude";
import { resetBuildState } from "../../compiler/buildSession";
import { resolveRuntimeDir } from "../../utils/path";
import { join } from "std/fs/path";
import "../../codegen/raiser/eval";

const PASS_HEAD = `import { Node, NodeKind, expansionFile } from "std/meta";
import { helper } from "./helper";

export function marker(): int32 { return helper(); }
`;

function diagnostics(passSource: string, macro: string, mainSource: string): string[] {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: "/mp/src/pass.ms", entrySource: passSource },
		{ entryPath: "/mp/src/helper.ms", entrySource: "export function helper(): int32 { return 1; }\n" },
		{ entryPath: "/mp/src/other.ms", entrySource: "export function other(): int32 { return 2; }\n" },
		{ entryPath: "/mp/src/main.ms", entrySource: mainSource },
	];
	const provider = createMapProvider(entries);
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.C, stdPath);
	setExtraGlobalImports(["/mp/src/pass"], "/mp/build.ms");
	setModulePasses(["/mp/src/pass"], [macro]);
	const graph = createModuleGraph();
	loadStdGlobalImportModules(graph, provider, config);
	loadExtraGlobalImportModules(graph, provider, config);
	const _loaded = loadModule(graph, "/mp/src/main.ms", provider, config, 1);
	checkModuleGraph(graph, stdPath, ".cms");
	setExtraGlobalImports([]);
	setModulePasses([], []);
	const messages: string[] = [];
	for (const e of graph.errors) messages.push(e);
	for (const mod of graph.modules) {
		for (const e of mod.errors) {
			if (e.severity == ErrorSeverity.Error) messages.push(`${mod.path}: ${e.message}`);
		}
	}
	return messages;
}

function count(messages: string[], needle: string): int32 {
	let n = 0;
	for (const m of messages) {
		if (m.indexOf(needle, 0) >= 0) n = n + 1;
	}
	return n;
}

const MAIN = `import { other } from "./other";

console.log(other().toString());
`;

test "a module pass that returns the module unchanged leaves it checking clean" {
	const messages = diagnostics(PASS_HEAD + `
export macro keep(mod: Node): Node { return mod; }
`, "keep", MAIN);
	assert messages.length == 0;
}

test "a module pass runs on every module outside std and the globalImports closure, once each" {
	const messages = diagnostics(PASS_HEAD + `
export macro announce(mod: Node): Node {
	error("pass ran on " + expansionFile(), mod);
	return mod;
}
`, "announce", MAIN);
	assert count(messages, "pass ran on") == 2;
	assert count(messages, "pass ran on /mp/src/main.ms") == 1;
	assert count(messages, "pass ran on /mp/src/other.ms") == 1;
	assert count(messages, "/mp/src/helper.ms") == 0;
	assert count(messages, "/mp/src/pass.ms") == 0;
}

test "a module pass that returns something other than the module is an error naming the pass" {
	const messages = diagnostics(PASS_HEAD + `
export macro wrong(mod: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: 1, column: 1, value: 1 };
}
`, "wrong", MAIN);
	assert count(messages, "module pass 'wrong' must return the module it was given (a Program)") == 2;
}

test "a module pass that drops an import is an error naming the pass" {
	const messages = diagnostics(PASS_HEAD + `
export macro dropImports(mod: Node): Node {
	let kept: Node[] = [];
	for (const s of mod.programStmts) {
		if (s.kind != NodeKind.ImportDecl) kept.push(s);
	}
	return { kind: NodeKind.Program, line: mod.line, column: mod.column, programStmts: kept };
}
`, "dropImports", MAIN);
	assert count(messages, "module pass 'dropImports' changed the imports of this module") == 1;
}

test "a modulePass naming a macro its module does not export is an error on that module" {
	const messages = diagnostics(PASS_HEAD, "missing", MAIN);
	assert count(messages, "names modulePass 'missing', but this module exports no macro 'missing'") == 1;
}
