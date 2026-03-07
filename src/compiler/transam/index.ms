// Trans-Am Hub — incremental query engine entry point
//
// Pipeline: parse → check → transform → analyze → (codegen)
//           \_______________\________________\_______________/
//                    Trans-Am (incremental query cache)
//
// TransAmDb aggregates all stores. dbSetFileText triggers invalidation.
// dbExecute runs the full pipeline through the red-green engine.

import { Node, NodeKind, nodeCacheStore, nodeCacheGet } from "../../ast/node";
import { CheckerContext, ctxCacheStore, ctxCacheGet, createContext } from "../../checker/context";
import {
	TaQueryKey, TaQueryKind, TaQueryState, TaDurability,
	TaRevision, createRevision, incrementRevision,
	createQueryKey, queryKeysEqual
} from "./revision";
import { taHashString } from "./hash";
import {
	TaCacheEntry, createCacheEntry,
	TaDependencyStack,
	createDependencyStack, pushFrame, popFrame,
	recordDependency, hasActiveFrame
} from "./query";
import {
	TaCacheStore, createCacheStore, cacheGet, cachePut,
	cacheContains, markQueriesRedForFile
} from "./cache";
import {
	TaFileInputStore, createFileInputStore,
	setFileText, getFileText, getFileHash, getFileId, getFilePath, hasFile,
	getFileCount, getFilePathByIndex
} from "./fileInput";
import {
	TaModuleDepGraph, createModuleDepGraph,
	recordModuleImport, clearImportsFor, getTransitiveDependents
} from "./moduleDeps";
import { tryMarkGreen, executeQueryWith, invalidateFile } from "./redGreen";
import {
	TaCancelContext, createCancelContext,
	getCancelVersion, checkCancel, requestCancel, resetCancel
} from "./cancel";
import {
	TaStringInterner, createStringInterner,
	internString, lookupInterned, internedCount
} from "./intern";

import { parseSource } from "../../parser/statements/validation";
import { checkProgram, checkProgramCancellable, checkProgramWithRegistryCancellable } from "../../checker/index";
import { transformProgram } from "../../transform/index";
import { analyzeProgram } from "../../analyzer/index";
import {
	ExportRegistry, createExportRegistry, ExportedSymInfo,
	findModuleExports, registerModuleExports,
} from "../../checker/context";
import { collectTopLevelLocal } from "../../checker/collectPass";
import { SF_EXPORTED, hasFlag, openScope, ScopeKind } from "../../checker/symbol";
import {
	ImportDeclData, ExportDeclData, ProgramData,
} from "../../ast/node";
import {
	Module, ModuleGraph, createModule, createModuleGraph, addModule,
	ImportEntry, createImportEntry,
} from "../../module/graph";
import { getDirectImports } from "./moduleDeps";

// ===== TransAmDb =====
// Node/CheckerContext caches live in ast/node.ms and checker/context.ms
// to avoid DRC lifecycle mangling bug (wrong module path for Node_destroy).
// Cache keys use: parseKey = fileId, checkKey = fileId + 10000,
// transformKey = fileId + 20000, analyzeKey = fileId + 30000.

export interface TransAmDb {
	revision: TaRevision;
	fileInput: TaFileInputStore;
	depStack: TaDependencyStack;
	cache: TaCacheStore;
	moduleDeps: TaModuleDepGraph;
	cancelCtx: TaCancelContext;
	interner: TaStringInterner;
	exportRegistry: ExportRegistry;
}

export function createTransAmDb(cacheCapacity: number): TransAmDb {
	return {
		revision: createRevision(),
		fileInput: createFileInputStore(),
		depStack: createDependencyStack(),
		cache: createCacheStore(cacheCapacity),
		moduleDeps: createModuleDepGraph(),
		cancelCtx: createCancelContext(),
		interner: createStringInterner(),
		exportRegistry: createExportRegistry(),
	};
}

// Cache key offsets for different query types
function parseNodeKey(fileId: number): number { return fileId; }
function checkCtxKey(fileId: number): number { return fileId + 10000; }
function transformNodeKey(fileId: number): number { return fileId + 20000; }
function analyzeNodeKey(fileId: number): number { return fileId + 30000; }

// ===== Public API =====

// Set file content. Returns true if content changed.
export function dbSetFileText(db: TransAmDb, filePath: string, source: string): boolean {
	const changed = setFileText(db.fileInput, filePath, source);
	if (!changed) return false;
	incrementRevision(db.revision);
	const fileId = getFileId(db.fileInput, filePath);
	invalidateFile(db.cache, db.moduleDeps, fileId);
	// Invalidate ExportRegistry for this file + transitive dependents
	dbInvalidateExports(db, fileId);
	return true;
}

// Remove ExportRegistry entries for a file and its transitive dependents
function dbInvalidateExports(db: TransAmDb, fileId: number): void {
	const path = getFilePath(db.fileInput, fileId);
	if (path !== "") removeExportEntry(db.exportRegistry, path);
	const deps = getTransitiveDependents(db.moduleDeps, fileId);
	for (let i = 0; i < deps.length; i = i + 1) {
		const depPath = getFilePath(db.fileInput, deps[i]);
		if (depPath !== "") removeExportEntry(db.exportRegistry, depPath);
	}
}

function removeExportEntry(registry: ExportRegistry, path: string): void {
	for (let i = 0; i < registry.entries.length; i = i + 1) {
		if (registry.entries[i].modulePath === path) {
			// Shift left and pop
			for (let j = i; j < registry.entries.length - 1; j = j + 1) {
				registry.entries[j] = registry.entries[j + 1];
			}
			registry.entries.pop();
			return;
		}
	}
}

// Count of all files in the DB
export function dbGetFileCount(db: TransAmDb): number {
	return getFileCount(db.fileInput);
}

// Get file path by sequential index (0..count-1)
export function dbGetFilePathByIndex(db: TransAmDb, index: number): string {
	return getFilePathByIndex(db.fileInput, index);
}

// Execute parse query for a file. Returns the parsed Node.
export function dbParse(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Parse, fileId);

	// Try cache
	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return nodeCacheGet(parseNodeKey(fileId));
	}

	// Compute
	pushFrame(db.depStack, key);
	// Record file_text dependency
	const fileTextKey = createQueryKey(TaQueryKind.FileText, fileId);
	const fileHash = getFileHash(db.fileInput, fileId);
	recordDependency(db.depStack, fileTextKey, fileHash);

	const source = getFileText(db.fileInput, fileId);
	const parseResult = parseSource(source);
	let program = null as unknown as Node;
	if (parseResult.ok) {
		program = parseResult.value;
	}
	nodeCacheStore(parseNodeKey(fileId), program);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, 0, true);
	return program;
}

// ===== Cross-Module Export Registration =====

// Lazily ensure all files imported by `filePath` have their exports in the registry.
// Walks dep edges (already stored by recordImportsForFile), runs Phase 1 for unregistered deps.
function dbEnsureExportsRegistered(db: TransAmDb, filePath: string, visited: string[]): void {
	// Cycle protection
	for (let vi = 0; vi < visited.length; vi = vi + 1) {
		if (visited[vi] === filePath) return;
	}
	visited.push(filePath);

	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return;

	const depIds = getDirectImports(db.moduleDeps, fileId);
	for (let i = 0; i < depIds.length; i = i + 1) {
		const depId = depIds[i];
		const depPath = getFilePath(db.fileInput, depId);
		if (depPath === "") continue;

		// Skip if already registered
		if (findModuleExports(db.exportRegistry, depPath) !== null) {
			// Still recurse for transitive deps
			dbEnsureExportsRegistered(db, depPath, visited);
			continue;
		}

		// Phase 1: parse + collectTopLevelLocal → register exports
		const depProgram = dbParse(db, depPath);
		if (depProgram === null) continue;

		const tmpCtx = createTempCollectContext();
		collectTopLevelLocal(tmpCtx, depProgram);

		const earlyExports: ExportedSymInfo[] = [];
		for (const sym of tmpCtx.table.current.symbols) {
			if (hasFlag(sym, SF_EXPORTED)) {
				const info: ExportedSymInfo = {
					name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
					overloadTypes: [],
					extReceiverType: "", extIsStatic: false,
					overloadExtReceiverTypes: [], overloadExtIsStatic: [],
					nativeName: sym.nativeName, builtinKind: sym.builtinKind,
					overloadNativeNames: [], overloadBuiltinKinds: [],
					defaultTexts: [], overloadDefaultTexts: [],
				};
				earlyExports.push(info);
			}
		}
		registerModuleExports(db.exportRegistry, depPath, earlyExports);

		// Recurse for transitive deps
		dbEnsureExportsRegistered(db, depPath, visited);
	}
}

// Create a minimal CheckerContext for Phase 1 collection (no imports, no type checking)
function createTempCollectContext(): CheckerContext {
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Module);
	return ctx;
}

// Build ImportEntry[] from parsed program's import declarations + dep edge resolution
function buildImportEntries(db: TransAmDb, filePath: string, program: Node): ImportEntry[] {
	const entries: ImportEntry[] = [];
	if (program === null) return entries;
	if (program.kind !== NodeKind.Program) return entries;
	const pd = program.data as ProgramData;
	const fileId = getFileId(db.fileInput, filePath);

	for (let i = 0; i < pd.programStmts.length; i = i + 1) {
		let stmt = pd.programStmts[i];
		// Unwrap ExportDecl (re-exports)
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind !== NodeKind.ImportDecl) continue;
		const imp = stmt.data as ImportDeclData;

		// Find resolved path from dep edges
		let resolvedPath = "";
		const depIds = getDirectImports(db.moduleDeps, fileId);
		for (let di = 0; di < depIds.length; di = di + 1) {
			const dp = getFilePath(db.fileInput, depIds[di]);
			// Match: dep path should end with the import specifier (+ .ms suffix)
			// More robust: check if this dep was recorded for this import
			if (dp !== "") {
				// Simple heuristic: if specifier is "./foo", path ends with "/foo.ms"
				if (matchesImportSpec(dp, imp.importSource)) {
					resolvedPath = dp;
					break;
				}
			}
		}

		entries.push(createImportEntry(imp.importNames, imp.importAliases, resolvedPath, imp.importSource));
	}
	return entries;
}

// Check if an absolute path matches an import specifier
function matchesImportSpec(absPath: string, spec: string): boolean {
	if (spec === "" || absPath === "") return false;
	// Strip leading "./" or "../" to get the relative stem
	let stem = spec;
	while (stem.length >= 3 && stem[0] === "." && stem[1] === "." && stem[2] === "/") {
		stem = stem.slice(3, stem.length);
	}
	if (stem.length >= 2 && stem[0] === "." && stem[1] === "/") {
		stem = stem.slice(2, stem.length);
	}
	// absPath should end with /stem.ms or /stem/index.ms or /stem/index.cms
	const suffixes = ["/" + stem + ".ms", "/" + stem + "/index.ms", "/" + stem + "/index.cms"];
	for (let si = 0; si < suffixes.length; si = si + 1) {
		const suf = suffixes[si];
		if (absPath.length >= suf.length) {
			if (absPath.slice(absPath.length - suf.length, absPath.length) === suf) return true;
		}
	}
	return false;
}

// Execute type check query. Returns CheckerContext.
export function dbTypeCheck(db: TransAmDb, filePath: string): CheckerContext {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as CheckerContext;
	const key = createQueryKey(TaQueryKind.TypeCheck, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return ctxCacheGet(checkCtxKey(fileId));
	}

	// Ensure parse is up-to-date (records Parse as dependency)
	const program = dbParse(db, filePath);
	if (program === null) return null as unknown as CheckerContext;

	// Ensure cross-module exports are registered for all dependencies
	const visitedPaths: string[] = [];
	dbEnsureExportsRegistered(db, filePath, visitedPaths);

	pushFrame(db.depStack, key);
	const pKey = createQueryKey(TaQueryKind.Parse, fileId);
	recordDependency(db.depStack, pKey, 0);

	const startVersion = getCancelVersion(db.cancelCtx);

	// Cross-module: build synthetic Module + ModuleGraph, use ExportRegistry
	const imports = buildImportEntries(db, filePath, program);
	const mod = createModule(filePath);
	mod.imports = imports;
	const graph = createModuleGraph();
	addModule(graph, mod);
	const checkerCtx = checkProgramWithRegistryCancellable(
		program, db.exportRegistry, graph, mod,
		db.cancelCtx, startVersion
	);

	// If cancelled, discard frame without caching — partial result not reliable
	if (checkCancel(db.cancelCtx, startVersion)) {
		popFrame(db.depStack);
		return checkerCtx;
	}

	ctxCacheStore(checkCtxKey(fileId), checkerCtx);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, 0, true);
	return checkerCtx;
}

// Execute full pipeline: parse → check → transform → analyze
export function dbAnalyze(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Analyze, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return nodeCacheGet(analyzeNodeKey(fileId));
	}

	// Ensure upstream queries are computed
	const program = dbParse(db, filePath);
	if (program === null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	pushFrame(db.depStack, key);
	const ckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	recordDependency(db.depStack, ckKey, 0);

	const transformed = transformProgram(program, checkerCtx, false);
	const analyzed = analyzeProgram(transformed, checkerCtx);
	nodeCacheStore(analyzeNodeKey(fileId), analyzed);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, 0, true);
	return analyzed;
}

// Execute transform query: parse → check → transform (no analyzer)
export function dbTransform(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Transform, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return nodeCacheGet(transformNodeKey(fileId));
	}

	const program = dbParse(db, filePath);
	if (program === null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	pushFrame(db.depStack, key);
	const tckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	recordDependency(db.depStack, tckKey, 0);

	const transformed = transformProgram(program, checkerCtx, false);
	nodeCacheStore(transformNodeKey(fileId), transformed);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, 0, true);
	return transformed;
}

// ===== High-Level Compile API =====

// Compile source through full pipeline (C backend): parse → check → transform → analyze
export function dbCompileSource(db: TransAmDb, source: string): Node {
	const filePath = "__inline__.ms";
	dbSetFileText(db, filePath, source);
	return dbAnalyze(db, filePath);
}

// Compile source for JS backend: parse → check → transform (no analyzer)
export function dbCompileToJS(db: TransAmDb, source: string): Node {
	const filePath = "__inline__.ms";
	dbSetFileText(db, filePath, source);
	return dbTransform(db, filePath);
}

// ===== Re-exports =====

export {
	TaQueryKind, TaQueryState, TaDurability, TaRevision,
	TaQueryKey, createQueryKey, queryKeysEqual,
	createRevision, incrementRevision
} from "./revision";
export { taHashString } from "./hash";
export {
	TaCacheEntry, createCacheEntry,
	TaDependencyStack, createDependencyStack
} from "./query";
export { TaCacheStore, createCacheStore, cacheGet, cachePut } from "./cache";
export {
	TaFileInputStore, createFileInputStore,
	setFileText, getFileText, getFileHash, getFileId, getFilePath, hasFile,
	getFileCount, getFilePathByIndex
} from "./fileInput";
export {
	TaModuleDepGraph, createModuleDepGraph,
	recordModuleImport, clearImportsFor, getTransitiveDependents,
	getDirectImports, detectCycle
} from "./moduleDeps";
export { tryMarkGreen, executeQueryWith, invalidateFile } from "./redGreen";
export {
	TaCancelContext, createCancelContext,
	getCancelVersion, checkCancel, requestCancel, resetCancel
} from "./cancel";
export {
	TaStringInterner, createStringInterner,
	internString, lookupInterned, internedCount
} from "./intern";

// ===== Integration Tests =====

function isValidProgram(program: Node): boolean {
	if (program === null) return false;
	return program.kind === NodeKind.Program;
}

test "create db" {
	const db = createTransAmDb(100);
	expect(db.revision.value === 0);
	expect(db.cache.capacity === 100);
}

test "set file text increments revision" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	expect(db.revision.value === 1);
}

test "same content does not increment" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	expect(db.revision.value === 1);
	dbSetFileText(db, "a.ms", "const x = 1;");
	expect(db.revision.value === 1);  // no change
}

test "parse produces AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	const result = dbParse(db, "test.ms");
	expect(result !== null);
	expect(result.kind === NodeKind.Program);
}

test "parse caches result" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const y = 2;");
	const r1 = dbParse(db, "test.ms");
	expect(r1 !== null);
	// Second call should hit cache
	const key = createQueryKey(TaQueryKind.Parse, 0);
	expect(cacheContains(db.cache, key));
}

test "file change invalidates parse" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const a = 1;");
	dbParse(db, "test.ms");
	// Change file
	dbSetFileText(db, "test.ms", "const b = 2;");
	// Cache entry should be RED
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = cacheGet(db.cache, key);
	expect(entry !== null);
	expect(entry.state === TaQueryState.Red);
}

test "full pipeline produces analyzed AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1; const y = 2;");
	const result = dbAnalyze(db, "test.ms");
	expect(result !== null);
	expect(isValidProgram(result));
}

test "unknown file returns null" {
	const db = createTransAmDb(100);
	const result = dbParse(db, "nonexistent.ms");
	expect(result === null);
}

test "dbTransform produces transformed AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "t.ms", "const x = 1;");
	const result = dbTransform(db, "t.ms");
	expect(result !== null);
	expect(result.kind === NodeKind.Program);
}

test "dbCompileSource runs full pipeline" {
	const db = createTransAmDb(100);
	const result = dbCompileSource(db, "const a = 1; const b = 2;");
	expect(result !== null);
	expect(isValidProgram(result));
}

test "dbCompileToJS runs without analyzer" {
	const db = createTransAmDb(100);
	const result = dbCompileToJS(db, "const x = 42;");
	expect(result !== null);
	expect(result.kind === NodeKind.Program);
}

test "dbCompileSource caches on same input" {
	const db = createTransAmDb(100);
	dbCompileSource(db, "const z = 1;");
	expect(db.revision.value === 1);
	// Same input should not increment revision
	dbCompileSource(db, "const z = 1;");
	expect(db.revision.value === 1);
}

test "db has cancel context" {
	const db = createTransAmDb(100);
	expect(db.cancelCtx.version === 0);
	expect(!db.cancelCtx.cancelled);
}

test "db has string interner" {
	const db = createTransAmDb(100);
	const id = internString(db.interner, "hello");
	expect(id === 0);
	expect(lookupInterned(db.interner, id) === "hello");
}
