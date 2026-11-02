// Keep native empty-input handoff pins beside their source-declaration consumer siblings in run.mjs.
import {
	createFileSystemProvider, createMapProvider, createTaReadProvider,
	provideSource, loadModuleGraph,
} from "../../../module/loader";
import {
	createModule, addModule, ModuleState,
} from "../../../module/graph";
import {
	createTransAmDb, dbBindGraph, dbSetFileText, dbTypeCheck,
	dbPreprocess, dbResolveImport, getFileId, getDirectImports, cacheGet,
	createQueryKey, TaQueryKind,
} from "../../../compiler/transam/index";
import { getInputId, getFileChangedAt } from "../../../compiler/transam/fileInput";
import { createDefineTable, initDefines } from "../../../compiler/defines";
import { getParserDefines, setParserDefines } from "../../../parser/context";
import { errorCount } from "../../../checker/context";
import { checkModuleGraph } from "../../../checker/orchestrator";
import { lookupModuleCtx, resetInstantiationState } from "../../../checker/instantiate";
import { hashContent } from "../../../utils/contentHash";
import { writeFile, ensureDir, removeAll } from "std/fs";
import { cwd } from "std/process";

test "source providers distinguish empty success from missing and unreadable inputs" {
	const root = `${cwd()}/out/emptySource-${performance.now()}`;
	ensureDir(root);
	defer removeAll(root);
	const path = `${root}/empty.ms`;
	assert writeFile(path, "").ok;
	const provider = createFileSystemProvider();
	const readLog: string[] = [];
	provider.readLog = readLog;
	for (let i = 0; i < 2; i += 1) {
		const read = provideSource(provider, path);
		assert read.ok;
		assert read.value == "";
		assert readLog[i] == `${path}\t${hashContent("")}`;
	}
	assert provider.sources.has(path);
	assert !provideSource(provider, `${root}/missing.ms`).ok;
	assert !provideSource(provider, root).ok;
	assert readLog[2] == `${root}/missing.ms\t-`;
	assert readLog[3] == `${root}\t-`;
	const mapped = createMapProvider([{ entryPath: path, entrySource: "" }]);
	assert provideSource(mapped, path).ok;
	const tracked = createTaReadProvider((name: string): Result<string, string> => {
		return name == path ? Result.ok("") : Result.err("tracked missing");
	});
	assert provideSource(tracked, path).ok;
	const missing = provideSource(tracked, "absent");
	assert !missing.ok;
	assert missing.error == "tracked missing";
}

test "binding a graph records parsed empty modules and their type-only edges, not unresolved stubs" {
	const graph = loadModuleGraph("/emptySource/use.ms", createMapProvider([
		{ entryPath: "/emptySource/use.ms", entrySource: 'import type {} from "./empty"; export const value: int32 = 1;' },
		{ entryPath: "/emptySource/empty.ms", entrySource: "" },
	]));
	const stub = createModule("/emptySource/prelude.ms");
	stub.state = ModuleState.Ready;
	stub.stdPrelude = true;
	addModule(graph, stub);
	graph.loadOrder.push(stub.path);
	const unresolved = loadModuleGraph("/emptySource/missing.ms", createMapProvider([]));
	const db = createTransAmDb(100);
	dbBindGraph(db, unresolved);
	assert getFileId(db.fileInput, "/emptySource/missing.ms") < 0;
	dbBindGraph(db, graph);
	const emptyId = getFileId(db.fileInput, "/emptySource/empty.ms");
	assert emptyId >= 0;
	assert getFileId(db.fileInput, stub.path) < 0;
	assert getDirectImports(db.moduleDeps, getFileId(db.fileInput, "/emptySource/use.ms")).includes(emptyId);
	const ctx = dbTypeCheck(db, "/emptySource/use.ms");
	assert ctx != null;
	assert errorCount(ctx) == 0;
}

test "graph checking registers parsed empty modules but leaves unresolved and prelude stubs alone" {
	resetInstantiationState();
	defer resetInstantiationState();
	const path = "/emptySourceCheck/empty.ms";
	const graph = loadModuleGraph(path, createMapProvider([
		{ entryPath: path, entrySource: "" },
	]));
	const stub = createModule("/emptySourceCheck/prelude.ms");
	stub.state = ModuleState.Ready;
	stub.stdPrelude = true;
	addModule(graph, stub);
	graph.loadOrder.push(stub.path);
	const unresolved = createModule("/emptySourceCheck/unresolved.ms");
	unresolved.state = ModuleState.Ready;
	addModule(graph, unresolved);
	graph.loadOrder.push(unresolved.path);
	checkModuleGraph(graph, "");
	const ctx = lookupModuleCtx(path);
	assert ctx != null;
	assert errorCount(ctx) == 0;
	assert lookupModuleCtx(stub.path) == null;
	assert lookupModuleCtx(unresolved.path) == null;
}

test "a warm negative source dependency becomes a present empty module" {
	const db = createTransAmDb(100);
	const path = "/emptySourceWarm/use.ms";
	const empty = "/emptySourceWarm/empty.ms";
	dbSetFileText(db, path, 'import type {} from "./empty"; export const value: int32 = 1;');
	assert dbResolveImport(db, path, "./empty") == "";
	const inputId = getInputId(db.fileInput, empty, db.revision.value);
	const before = db.revision.value;
	assert dbSetFileText(db, empty, "");
	assert getFileId(db.fileInput, empty) == inputId;
	assert getFileChangedAt(db.fileInput, inputId)! > before;
	assert dbResolveImport(db, path, "./empty") == empty;
	const present = dbTypeCheck(db, path);
	assert present != null;
	assert errorCount(present) == 0;
}

test "tracked empty header reads preserve missing-to-empty companion invalidation" {
	const saved = getParserDefines();
	const defines = createDefineTable();
	initDefines(defines, "c", "linux", "amd64", "drc", 0);
	setParserDefines(defines);
	defer setParserDefines(saved);
	const db = createTransAmDb(100);
	const header = "/emptySourceHeader/empty.h";
	const companion = "/emptySourceHeader/empty.c";
	dbSetFileText(db, header, "");
	const first = dbPreprocess(db, header);
	assert first.contains(`@include("${header}")`);
	assert !first.contains("@compile");
	const inputId = getInputId(db.fileInput, companion, db.revision.value);
	const query = cacheGet(db.cache, createQueryKey(TaQueryKind.Preprocess, getFileId(db.fileInput, header)));
	assert query != null;
	let tracked = false;
	for (const dep of query.dependencies) {
		if (dep.queryKind == TaQueryKind.FileText && dep.fileId == inputId) tracked = true;
	}
	assert tracked;
	assert dbSetFileText(db, companion, "");
	const second = dbPreprocess(db, header);
	assert second.contains(`@compile("${companion}")`);
}
