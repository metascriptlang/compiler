// Trans-Am Hub — incremental query engine entry point
//
// Pipeline: parse → check → transform → analyze → (codegen)
//           \_______________\________________\_______________/
//                    Trans-Am (incremental query cache)
//
// TransAmDb aggregates all stores. dbSetFileText triggers invalidation.
// dbExecute runs the full pipeline through the red-green engine.

import { Node, NodeKind, Symbol, SymbolKind, TypeKind } from "../../ast/node";
import { readFile as readStdFile } from "std/fs";
import { ResolverConfig, createDefaultConfig, resolveImportWithConfig, Backend } from "../../module/resolver";
import { CheckerContext, CheckerError, CancelCtx, createContext } from "../../checker/context";
import { SymbolFlag, hasFlag, lookupLocal } from "../../checker/symbol";
import {
	TaQueryKey, TaQueryKind, TaQueryState, TaDurability,
	TaRevision, createRevision, incrementRevision,
	createQueryKey, queryKeysEqual
} from "./revision";
import { taHashString } from "./hash";
import {
	TaCacheEntry, createCacheEntry,
	TaDependencyStack,
	createDependencyStack, pushFrame, popFrame, recordDependency, recordDurability,
} from "./query";
import { TaCacheStore, createCacheStore, cacheGet, cachePut, cacheContains, cacheRemove } from "./cache";
import {
	TaFileInputStore, createFileInputStore,
	setFileText, getFileText, getFileHash, getFileId, getFilePath, hasFile,
	getFileCount, getFilePathByIndex,
	getFileDurability, setFileDurability
} from "./fileInput";
import {
	TaModuleDepGraph, createModuleDepGraph,
	recordModuleImport, clearImportsFor, getTransitiveDependents,
	getRegisteredAt, setRegisteredAt, resetRegisteredAt
} from "./moduleDeps";
import { tryMarkGreen, executeQueryWith, invalidateFile } from "./redGreen";
import { transAmHashNode } from "./hash";
import {
	createCancelContext,
	getCancelVersion, checkCancel, requestCancel, resetCancel
} from "./cancel";
import {
	TaStringInterner, createStringInterner,
	internString, lookupInterned, internedCount
} from "./intern";

import { parseSource, parseSourceLenient } from "../../parser/statements/validation";
import { preludeContextFor, bindModuleForCheck, finishModuleCheck, registerBoundModuleFn, BoundModule, sharedPreludeOwns, buildGlobalImportsLayer, bindModulePassesFrom } from "../../checker/checkPass";
import { registerModuleProgram, registerModuleCtx, lookupModuleProgram, lookupModuleCtx, resetInstantiationState } from "../../checker/instantiate";
import { transformProgram } from "../../transform/index";
import { analyzeProgram } from "../../analyzer/index";
import "../../codegen/raiser/eval"; // side-effect: registers macro evaluator callback
import "../meta/expand"; // side-effect: registers expandMacroInvocation callback
import "../meta/modulePass";
import "../meta/comptime"; // side-effect: registers evalComptimeBlock callback
import { ExportRegistry, createExportRegistry, findModuleExports, registerModuleExports, updateModuleExports, findExportedSymbol, collectExports } from "../../checker/context";
import { collectTopLevelLocal, collectTopLevel, declOfStatement } from "../../checker/collectPass";
import { resolveDeclarations } from "../../checker/resolvePass";
import { openScope, ScopeKind } from "../../checker/symbol";
import { ImportDeclData, ExportDeclData, ProgramData, ClassDeclData } from "../../ast/node";
import { ModuleGraph, createModule, createModuleGraph, addModule, findModule, ImportEntry, createImportEntry } from "../../module/graph";
import { getDirectImports } from "./moduleDeps";
import { headerModuleSource, createTaReadProvider, SourceProvider, MapEntry, createMapProvider, loadModuleGraph, collectImportCalls } from "../../module/loader";
import { cloneNodeForCheck } from "../../monomorphize/clone";
import { resolveRuntimeDir } from "../../utils/path";
import { errorCount as checkErrorCount, addError } from "../../checker/context";
import { modulePasses, modulePassExempt, setModulePassExempt, ModulePass } from "../../checker/prelude";

// ===== Stdlib Detection =====

// Check if filePath starts with db.stdPath prefix (set via dbSetStdPath).
// When stdPath is empty (tests, unconfigured), returns false — no files get High durability.
function isStdPathFor(db: TransAmDb, filePath: string): boolean {
	if (db.stdPath.length == 0) return false;
	if (filePath.length < db.stdPath.length) return false;
	for (let i = 0; i < db.stdPath.length; i = i + 1) {
		if (filePath[i] != db.stdPath[i]) return false;
	}
	return true;
}

export function dbSetStdPath(db: TransAmDb, stdPath: string): void {
	db.stdPath = stdPath;
	db.resolverConfig = createDefaultConfig(Backend.C, stdPath);
}

export function dbSetResolverConfig(db: TransAmDb, config: ResolverConfig): void {
	db.stdPath = config.stdPath;
	db.resolverConfig = config;
}

export function dbBindGraph(db: TransAmDb, graph: ModuleGraph): void {
	db.graph = graph;
	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod != null && mod.source != "") dbSetFileText(db, path, mod.rawSource);
	}
	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod == null || mod.source == "") continue;
		const fileId = getFileId(db.fileInput, path);
		clearImportsFor(db.moduleDeps, fileId);
		for (const imp of mod.imports) {
			const targetId = getFileId(db.fileInput, imp.sourcePath);
			if (targetId >= 0) recordModuleImport(db.moduleDeps, fileId, targetId);
		}
	}
}


export function dbEnsurePrelude(db: TransAmDb): void {
	if (db.preludeCtx == null && db.stdPath.length > 0) {
		db.preludeCtx = preludeContextFor(db.stdPath, ".cms");
		// Pre-register exports from top-level std modules (e.g., std/build.ms)
		// so auto-import suggestions work even without explicit imports.
		preRegisterStdModule(db, db.stdPath + "/build.ms", "std/build");
	}
}

// Parse a single file and register its exports into the registry.
function preRegisterStdModule(db: TransAmDb, filePath: string, specifier: string): void {
	const source = try readStdFile(filePath) catch "";
	if (source.length == 0) return;
	const pr = parseSourceLenient(source);
	if (!pr.ok) return;
	const tmpCtx = createTempCollectContext(filePath);
	collectTopLevelLocal(tmpCtx, pr.value);
	resolveDeclarations(tmpCtx, pr.value);
	const exports = collectExports(tmpCtx, filePath);
	if (exports.length > 0) {
		registerModuleExports(db.exportRegistry, filePath, exports);
	}
}

// ===== TransAmDb =====

export class TransAmDb {
	revision: TaRevision;
	fileInput: TaFileInputStore;
	depStack: TaDependencyStack;
	cache: TaCacheStore;
	moduleDeps: TaModuleDepGraph;
	cancelCtx: CancelCtx;
	interner: TaStringInterner;
	exportRegistry: ExportRegistry;
	stdPath: string;
	resolverConfig: ResolverConfig;
	preludeCtx: CheckerContext;
	preprocessCache: HashMap<int32, string>;  // fileId → preprocessed source
	checkInProgress: HashSet<string>;          // cycle guard for macro-dep pre-checks
	graph: ModuleGraph | null;                 // loaded graph whose modules this db checks
	trees: HashMap<int32, Node>;               // tree key → parsed, checked, transformed or analyzed tree
	contexts: HashMap<int32, CheckerContext>;  // check key → checker context
	bound: HashMap<string, BoundCheck>;         // bound and not finished: in progress, or bound on demand from an import cycle
	globalImports: TaGlobalImport[];            // the project's build.ms globalImports, resolved, in build.ms order
	globalClosures: TaGlobalImportClosures;
	globalLayers: TaGlobalImportsLayer[];       // [k - 1]: the names of the first k global imports
	passModules: HashMap<string, CheckerContext>; // global import → the check its module passes were bound from
	passesExemptFor: ModulePass[] | null;
	exemptFrom: TaGlobalImportClosures | null;
}

interface TaGlobalImport {
	entry: string;
	path: string;
}

interface TaGlobalImportClosures {
	revision: int32;
	closures: HashSet<string>[];
	modules: string[];
}

interface TaGlobalImportsLayer {
	checked: CheckerContext[];
	layer: CheckerContext;
}

interface BoundCheck {
	revision: int32;
	inputHash: number;
	unit: BoundModule;
}

function dbTree(db: TransAmDb, key: int32): Node {
	return db.trees.get(key) ?? null as unknown as Node;
}

function dbContext(db: TransAmDb, key: int32): CheckerContext {
	return db.contexts.get(key) ?? null as unknown as CheckerContext;
}

export function createTransAmDb(cacheCapacity: int32): TransAmDb {
	return {
		revision: createRevision(),
		fileInput: createFileInputStore(),
		depStack: createDependencyStack(),
		cache: createCacheStore(cacheCapacity),
		moduleDeps: createModuleDepGraph(),
		cancelCtx: createCancelContext(),
		interner: createStringInterner(),
		exportRegistry: createExportRegistry(),
		stdPath: "",
		resolverConfig: createDefaultConfig(Backend.C, ""),
		preludeCtx: null as unknown as CheckerContext,
		preprocessCache: new HashMap<int32, string>(),
		checkInProgress: new HashSet<string>(),
		graph: null,
		trees: new HashMap<int32, Node>(),
		contexts: new HashMap<int32, CheckerContext>(),
		bound: new HashMap<string, BoundCheck>(),
		globalImports: [],
		globalClosures: { revision: -1, closures: [], modules: [] },
		globalLayers: [],
		passModules: new HashMap<string, CheckerContext>(),
		passesExemptFor: null,
		exemptFrom: null,
	};
}

// Cache key offsets for different query types
function parseNodeKey(fileId: int32): int32 { return fileId; }
function checkCtxKey(fileId: int32): int32 { return fileId + 10000; }
function checkNodeKey(fileId: int32): int32 { return fileId + 15000; }
function transformNodeKey(fileId: int32): int32 { return fileId + 20000; }
function analyzeNodeKey(fileId: int32): int32 { return fileId + 30000; }
function lowerNodeKey(fileId: int32): int32 { return fileId + 40000; }
function exportNodeKey(fileId: int32): int32 { return fileId + 50000; }

// ===== Public API =====

// Set file content. Stores the RAW source as-is; preprocessing happens lazily via
// the Preprocess query (see dbPreprocess). This means .h files are stored as C source,
// .ms files are stored with unresolved .h imports. The Preprocess query handles both,
// with dep tracking so .h changes propagate to dependent .ms files automatically.
export function dbSetFileText(db: TransAmDb, filePath: string, rawSource: string): boolean {
	const changed = setFileText(db.fileInput, filePath, rawSource);
	if (!changed) return false;
	incrementRevision(db.revision);
	const fileId = getFileId(db.fileInput, filePath);
	// G2: Mark stdlib files as High durability (skip verification in tryMarkGreen)
	if (isStdPathFor(db, filePath)) {
		setFileDurability(db.fileInput, fileId, TaDurability.High);
	}
	invalidateFile(db.cache, db.moduleDeps, fileId);
	// Invalidate ExportRegistry for this file + transitive dependents
	dbInvalidateExports(db, fileId);
	return true;
}

export function dbForgetAllTypeChecks(db: TransAmDb): void {
	for (let index = 0; index < getFileCount(db.fileInput); index = index + 1) {
		const path = getFilePathByIndex(db.fileInput, index);
		if (path == "" || isStdPathFor(db, path)) continue;
		cacheRemove(db.cache, createQueryKey(TaQueryKind.TypeCheck, getFileId(db.fileInput, path)));
	}
}

// Resolves build.ms globalImports as the project's implicit imports and returns the entries
// that resolve to no module.
export function dbSetGlobalImports(db: TransAmDb, entries: string[]): string[] {
	const unresolved: string[] = [];
	const resolved: TaGlobalImport[] = [];
	for (const entry of entries) {
		const path = dbResolveImport(db, "virtual:prelude", entry);
		if (path == "") unresolved.push(entry);
		else resolved.push({ entry, path });
	}
	if (sameGlobalImports(db.globalImports, resolved)) return unresolved;
	db.globalImports = resolved;
	db.globalClosures = { revision: -1, closures: [], modules: [] };
	db.globalLayers = [];
	db.passModules = new HashMap<string, CheckerContext>();
	db.passesExemptFor = null;
	db.exemptFrom = null;
	dbForgetAllTypeChecks(db);
	return unresolved;
}

function sameGlobalImports(a: TaGlobalImport[], b: TaGlobalImport[]): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i].entry != b[i].entry || a[i].path != b[i].path) return false;
	}
	return true;
}

function globalImportClosures(db: TransAmDb): TaGlobalImportClosures {
	if (db.globalClosures.revision == db.revision.value) return db.globalClosures;
	const closures: HashSet<string>[] = [];
	const modules: string[] = [];
	const walked = new HashSet<string>();
	for (const global of db.globalImports) {
		const owned = new HashSet<string>();
		const pending: string[] = [global.path];
		while (pending.length > 0) {
			const path = pending.pop()!;
			if (path == "" || owned.has(path) || isStdPathFor(db, path)) continue;
			owned.add(path);
			if (!walked.has(path)) {
				walked.add(path);
				modules.push(path);
			}
			for (const ie of buildImportEntries(db, path, dbParse(db, path))) pending.push(ie.sourcePath);
		}
		closures.push(owned);
	}
	db.globalClosures = { revision: db.revision.value, closures, modules };
	return db.globalClosures;
}

// A module sees the global imports listed before the first one whose import closure holds it,
// as batch checking promotes them in build.ms order.
function visibleGlobalImports(db: TransAmDb, filePath: string): TaGlobalImport[] {
	const visible: TaGlobalImport[] = [];
	if (db.globalImports.length == 0 || isStdPathFor(db, filePath)) return visible;
	const closures = globalImportClosures(db).closures;
	for (let i = 0; i < db.globalImports.length; i += 1) {
		if (closures[i].has(filePath)) break;
		visible.push(db.globalImports[i]);
	}
	return visible;
}

function recordGlobalImportEdges(db: TransAmDb, filePath: string, fileId: int32): void {
	for (const global of visibleGlobalImports(db, filePath)) recordModuleImport(db.moduleDeps, fileId, getFileId(db.fileInput, global.path));
}

function checkGlobalImports(db: TransAmDb, filePath: string, unchecked: string[]): CheckerContext[] {
	const checked: CheckerContext[] = [];
	for (const global of visibleGlobalImports(db, filePath)) {
		if (db.checkInProgress.has(global.path)) {
			unchecked.push(`internal: global import ${global.path} is still being checked when ${filePath} needs it`);
			continue;
		}
		dbRecordDepImports(db, global.path, dbParse(db, global.path));
		const ctx = dbTypeCheck(db, global.path);
		if (ctx == null) continue;
		bindGlobalImportPasses(db, global, ctx);
		checked.push(ctx);
	}
	syncModulePassExempt(db);
	return checked;
}

function bindGlobalImportPasses(db: TransAmDb, global: TaGlobalImport, ctx: CheckerContext): void {
	const fresh = db.passModules.get(global.path) != ctx;
	if (!fresh && db.passesExemptFor == modulePasses()) return;
	for (const pass of modulePasses()) {
		if (pass.entry == global.entry) pass.modulePath = global.path;
	}
	const refused = bindModulePassesFrom(global.path, ctx);
	if (fresh) for (const message of refused) addError(ctx, message, 1, 1);
	db.passModules.set(global.path, ctx);
}

function syncModulePassExempt(db: TransAmDb): void {
	if (db.globalImports.length == 0 || modulePasses().length == 0) return;
	const closures = globalImportClosures(db);
	if (db.passesExemptFor == modulePasses() && db.exemptFrom == closures) return;
	const exempt = new HashSet<string>();
	for (const path of closures.modules) exempt.add(path);
	setModulePassExempt(exempt, db.stdPath);
	db.passesExemptFor = modulePasses();
	db.exemptFrom = closures;
}

function globalImportsLayer(db: TransAmDb, checked: CheckerContext[]): CheckerContext | null {
	if (checked.length == 0) return null;
	while (db.globalLayers.length < checked.length) db.globalLayers.push({ checked: [], layer: null as unknown as CheckerContext });
	const held = db.globalLayers[checked.length - 1];
	if (sameContexts(held.checked, checked)) return held.layer;
	const layer = buildGlobalImportsLayer(db.preludeCtx!.table.identCache, checked);
	db.globalLayers[checked.length - 1] = { checked, layer };
	return layer;
}

function sameContexts(a: CheckerContext[], b: CheckerContext[]): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

// Remove ExportRegistry entries for a file and its transitive dependents
// G3: Skip std/ paths — their exports are immutable for the session
function dbInvalidateExports(db: TransAmDb, fileId: int32): void {
	const path = getFilePath(db.fileInput, fileId);
	if (path != "" && !isStdPathFor(db, path)) removeExportEntry(db.exportRegistry, path);
	resetRegisteredAt(db.moduleDeps, fileId);
	const deps = getTransitiveDependents(db.moduleDeps, fileId);
	for (let i = 0; i < deps.length; i = i + 1) {
		const depPath = getFilePath(db.fileInput, deps[i]);
		if (depPath != "" && !isStdPathFor(db, depPath)) removeExportEntry(db.exportRegistry, depPath);
		resetRegisteredAt(db.moduleDeps, deps[i]);
	}
}

function removeExportEntry(registry: ExportRegistry, path: string): void {
	for (let i = 0; i < registry.entries.length; i = i + 1) {
		if (registry.entries[i].modulePath == path) {
			for (let j = i; j < registry.entries.length - 1; j = j + 1) {
				registry.entries[j] = registry.entries[j + 1];
			}
			registry.entries.pop();
			// moduleIndex must follow: drop the removed path and re-point every
			// shifted entry, or findModuleExports serves ANOTHER module's exports
			// (or reads out of bounds) after any edit-triggered invalidation.
			registry.moduleIndex.delete(path);
			for (let k = i; k < registry.entries.length; k = k + 1) {
				registry.moduleIndex.set(registry.entries[k].modulePath, k);
			}
			return;
		}
	}
}

// Count of all files in the DB
export function dbGetFileCount(db: TransAmDb): int32 {
	return getFileCount(db.fileInput);
}

// Get file path by sequential index (0..count-1)
export function dbGetFilePathByIndex(db: TransAmDb, index: int32): string {
	return getFilePathByIndex(db.fileInput, index);
}

// ===== Preprocess Query =====
//
// Produces preprocessed source for a file. Handles:
//   - .h files: the header's module source (via headerModuleSource)
//   - other: pass through raw
//
// The query runs through Trans-Am's red-green mechanism, so:
//   - Unchanged files return cached preprocessed text instantly
//   - a .h file's own text and its companion .c probe are tracked as FileText deps
//     (via lazy tryMarkGreen verification — on next query, deps are re-checked)

// Trans-Am-backed SourceProvider. When headerModuleSource reads a file through this
// provider, the read records a FileText dependency on the current query frame, so the
// containing Preprocess query auto-invalidates when the .h file changes.
function createTaSourceProvider(db: TransAmDb, currentFileId: int32): SourceProvider {
	return createTaReadProvider((headerPath: string) => {
		dbEnsureFileLoaded(db, headerPath);
		const headerId = getFileId(db.fileInput, headerPath);
		if (headerId < 0) return "";
		// Record FileText dep so tryMarkGreen catches content changes
		const ftKey = createQueryKey(TaQueryKind.FileText, headerId);
		const ftHash = getFileHash(db.fileInput, headerId);
		recordDependency(db.depStack, ftKey, ftHash);
		// Also record module edge (eager invalidation — getTransitiveDependents)
		if (currentFileId >= 0) recordModuleImport(db.moduleDeps, currentFileId, headerId);
		return getFileText(db.fileInput, headerId);
	});
}

export function dbPreprocess(db: TransAmDb, filePath: string): string {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return "";
	const key = createQueryKey(TaQueryKind.Preprocess, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return db.preprocessCache.get(fileId) ?? "";
	}

	pushFrame(db.depStack, key);
	// Self file_text dep: preprocess output depends on the raw source
	const selfFtKey = createQueryKey(TaQueryKind.FileText, fileId);
	const selfHash = getFileHash(db.fileInput, fileId);
	recordDependency(db.depStack, selfFtKey, selfHash);
	// G2: propagate durability (std/ stays High)
	recordDurability(db.depStack, getFileDurability(db.fileInput, fileId));

	const raw = getFileText(db.fileInput, fileId);
	let out = raw;
	const graphMod = db.graph != null ? findModule(db.graph, filePath) : null;

	if (graphMod != null && graphMod.source != "") {
		out = graphMod.source;
	} else if (filePath.endsWith(".h")) {
		out = headerModuleSource(filePath, createTaSourceProvider(db, -1), null, []);
	}

	db.preprocessCache.set(fileId, out);
	const outHash = taHashString(out) as number;
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, outHash, true);
	return out;
}

// Execute parse query for a file. Returns the parsed Node.
export function dbParse(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Parse, fileId);

	// Try cache
	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return dbTree(db, parseNodeKey(fileId));
	}

	// Compute — get preprocessed source via the Preprocess query. This records
	// deps on the file's own FileText AND any .h files it imports, so parse
	// invalidates when the source OR any included header changes.
	const source = dbPreprocess(db, filePath);

	pushFrame(db.depStack, key);
	// Parse depends on Preprocess (for this file).
	const preprocessKey = createQueryKey(TaQueryKind.Preprocess, fileId);
	const preprocessEntry = cacheGet(db.cache, preprocessKey);
	const preprocessHash = preprocessEntry != null ? preprocessEntry.outputHash : 0;
	recordDependency(db.depStack, preprocessKey, preprocessHash);
	// G2: Propagate durability so std/ parse queries inherit High durability
	const fileDur = getFileDurability(db.fileInput, fileId);
	recordDurability(db.depStack, fileDur);

	// Use lenient parse: LSP needs partial ASTs from incomplete code (e.g. "config.")
	const parseResult = parseSourceLenient(source);
	let program = null as unknown as Node;
	if (parseResult.ok) {
		program = parseResult.value;
	}
	db.trees.set(parseNodeKey(fileId), program);
	const parseHash = taHashString(source) as number;
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, parseHash, true);
	return program;
}

// ===== Cross-Module Export Registration =====

// Ensure a file is loaded into the db (read from disk if needed).
// Preprocessing happens lazily via the Preprocess query (dbPreprocess), so this
// just reads raw and stores as-is. The Preprocess query later resolves .h imports.
function dbEnsureFileLoaded(db: TransAmDb, filePath: string): void {
	if (getFileId(db.fileInput, filePath) >= 0) return;
	const raw = try readStdFile(filePath) catch "";
	if (raw.byteLength == 0) return;
	dbSetFileText(db, filePath, raw);
}

// Resolve import specifier to absolute path (relative + std/ imports).
export function dbResolveImport(db: TransAmDb, basePath: string, importSpec: string): string {
	// Use the compiler's resolver with the db's config (includes std/, aliases, packages)
	const candidates = resolveImportWithConfig(importSpec, basePath, db.resolverConfig);
	// Fast path: already in db
	for (const c of candidates) {
		if (getFileId(db.fileInput, c) >= 0) return c;
	}
	// Slow path: try loading from disk
	for (const c of candidates) {
		dbEnsureFileLoaded(db, c);
		if (getFileId(db.fileInput, c) >= 0) return c;
	}
	return "";
}

// Scan a parsed program's imports, resolve paths, load files, record dep edges.
// Enables depth-first traversal in dbEnsureExportsRegistered.
function dbRecordDepImports(db: TransAmDb, depPath: string, depProgram: Node): void {
	const depFileId = getFileId(db.fileInput, depPath);
	if (depFileId < 0) return;
	if (depProgram == null || depProgram.kind != NodeKind.Program) return;
	const pd = depProgram.data as ProgramData;
	for (const rawStmt of pd.programStmts) {
		let stmt = rawStmt;
		if (stmt.kind == NodeKind.ExportDecl) {
			stmt = (stmt.data as ExportDeclData).exportedDecl;
		}
		if (stmt.kind != NodeKind.ImportDecl) continue;
		const imp = stmt.data as ImportDeclData;
		const targetPath = dbResolveImport(db, depPath, imp.importSource);
		if (targetPath == "") continue;
		dbEnsureFileLoaded(db, targetPath);
		const targetId = getFileId(db.fileInput, targetPath);
		if (targetId >= 0) {
			recordModuleImport(db.moduleDeps, depFileId, targetId);
		}
	}
}

// Lazily ensure all files imported by `filePath` have their exports in the registry.
// Depth-first: processes transitive deps before current (compileModule pattern).
function dbEnsureExportsRegistered(db: TransAmDb, filePath: string, visited: HashSet<string>, startVersion: int32): void {
	// Cycle protection — O(1) Set lookup
	if (visited.has(filePath)) return;
	visited.add(filePath);

	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return;

	const depIds = getDirectImports(db.moduleDeps, fileId);
	for (const depId of depIds) {
		// G5: Bail early if cancelled (new keystroke arrived)
		if (checkCancel(db.cancelCtx, startVersion)) return;

		const depPath = getFilePath(db.fileInput, depId);
		if (depPath == "") continue;

		// Skip if registered at current revision (reference: incremental cache hit)
		if (getRegisteredAt(db.moduleDeps, depId) >= db.revision.value) continue;

		// Skip if already registered (but still recurse for transitive deps).
		if (findModuleExports(db.exportRegistry, depPath) != null) {
			// Ensure dep's import edges are recorded before recursing
			if (!visited.has(depPath)) {
				const regProgram = dbParse(db, depPath);
				if (regProgram != null) dbRecordDepImports(db, depPath, regProgram);
			}
			dbEnsureExportsRegistered(db, depPath, visited, startVersion);
			continue;
		}

		// Phase 1: parse dep, record its import edges, then depth-first recurse.
		const depProgram = dbParse(db, depPath);
		if (depProgram == null) continue;

		// Record dep's own import edges so depth-first recursion can traverse them
		dbRecordDepImports(db, depPath, depProgram);
		// Recurse into transitive deps BEFORE resolving this dep
		dbEnsureExportsRegistered(db, depPath, visited, startVersion);
		if (getRegisteredAt(db.moduleDeps, depId) >= db.revision.value) continue;

		// Wire db.exportRegistry + module imports so collectImport can resolve
		// cross-module types (e.g., DrcContext.ctx: TransformContext).
		const tmpCtx = createTempCollectContext(depPath);
		tmpCtx.exportRegistry = db.exportRegistry;
		const depMod = createModule(depPath);
		depMod.imports = buildImportEntries(db, depPath, depProgram);
		tmpCtx.currentModule = depMod;
		const collected = cloneNodeForCheck(depProgram);
		tmpCtx.adoptedDecls = earlyAdoptions(db, depPath, collected);
		collectTopLevel(tmpCtx, collected);
		db.cache.collected += 1;
		resolveDeclarations(tmpCtx, collected);
		db.trees.set(exportNodeKey(depId), collected);

		const earlyExports = collectExports(tmpCtx, depPath);
		registerModuleExports(db.exportRegistry, depPath, earlyExports);
		setRegisteredAt(db.moduleDeps, depId, db.revision.value);
		dbRegisterMacroExpandedExports(db, depPath, depMod.imports, startVersion);
	}
}

// Create a minimal CheckerContext for Phase 1 collection (no imports, no type checking)
function createTempCollectContext(modulePath: string): CheckerContext {
	const ctx = createContext();
	ctx.modulePath = modulePath;
	openScope(ctx.table, ScopeKind.Module);
	return ctx;
}

// Register a single file's exports into the ExportRegistry.
// Used by import completion when the target module hasn't been processed as a dependency yet.
export function dbEnsureModuleExports(db: TransAmDb, filePath: string): void {
	if (findModuleExports(db.exportRegistry, filePath) != null) return;
	const program = dbParse(db, filePath);
	if (program == null) return;
	dbRecordDepImports(db, filePath, program);
	dbEnsureExportsRegistered(db, filePath, new HashSet<string>(), getCancelVersion(db.cancelCtx));
	const tmpCtx = createTempCollectContext(filePath);
	tmpCtx.exportRegistry = db.exportRegistry;
	const depMod = createModule(filePath);
	depMod.imports = buildImportEntries(db, filePath, program);
	tmpCtx.currentModule = depMod;
	const collected = cloneNodeForCheck(program);
	collectTopLevel(tmpCtx, collected);
	db.cache.collected += 1;
	resolveDeclarations(tmpCtx, collected);
	db.trees.set(exportNodeKey(getFileId(db.fileInput, filePath)), collected);
	const exports = collectExports(tmpCtx, filePath);
	if (exports.length > 0) {
		registerModuleExports(db.exportRegistry, filePath, exports);
	}
	dbRegisterMacroExpandedExports(db, filePath, depMod.imports, getCancelVersion(db.cancelCtx));
}

// Build ImportEntry[] from parsed program's import declarations + dep edge resolution
function buildImportEntries(db: TransAmDb, filePath: string, program: Node): ImportEntry[] {
	const entries: ImportEntry[] = [];
	if (program == null) return entries;
	if (program.kind != NodeKind.Program) return entries;
	const pd = program.data as ProgramData;
	const fileId = getFileId(db.fileInput, filePath);

	for (let i = 0; i < pd.programStmts.length; i = i + 1) {
		let stmt = pd.programStmts[i];
		// Unwrap ExportDecl (re-exports)
		if (stmt.kind == NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind != NodeKind.ImportDecl) continue;
		const imp = stmt.data as ImportDeclData;
		// Resolve import specifier using the same resolver as everything else
		const resolvedPath = dbResolveImport(db, filePath, imp.importSource);

		entries.push(createImportEntry(imp.importNames, imp.importAliases, resolvedPath, imp.importSource));
	}
	for (const specifier of collectImportCalls(program)) entries.push(createImportEntry([], [], dbResolveImport(db, filePath, specifier), specifier, true));
	return entries;
}

function checkOutputHash(ctx: CheckerContext, inputHashes: number[]): number {
	let h: number = ctx != null ? checkErrorCount(ctx) : 0;
	for (const input of inputHashes) h = (h * 31 + input) % 2147483647;
	return h;
}

function earlyAdoptions(db: TransAmDb, filePath: string, program: Node): HashMap<Node, Symbol> {
	const adopted = new HashMap<Node, Symbol>();
	const entry = findModuleExports(db.exportRegistry, filePath);
	const parsed = dbTree(db, exportNodeKey(getFileId(db.fileInput, filePath)));
	if (entry == null || parsed == null) return adopted;
	const early = new HashMap<Node, Symbol>();
	for (const info of entry.symbols) {
		if (info.sym.declNode != null && info.sym.modulePath == filePath) early.set(info.sym.declNode, info.sym);
	}
	const parsedStmts = (parsed.data as ProgramData).programStmts;
	const stmts = (program.data as ProgramData).programStmts;
	if (parsedStmts.length != stmts.length) return adopted;
	for (let i = 0; i < stmts.length; i += 1) {
		const parsedDecl = declOfStatement(parsedStmts[i]);
		const decl = declOfStatement(stmts[i]);
		const sym = early.get(parsedDecl);
		if (sym != null) adopted.set(decl, sym);
		if (decl.kind != NodeKind.ClassDecl || parsedDecl.kind != NodeKind.ClassDecl) continue;
		const parsedBody = (parsedDecl.data as ClassDeclData).classBody;
		const body = (decl.data as ClassDeclData).classBody;
		if (parsedBody.length != body.length) continue;
		for (let m = 0; m < body.length; m += 1) {
			const method = early.get(parsedBody[m]);
			if (method != null) adopted.set(body[m], method);
		}
	}
	return adopted;
}

function exportsMacro(db: TransAmDb, modulePath: string): boolean {
	const exports = findModuleExports(db.exportRegistry, modulePath);
	if (exports == null) return false;
	for (const es of exports.symbols) {
		if (es.sym.symbolKind == SymbolKind.Macro) return true;
	}
	return false;
}

function checkMacroDeps(db: TransAmDb, filePath: string, imports: ImportEntry[]): void {
	for (const ie of imports) {
		if (ie.sourcePath == "" || ie.sourcePath == filePath) continue;
		if (db.checkInProgress.has(ie.sourcePath)) continue;
		if (exportsMacro(db, ie.sourcePath)) dbTypeCheck(db, ie.sourcePath);
		else if (db.graph == null) bindUncheckedModule(db, ie.sourcePath);
	}
}

function bindUncheckedModule(db: TransAmDb, modulePath: string): void {
	if (boundInputsUnchanged(db, modulePath) || dbCheckIsCurrent(db, modulePath)) return;
	if (checkedElsewhere(db, modulePath)) return;
	const outerDb = _checkingDb;
	_checkingDb = db;
	const ctx = dbBoundModule(modulePath);
	_checkingDb = outerDb;
	if (ctx != null) registerModuleCtx(modulePath, ctx);
}

function checkedElsewhere(db: TransAmDb, modulePath: string): boolean {
	const held = lookupModuleCtx(modulePath);
	return held != null && held.exportRegistry != db.exportRegistry || sharedPreludeOwns(db.preludeCtx, modulePath);
}

function importsMacro(db: TransAmDb, filePath: string, imports: ImportEntry[]): boolean {
	for (const ie of imports) {
		if (ie.sourcePath != filePath && exportsMacro(db, ie.sourcePath)) return true;
	}
	return false;
}

function dbRegisterMacroExpandedExports(db: TransAmDb, filePath: string, imports: ImportEntry[], startVersion: int32): void {
	if (!importsMacro(db, filePath, imports)) return;
	const outerDb = _checkingDb;
	_checkingDb = db;
	const ctx = dbBoundModule(filePath);
	_checkingDb = outerDb;
	if (ctx == null || checkCancel(db.cancelCtx, startVersion)) return;
	updateModuleExports(db.exportRegistry, filePath, collectExports(ctx, filePath));
}

function boundInputsUnchanged(db: TransAmDb, filePath: string): boolean {
	const entry = db.bound.get(filePath);
	if (entry == null) return false;
	return entry.revision == db.revision.value || entry.inputHash == bindInputHash(db, filePath);
}

function bindInputHash(db: TransAmDb, filePath: string): number {
	let h: number = 0;
	const seen = new HashSet<int32>();
	const pending: int32[] = [getFileId(db.fileInput, filePath)];
	while (pending.length > 0) {
		const fileId = pending.pop()!;
		if (fileId < 0 || seen.has(fileId)) continue;
		seen.add(fileId);
		for (const kind of [TaQueryKind.Parse, TaQueryKind.TypeCheck]) {
			const entry = cacheGet(db.cache, createQueryKey(kind, fileId));
			h = (h * 31 + fileId) % 2147483647;
			h = (h * 31 + (entry != null ? entry.outputHash : 0)) % 2147483647;
		}
		for (const depId of getDirectImports(db.moduleDeps, fileId)) pending.push(depId);
	}
	return h;
}

function boundAtRevision(db: TransAmDb, filePath: string): BoundModule | null {
	const entry = db.bound.get(filePath);
	return entry != null && entry.revision == db.revision.value ? entry.unit : null;
}

function dbBindModule(db: TransAmDb, filePath: string, program: Node, imports: ImportEntry[], globals: CheckerContext[], startVersion: int32): BoundModule {
	const graphMod = db.graph != null ? findModule(db.graph, filePath) : null;
	const graph: ModuleGraph = graphMod != null ? db.graph! : createModuleGraph();
	const mod = graphMod != null ? graphMod : createModule(filePath);
	if (graphMod == null) {
		mod.imports = imports;
		addModule(graph, mod);
	}
	if (db.preludeCtx == null) db.preludeCtx = preludeContextFor(db.stdPath, ".cms");
	registerModuleProgram(filePath, program);
	db.cache.bound += 1;
	const unit = bindModuleForCheck(
		program, db.exportRegistry, graph, mod,
		db.preludeCtx, db.cancelCtx, startVersion,
		earlyAdoptions(db, filePath, program),
		true,
		globalImportsLayer(db, globals)
	);
	if (!checkCancel(db.cancelCtx, startVersion)) db.bound.set(filePath, { revision: db.revision.value, inputHash: bindInputHash(db, filePath), unit });
	return unit;
}

let _checkingDb: TransAmDb | null = null;

function dbBoundModule(modulePath: string): CheckerContext | null {
	const db = _checkingDb;
	if (db == null) return null;
	const fileId = getFileId(db.fileInput, modulePath);
	if (fileId < 0) return null;
	const filePath = getFilePath(db.fileInput, fileId);
	const bound = boundAtRevision(db, filePath);
	if (bound != null) return bound.ctx;
	if (db.checkInProgress.has(filePath)) return null;
	const unchecked: string[] = [];
	const globals = checkGlobalImports(db, filePath, unchecked);
	const cachedProgram = dbParse(db, filePath);
	if (cachedProgram == null) return null;
	const program = cloneNodeForCheck(cachedProgram);
	const startVersion = getCancelVersion(db.cancelCtx);
	dbEnsureExportsRegistered(db, filePath, new HashSet<string>(), startVersion);
	const imports = buildImportEntries(db, filePath, program);
	db.checkInProgress.add(filePath);
	checkMacroDeps(db, filePath, imports);
	const unit = dbBindModule(db, filePath, program, imports, globals, startVersion);
	for (const message of unchecked) addError(unit.ctx, message, 1, 1);
	db.checkInProgress.delete(filePath);
	return unit.ctx;
}

registerBoundModuleFn(dbBoundModule);

// Execute type check query. Returns CheckerContext.
export function dbTypeCheck(db: TransAmDb, filePath: string): CheckerContext {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as CheckerContext;
	const key = createQueryKey(TaQueryKind.TypeCheck, fileId);
	recordGlobalImportEdges(db, filePath, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return dbContext(db, checkCtxKey(fileId));
	}
	const unchecked: string[] = [];
	const globals = checkGlobalImports(db, filePath, unchecked);

	// Get the cached parse tree (needed for dependency hash tracking + to source the clone).
	const cachedProgram = dbParse(db, filePath);
	if (cachedProgram == null) return null as unknown as CheckerContext;

	const startVersion = getCancelVersion(db.cancelCtx);

	// Ensure cross-module exports are registered for all dependencies
	const visitedPaths: HashSet<string> = new HashSet<string>();
	dbEnsureExportsRegistered(db, filePath, visitedPaths, startVersion);

	// Clone the parse tree before type-checking. The checker mutates nodeType/resolvedSym
	// in-place; cloning keeps dbParse's cached tree immutable so other consumers
	// (semantic tokens, syntax queries) see a clean AST. CloneMode.Check preserves
	// typeExpr/typeExprs (resolvePass needs them) and drops nodeType/resolvedSym
	// so the checker re-populates them fresh.
	// This replaces the previous double-parse (parseSourceLenient was called twice).
	const bound = boundAtRevision(db, filePath);
	const program = bound != null ? bound.program : cloneNodeForCheck(cachedProgram);

	// Macro-declaring deps need a FULL check first: checkProgram registers their
	// module ctx (registerModuleCtx), which the comptime engine seeds macro-body
	// imports from (eval.ms lookupModuleCtx). Batch compile gets this for free
	// from dep-order compilation; the db must do it on demand.
	const imports = buildImportEntries(db, filePath, program);
	db.checkInProgress.add(filePath);
	checkMacroDeps(db, filePath, imports);

	pushFrame(db.depStack, key);
	const pKey = createQueryKey(TaQueryKind.Parse, fileId);
	// Record Parse dep with actual output hash (Salsa early cutoff)
	const parseEntry = cacheGet(db.cache, pKey);
	const parseHash = parseEntry != null ? parseEntry.outputHash : 0;
	recordDependency(db.depStack, pKey, parseHash);
	recordDurability(db.depStack, getFileDurability(db.fileInput, fileId));
	const inputHashes: number[] = [parseHash];

	// Record cross-module deps: TypeCheck(A) depends on Parse(B) AND TypeCheck(B) for each import B.
	// Parse dep: structural changes (new/removed declarations).
	// TypeCheck dep: semantic changes (export type signatures, error state).
	// Without TypeCheck dep, changing an export's type in B wouldn't invalidate A if AST shape is same.
	const importDepIds = getDirectImports(db.moduleDeps, fileId);
	for (let di = 0; di < importDepIds.length; di = di + 1) {
		const depId = importDepIds[di];
		const depParseKey = createQueryKey(TaQueryKind.Parse, depId);
		const depParseEntry = cacheGet(db.cache, depParseKey);
		const depParseHash = depParseEntry != null ? depParseEntry.outputHash : 0;
		recordDependency(db.depStack, depParseKey, depParseHash);
		inputHashes.push(depParseHash);
		if (checkedElsewhere(db, getFilePath(db.fileInput, depId))) continue;
		const depCheckKey = createQueryKey(TaQueryKind.TypeCheck, depId);
		const depCheckEntry = cacheGet(db.cache, depCheckKey);
		const depCheckHash = depCheckEntry != null ? depCheckEntry.outputHash : 0;
		recordDependency(db.depStack, depCheckKey, depCheckHash);
		inputHashes.push(depCheckHash);
	}

	if (!modulePassExempt(filePath)) {
		for (const pass of modulePasses()) {
			const passId = getFileId(db.fileInput, pass.modulePath);
			if (passId < 0) continue;
			const passCheckEntry = cacheGet(db.cache, createQueryKey(TaQueryKind.TypeCheck, passId));
			const passCheckHash = passCheckEntry != null ? passCheckEntry.outputHash : 0;
			recordDependency(db.depStack, createQueryKey(TaQueryKind.TypeCheck, passId), passCheckHash);
			inputHashes.push(passCheckHash);
		}
	}

	const outerDb = _checkingDb;
	_checkingDb = db;
	const unit = bound != null ? bound : dbBindModule(db, filePath, program, imports, globals, startVersion);
	const checkerCtx = finishModuleCheck(unit);
	for (const message of unchecked) addError(checkerCtx, message, 1, 1);
	_checkingDb = outerDb;
	db.bound.delete(filePath);

	// If cancelled, discard frame without caching — partial result not reliable
	if (checkCancel(db.cancelCtx, startVersion)) {
		popFrame(db.depStack);
		db.checkInProgress.delete(filePath);
		return checkerCtx;
	}

	db.contexts.set(checkCtxKey(fileId), checkerCtx);
	updateModuleExports(db.exportRegistry, filePath, collectExports(checkerCtx, filePath));
	if (db.graph != null && findModule(db.graph, filePath) != null) setRegisteredAt(db.moduleDeps, fileId, db.revision.value);
	db.trees.set(checkNodeKey(fileId), program);  // cache checked program (has resolvedSym/nodeType)
	inputHashes.push(db.revision.value);
	const checkHash = checkOutputHash(checkerCtx, inputHashes);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, checkHash, true);
	db.checkInProgress.delete(filePath);
	return checkerCtx;
}

// Get the checked program (has resolvedSym/nodeType on AST nodes).
// Falls back to raw parse if no checked version is cached.
export function dbGetCheckedProgram(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const checked = dbTree(db, checkNodeKey(fileId));
	if (checked != null) return checked;
	return dbParse(db, filePath);
}

export function dbCheckIsCurrent(db: TransAmDb, filePath: string): boolean {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return false;
	return tryMarkGreen(db.cache, db.fileInput, createQueryKey(TaQueryKind.TypeCheck, fileId), db.revision.value);
}

export function dbLower<T>(db: TransAmDb, filePath: string, lower: (checked: Node, ctx: CheckerContext, arg: T) => Node, arg: T): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Lower, fileId);
	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) return dbTree(db, lowerNodeKey(fileId));
	const ctx = dbTypeCheck(db, filePath);
	if (ctx == null) return null as unknown as Node;
	const checked = dbTree(db, checkNodeKey(fileId));
	pushFrame(db.depStack, key);
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	const checkEntry = cacheGet(db.cache, checkKey);
	recordDependency(db.depStack, checkKey, checkEntry != null ? checkEntry.outputHash : 0);
	recordDurability(db.depStack, getFileDurability(db.fileInput, fileId));
	const lowered = lower(checked, ctx, arg);
	db.trees.set(lowerNodeKey(fileId), lowered);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, db.revision.value, true);
	return lowered;
}

// Execute full pipeline: parse → check → transform → analyze
export function dbAnalyze(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Analyze, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return dbTree(db, analyzeNodeKey(fileId));
	}

	// Ensure upstream queries are computed
	const _cachedProg = dbParse(db, filePath);
	if (_cachedProg == null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	// Fresh parse for transform — checker already mutated its own copy
	// (enum MemberExpr → Identifier), and transforms also mutate the AST.
	const analyzeSrc = getFileText(db.fileInput, fileId);
	const analyzeParse = parseSource(analyzeSrc);
	const program = analyzeParse.ok ? analyzeParse.value : null as unknown as Node;
	if (program == null) return null as unknown as Node;

	pushFrame(db.depStack, key);
	const ckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	const ckEntry = cacheGet(db.cache, ckKey);
	recordDependency(db.depStack, ckKey, ckEntry != null ? ckEntry.outputHash : 0);

	const transformed = transformProgram(program, checkerCtx, false);
	const analyzed = analyzeProgram(transformed, checkerCtx);
	db.trees.set(analyzeNodeKey(fileId), analyzed);
	const analyzeHash = transAmHashNode(analyzed);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, analyzeHash, true);
	return analyzed;
}

// Execute transform query: parse → check → transform (no analyzer)
export function dbTransform(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Transform, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return dbTree(db, transformNodeKey(fileId));
	}

	const _cachedProg2 = dbParse(db, filePath);
	if (_cachedProg2 == null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	// Fresh parse — checker mutates AST, transforms also mutate
	const txSrc = getFileText(db.fileInput, fileId);
	const txParse = parseSource(txSrc);
	const program = txParse.ok ? txParse.value : null as unknown as Node;
	if (program == null) return null as unknown as Node;

	pushFrame(db.depStack, key);
	const tckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	const tckEntry = cacheGet(db.cache, tckKey);
	recordDependency(db.depStack, tckKey, tckEntry != null ? tckEntry.outputHash : 0);

	const transformed = transformProgram(program, checkerCtx, false);
	db.trees.set(transformNodeKey(fileId), transformed);
	const transformHash = transAmHashNode(transformed);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, transformHash, true);
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

export function dbStats(db: TransAmDb): string {
	const cache = db.cache;
	let recomputed = "";
	for (let kind = 0; kind < cache.recomputed.length; kind++) {
		const count = cache.recomputed[kind];
		if (count > 0) recomputed += ` ${(kind as TaQueryKind).toString()}=${count}`;
	}
	return `entries=${cache.entries.length} hits=${cache.hits} misses=${cache.misses}`
		+ ` marked=${cache.marked} evicted=${cache.evicted} bound=${cache.bound} collected=${cache.collected}`
		+ ` recomputed:${recomputed}`;
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
	createCancelContext,
	getCancelVersion, checkCancel, requestCancel, resetCancel
} from "./cancel";
export {
	TaStringInterner, createStringInterner,
	internString, lookupInterned, internedCount
} from "./intern";

// ===== Integration Tests =====

function isValidProgram(program: Node): boolean {
	if (program == null) return false;
	return program.kind == NodeKind.Program;
}

test "create db" {
	const db = createTransAmDb(100);
	assert db.revision.value == 0;
	assert db.cache.capacity == 100;
}

test "set file text increments revision" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	assert db.revision.value == 1;
}

test "same content does not increment" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	assert db.revision.value == 1;
	dbSetFileText(db, "a.ms", "const x = 1;");
	assert db.revision.value == 1;  // no change
}

test "parse produces AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	const result = dbParse(db, "test.ms");
	assert result != null;
	assert result.kind == NodeKind.Program;
}

test "parse caches result" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const y = 2;");
	const r1 = dbParse(db, "test.ms");
	assert r1 != null;
	// Second call should hit cache
	const key = createQueryKey(TaQueryKind.Parse, 0);
	assert cacheContains(db.cache, key);
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
	assert entry != null;
	assert entry.state == TaQueryState.Red;
}

test "preprocess query passes through non-header files" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "plain.ms", "const x = 1;");
	const out = dbPreprocess(db, "plain.ms");
	assert out == "const x = 1;";
}

test "preprocess query caches result" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "plain.ms", "const x = 1;");
	const out1 = dbPreprocess(db, "plain.ms");
	const out2 = dbPreprocess(db, "plain.ms");
	assert out1 == out2;
	// Second call should be a cache hit — Preprocess query state is Green
	const fileId = getFileId(db.fileInput, "plain.ms");
	const key = createQueryKey(TaQueryKind.Preprocess, fileId);
	const entry = cacheGet(db.cache, key);
	assert entry != null;
	assert entry.state == TaQueryState.Green;
}

test "preprocess query invalidates on file change" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "plain.ms", "const a = 1;");
	dbPreprocess(db, "plain.ms");
	dbSetFileText(db, "plain.ms", "const b = 2;");
	const fileId = getFileId(db.fileInput, "plain.ms");
	const key = createQueryKey(TaQueryKind.Preprocess, fileId);
	const entry = cacheGet(db.cache, key);
	assert entry != null;
	assert entry.state == TaQueryState.Red;
}

test "full pipeline produces analyzed AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1; const y = 2;");
	const result = dbAnalyze(db, "test.ms");
	assert result != null;
	assert isValidProgram(result);
}

test "unknown file returns null" {
	const db = createTransAmDb(100);
	const result = dbParse(db, "nonexistent.ms");
	assert result == null;
}

test "dbTransform produces transformed AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "t.ms", "const x = 1;");
	const result = dbTransform(db, "t.ms");
	assert result != null;
	assert result.kind == NodeKind.Program;
}

test "dbCompileSource runs full pipeline" {
	const db = createTransAmDb(100);
	const result = dbCompileSource(db, "const a = 1; const b = 2;");
	assert result != null;
	assert isValidProgram(result);
}

test "dbCompileToJS runs without analyzer" {
	const db = createTransAmDb(100);
	const result = dbCompileToJS(db, "const x = 42;");
	assert result != null;
	assert result.kind == NodeKind.Program;
}

test "dbCompileSource caches on same input" {
	const db = createTransAmDb(100);
	dbCompileSource(db, "const z = 1;");
	assert db.revision.value == 1;
	// Same input should not increment revision
	dbCompileSource(db, "const z = 1;");
	assert db.revision.value == 1;
}

test "db has cancel context" {
	const db = createTransAmDb(100);
	assert db.cancelCtx.version == 0;
	assert !db.cancelCtx.cancelled;
}

test "db has string interner" {
	const db = createTransAmDb(100);
	const id = internString(db.interner, "hello");
	assert id == 0;
	assert lookupInterned(db.interner, id) == "hello";
}

test "unused .h import identifier gets warning via Phase B" {
	// Verifies the root-cause fix: .h imports now survive preprocessing as
	// real ImportDecl nodes, so the existing reportUnusedImports pass walks
	// them uniformly with .cms imports. No side-channel needed.
	const db = createTransAmDb(100);
	dbSetFileText(db, "fake/os.h",
		"typedef struct CpuInfo { int speed; } CpuInfo;\n" +
		"const char* msOsHostname(void);\n");
	// Line 3 is the import. msOsHostname should be flagged as unused;
	// CpuInfo is used in the return type below and must NOT be flagged.
	dbSetFileText(db, "consumer.cms",
		"// header comment\n" +
		"\n" +
		"import { CpuInfo, msOsHostname } from \"fake/os.h\";\n" +
		"export function getCpu(): CpuInfo { return null as unknown as CpuInfo; }\n");
	const ctx = dbTypeCheck(db, "consumer.cms");
	assert ctx != null;
	let foundUnusedHostname = false;
	let foundUnusedCpuInfo = false;
	for (const err of ctx.errors) {
		if (err.message.indexOf("msOsHostname") >= 0 && err.message.indexOf("imported but never used") >= 0) {
			foundUnusedHostname = true;
			assert err.line == 3;
		}
		if (err.message.indexOf("CpuInfo") >= 0 && err.message.indexOf("imported but never used") >= 0) {
			foundUnusedCpuInfo = true;
		}
	}
	assert foundUnusedHostname;
	assert !foundUnusedCpuInfo;
}

// ===== Salsa Early Cutoff Integration Tests =====

test "a comment-only edit rechecks the module" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	dbTypeCheck(db, "test.ms");
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	assert cacheGet(db.cache, checkKey).state == TaQueryState.Green;

	dbSetFileText(db, "test.ms", "const x = 1; // comment");
	dbParse(db, "test.ms");
	assert !tryMarkGreen(db.cache, db.fileInput, checkKey, db.revision.value);
}

test "an unchanged text keeps the module's check green" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	const first = dbTypeCheck(db, "test.ms");
	dbSetFileText(db, "test.ms", "const x = 1;");
	dbParse(db, "test.ms");
	assert dbTypeCheck(db, "test.ms") == first;
}

test "real code edit invalidates typecheck" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	dbTypeCheck(db, "test.ms");

	// Edit: actual code change
	dbSetFileText(db, "test.ms", "const x = 2;");
	dbParse(db, "test.ms");

	// TypeCheck should NOT verify green (parse output hash changed)
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	assert !tryMarkGreen(db.cache, db.fileInput, checkKey, db.revision.value);
}

test "parse stores real output hash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	dbParse(db, "test.ms");

	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = cacheGet(db.cache, parseKey);
	assert entry != null;
	// outputHash should be non-zero (real AST hash)
	assert entry.outputHash != 0;
}

test "same source produces same parse hash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	dbParse(db, "a.ms");
	const hashA = cacheGet(db.cache, createQueryKey(TaQueryKind.Parse, 0)).outputHash;

	dbSetFileText(db, "b.ms", "const x = 1;");
	dbParse(db, "b.ms");
	const hashB = cacheGet(db.cache, createQueryKey(TaQueryKind.Parse, 1)).outputHash;

	assert hashA == hashB;
}

test "dbTypeCheck records parse dep with real hash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	dbTypeCheck(db, "test.ms");

	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const entry = cacheGet(db.cache, checkKey);
	assert entry != null;
	assert entry.dependencies.length > 0;

	// Find Parse dependency and verify it has a real hash
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	let foundParseDep = false;
	let i = 0;
	while (i < entry.dependencies.length) {
		if (queryKeysEqual(entry.dependencies[i].depKey, parseKey)) {
			// expectedHash should match parse entry's outputHash
			const parseEntry = cacheGet(db.cache, parseKey);
			assert entry.dependencies[i].expectedHash == parseEntry.outputHash;
			foundParseDep = true;
		}
		i = i + 1;
	}
	assert foundParseDep;
}

test "position edits and undo refresh checked spans and lower once per revision" {
	const db = createTransAmDb(100);
	const path = "/reuse/value.ms";
	const source = "export const value: int32 = 1;";
	dbSetFileText(db, path, source);
	dbSetFileText(db, "/reuse/other.ms", "export const other: int32 = 7;");
	const count: LowerCount = { n: 0 };
	const first = dbLower(db, path, countLowering, count);
	const firstCtx = dbTypeCheck(db, path);
	const initialRevision = db.revision.value;
	const fileId = getFileId(db.fileInput, path);
	const kinds: TaQueryKind[] = [TaQueryKind.Parse, TaQueryKind.TypeCheck, TaQueryKind.Lower];
	assert firstCtx.errors.length == 0;
	assert localTypeName(firstCtx, "value") == "int32";
	const firstDecl = (first.data as ProgramData).programStmts[0];
	assert firstDecl.location.line == 1;
	assert firstDecl.location.column == 1;
	assert firstDecl.location.endLine == 1;
	assert firstDecl.location.endColumn == 31;
	assert dbLower(db, path, countLowering, count) == first;
	assert count.n == 1;

	dbSetFileText(db, "/reuse/other.ms", "export const other: int32 = 8;");
	assert db.revision.value > initialRevision;
	assert dbLower(db, path, countLowering, count) == first;
	assert dbTypeCheck(db, path) == firstCtx;
	assert count.n == 1;
	for (const kind of kinds) {
		const entry = cacheGet(db.cache, createQueryKey(kind, fileId));
		assert entry != null;
		assert entry.computedAt == initialRevision;
		assert entry.verifiedAt == db.revision.value;
	}

	const snapshots = ["\n  " + source, source];
	const lines: int32[] = [2, 1];
	const columns: int32[] = [3, 1];
	const ends: int32[] = [33, 31];
	for (let i = 0; i < snapshots.length; i += 1) {
		dbSetFileText(db, path, snapshots[i]);
		const revision = db.revision.value;
		const lowered = dbLower(db, path, countLowering, count);
		const ctx = dbTypeCheck(db, path);
		assert ctx.errors.length == 0;
		assert localTypeName(ctx, "value") == "int32";
		const decl = (lowered.data as ProgramData).programStmts[0];
		assert decl.location.line == lines[i];
		assert decl.location.column == columns[i];
		assert decl.location.endLine == lines[i];
		assert decl.location.endColumn == ends[i];
		assert count.n == i + 2;
		dbSetFileText(db, path, snapshots[i]);
		assert db.revision.value == revision;
		assert dbLower(db, path, countLowering, count) == lowered;
		assert dbTypeCheck(db, path) == ctx;
		assert count.n == i + 2;
		for (const kind of kinds) {
			const entry = cacheGet(db.cache, createQueryKey(kind, fileId));
			assert entry != null;
			assert entry.state == TaQueryState.Green;
			assert entry.computedAt == revision;
			assert entry.verifiedAt == revision;
		}
	}
}

test "syntax error parse still stores hash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "bad.ms", "const = ;");
	dbParse(db, "bad.ms");

	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = cacheGet(db.cache, parseKey);
	assert entry != null;
	// Even failed parse stores a hash (of null node → 0)
	assert entry.state == TaQueryState.Green;
}

test "cross-module interface field resolution" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/test/c.ms", "export interface Bar { value: number; }");
	dbSetFileText(db, "/test/b.ms", 'import { Bar } from "./c";\nexport interface Foo { x: Bar; count: number; }');
	dbSetFileText(db, "/test/a.ms", 'import { Foo } from "./b";\nfunction test(f: Foo): number { return f.count; }');

	const aId = getFileId(db.fileInput, "/test/a.ms");
	const bId = getFileId(db.fileInput, "/test/b.ms");
	recordModuleImport(db.moduleDeps, aId, bId);

	const visited: HashSet<string> = new HashSet<string>();
	dbEnsureExportsRegistered(db, "/test/a.ms", visited, 0);

	// Foo should be registered with resolved fields
	const fooInfo = findExportedSymbol(db.exportRegistry, "/test/b.ms", "Foo");
	assert fooInfo != null;
	const fooType = fooInfo.sym.symbolType;
	assert fooType != null;
	// Interface = Ref<Struct>. Unwrap Ref to get inner Struct.
	const inner = fooType.typeReturn != null ? fooType.typeReturn : fooType;
	assert inner.typeNames != null;
	assert inner.typeNames.length == 2;
	assert inner.typeNames[0] == "x";
	assert inner.typeNames[1] == "count";
	// Field types should be resolved — x: Bar is Ref<Struct(Bar)>
	assert inner.typeChildren != null;
	assert inner.typeChildren.length == 2;
}

test "exported static extension carries its signature" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/test/box.ms", "export struct Box { v: int32; }\nexport function make(this typeof Box, v: int32, w: int32): Box { const b: Box = { v: v + w }; return b; }");
	dbSetFileText(db, "/test/use.ms", 'import { Box } from "./box";\nexport function f(): int32 { return Box.make(3, 4).v; }');
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/test/use.ms"), getFileId(db.fileInput, "/test/box.ms"));
	const visited: HashSet<string> = new HashSet<string>();
	dbEnsureExportsRegistered(db, "/test/use.ms", visited, 0);
	const make = findExportedSymbol(db.exportRegistry, "/test/box.ms", "make");
	assert make != null;
	assert make.ext != null && make.ext.isStatic;
	assert make.sym.symbolType.kind == TypeKind.Function;
	assert make.sym.symbolType.typeChildren.length == 2;
}

test "module exports keep a decorated exported class" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "decmod.ms", "macro noop(value: int32): int32 {\n\treturn value;\n}\n\n@noop\nexport class Widget { v: int32 = 1; }\n");
	dbEnsureModuleExports(db, "decmod.ms");
	const info = findExportedSymbol(db.exportRegistry, "decmod.ms", "Widget");
	assert info != null;
}

test "one module's exports resolve the types it imports from a module not yet registered" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/test/box.ms", "export struct Box { v: int32; }");
	dbSetFileText(db, "/test/use.ms", 'import { Box } from "./box";\nexport function f(b: Box): int32 { return b.v; }');
	dbEnsureModuleExports(db, "/test/use.ms");
	const f = findExportedSymbol(db.exportRegistry, "/test/use.ms", "f");
	assert f != null;
	const param = f.sym.symbolType.typeChildren[0];
	assert param.sym != null && param.sym.modulePath == "/test/box.ms";
}

test "one module's exports resolve what it imports from std" {
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/test/kinds.ms", 'import { NodeKind } from "std/meta";\nexport function kindOf(k: NodeKind): int32 { return k as int32; }');
	dbEnsureModuleExports(db, "/test/kinds.ms");
	const f = findExportedSymbol(db.exportRegistry, "/test/kinds.ms", "kindOf");
	assert f != null;
	const param = f.sym.symbolType.typeChildren[0];
	assert param.sym != null && param.sym.builtinKind == "MetaNodeKind";
}

test "a dependency's exported type keeps its declaring module" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/test/box.ms", "export class Box { v: int32 = 1; }\nexport struct Pair { a: int32; b: int32; }");
	dbSetFileText(db, "/test/use.ms", 'import { Box, Pair } from "./box";\nexport function f(b: Box, p: Pair): int32 { return b.v + p.a; }');
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/test/use.ms"), getFileId(db.fileInput, "/test/box.ms"));
	const visited: HashSet<string> = new HashSet<string>();
	dbEnsureExportsRegistered(db, "/test/use.ms", visited, 0);
	for (const name of ["Box", "Pair"]) {
		const info = findExportedSymbol(db.exportRegistry, "/test/box.ms", name);
		assert info != null;
		assert info.sym.modulePath == "/test/box.ms";
		const t = info.sym.symbolType;
		const inner = t.typeReturn != null ? t.typeReturn : t;
		assert inner.sym != null;
		assert inner.sym.modulePath == "/test/box.ms";
	}
}

test "an importer resolves members through a dependency's checked exports" {
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/test/holder.ms", "export interface Holder { items: Map<int32, string>; }\nexport function makeHolder(): Holder { return { items: new Map<int32, string>() }; }\nexport class Tags { names: Map<string, int32> = new Map<string, int32>(); }");
	dbSetFileText(db, "/test/reader.ms", 'import { Holder, makeHolder, Tags } from "./holder";\nexport function count(): int32 { const h: Holder = makeHolder(); let n = 0; for (const v of h.items.values()) n += v.length; return n; }\nexport function tagged(t: Tags): boolean { return t.names.has("x"); }');
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/test/reader.ms"), getFileId(db.fileInput, "/test/holder.ms"));
	dbTypeCheck(db, "/test/holder.ms");
	const ctx = dbTypeCheck(db, "/test/reader.ms");
	assert ctx != null;
	assert checkErrorCount(ctx) == 0;
}

test "a module's type check registers the program it checked" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/test/registered.ms", "export function one(): int32 { return 1; }");
	const ctx = dbTypeCheck(db, "/test/registered.ms");
	assert ctx != null;
	const program = lookupModuleProgram("/test/registered.ms");
	assert program != null;
	assert program == dbGetCheckedProgram(db, "/test/registered.ms");
}

test "import cycles refresh signatures and reuse lowering through undo and redo" {
	const paths = ["/cycles/a.ms", "/cycles/b.ms", "/cycles/view.ms", "/cycles/stable.ms"];
	const a32 = 'import { fb } from "./b";
export function fa(n: int32): int32 { return fb(n); }';
	const b32 = 'import { fa } from "./a";
export function fb(n: int32): int32 { return n <= 0 ? 0 : fa(n - 1); }';
	const a64 = 'import { fb } from "./b";
export function fa(n: int64): int64 { return fb(n); }';
	const b64 = 'import { fa } from "./a";
export function fb(n: int64): int64 { return n <= 0 ? 0 : fa(n - 1); }';
	const sourcesA = [a32, a64, a32, a64];
	const sourcesB = [b32, b64, b32, b64];
	const types = ["int32", "int64", "int32", "int64"];
	const names = ["fa", "fb", "observed", "stable"];
	for (let order = 0; order < 2; order++) {
		const db = createTransAmDb(100);
		dbSetFileText(db, paths[0], a32);
		dbSetFileText(db, paths[1], b32);
		dbSetFileText(db, paths[2], 'import { fa } from "./a";
export const observed = fa(2);');
		dbSetFileText(db, paths[3], "export const stable: int32 = 7;");
		const aId = getFileId(db.fileInput, paths[0]);
		const bId = getFileId(db.fileInput, paths[1]);
		recordModuleImport(db.moduleDeps, aId, bId);
		recordModuleImport(db.moduleDeps, bId, aId);
		recordModuleImport(db.moduleDeps, getFileId(db.fileInput, paths[2]), aId);
		const counts: LowerCount[] = [{ n: 0 }, { n: 0 }, { n: 0 }, { n: 0 }];
		const indices = order == 0 ? [0, 1, 2, 3] : [1, 0, 2, 3];
		for (let i = 0; i < sourcesA.length; i++) {
			dbSetFileText(db, paths[0], sourcesA[i]);
			dbSetFileText(db, paths[1], sourcesB[i]);
			for (const path of paths) dbParse(db, path);
			for (const j of indices) {
				const ctx = dbTypeCheck(db, paths[j]);
				assert ctx.errors.length == 0;
				const expectedType = j == 3 ? "int32" : types[i];
				const sym = lookupLocal(ctx.table, names[j]);
				assert sym != null;
				if (j < 2) {
					assert sym.symbolType.typeReturn != null;
					assert typeDisplayName(sym.symbolType.typeReturn) == expectedType;
					assert sym.symbolType.typeChildren.length == 1;
					assert typeDisplayName(sym.symbolType.typeChildren[0]) == expectedType;
				} else {
					assert localTypeName(ctx, names[j]) == expectedType;
				}
				const lowered = dbLower(db, paths[j], countLowering, counts[j]);
				const expectedCount = j == 3 ? 1 : i + 1;
				assert counts[j].n == expectedCount;
				assert dbLower(db, paths[j], countLowering, counts[j]) == lowered;
				assert dbTypeCheck(db, paths[j]) == ctx;
				assert counts[j].n == expectedCount;
			}
			const ctxA = dbTypeCheck(db, paths[0]);
			const ctxB = dbTypeCheck(db, paths[1]);
			const fa = lookupLocal(ctxA.table, "fa");
			const fb = lookupLocal(ctxB.table, "fb");
			assert fa != null && fb != null;
			assert lookupLocal(ctxB.table, "fa") == fa;
			assert lookupLocal(ctxA.table, "fb") == fb;
		}
	}
}

test "a db bound to a loaded graph checks each module against the graph's module" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/g/b.ms", entrySource: "export function two(): int32 { return 2; }" });
	entries.push({ entryPath: "/g/a.ms", entrySource: 'import { two } from "./b";\nexport const four = two() + two();' });
	const graph = loadModuleGraph("/g/a.ms", createMapProvider(entries));
	const db = createTransAmDb(100);
	dbBindGraph(db, graph);
	for (const path of graph.loadOrder) dbTypeCheck(db, path);
	const ctx = dbTypeCheck(db, "/g/a.ms");
	assert ctx != null;
	assert checkErrorCount(ctx) == 0;
	assert ctx.currentModule == findModule(graph, "/g/a.ms");
}

const HEADER_API = "int apiValue(int x);";
const HEADER_MAIN = "import { apiValue } from \"./api.h\";\nexport function twice(): int32 { return apiValue(1) + apiValue(2); }";

function headerGraph(): ModuleGraph {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/g/api.h", entrySource: HEADER_API });
	entries.push({ entryPath: "/g/main.ms", entrySource: HEADER_MAIN });
	return loadModuleGraph("/g/main.ms", createMapProvider(entries));
}

test "a db bound to a loaded graph parses the header text the loader inlined" {
	const graph = headerGraph();
	const db = createTransAmDb(100);
	dbBindGraph(db, graph);
	const ctx = dbTypeCheck(db, "/g/main.ms");
	assert ctx != null;
	assert checkErrorCount(ctx) == 0;
	assert dbPreprocess(db, "/g/main.ms") == findModule(graph, "/g/main.ms")!.source;
}

test "an unbound db inlines a C header the way the loader does" {
	const graph = headerGraph();
	const db = createTransAmDb(100);
	dbSetFileText(db, "/g/api.h", HEADER_API);
	dbSetFileText(db, "/g/main.ms", HEADER_MAIN);
	assert dbPreprocess(db, "/g/main.ms") == findModule(graph, "/g/main.ms")!.source;
}

test "a graph-bound check marks its module registered at the current revision" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/g/b.ms", entrySource: "export function two(): int32 { return 2; }" });
	entries.push({ entryPath: "/g/a.ms", entrySource: 'import { two } from "./b";\nexport const four = two() + two();' });
	const graph = loadModuleGraph("/g/a.ms", createMapProvider(entries));
	const db = createTransAmDb(100);
	dbBindGraph(db, graph);
	for (const path of graph.loadOrder) dbTypeCheck(db, path);
	assert getRegisteredAt(db.moduleDeps, getFileId(db.fileInput, "/g/b.ms")) == db.revision.value;
	assert getRegisteredAt(db.moduleDeps, getFileId(db.fileInput, "/g/a.ms")) == db.revision.value;
}

test "two dbs keep their own trees and contexts for the same file id" {
	const first = createTransAmDb(100);
	dbSetFileText(first, "/test/first.ms", "export const firstName = 1;");
	const firstTree = dbParse(first, "/test/first.ms");
	const firstCtx = dbTypeCheck(first, "/test/first.ms");
	const second = createTransAmDb(100);
	dbSetFileText(second, "/test/second.ms", "export const secondName = 2;");
	dbParse(second, "/test/second.ms");
	dbTypeCheck(second, "/test/second.ms");
	assert dbParse(first, "/test/first.ms") == firstTree;
	assert dbTypeCheck(first, "/test/first.ms") == firstCtx;
}

import { typeDisplayName } from "../../checker/types";

function checkChain(db: TransAmDb, paths: string[]): CheckerContext {
	for (const path of paths) dbParse(db, path);
	let last = null as unknown as CheckerContext;
	for (const path of paths) last = dbTypeCheck(db, path);
	return last;
}

function localTypeName(ctx: CheckerContext, name: string): string {
	const sym = lookupLocal(ctx.table, name);
	return sym != null ? typeDisplayName(sym.symbolType) : "";
}

test "an inferred export type change reaches an importer of an importer" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/chain/logic.ms", "export function value(): int32 { return 1; }");
	dbSetFileText(db, "/chain/mid.ms", 'import { value } from "./logic";
export function midValue() { return value(); }');
	dbSetFileText(db, "/chain/far.ms", 'import { midValue } from "./mid";
export const farValue = () => midValue();');
	dbSetFileText(db, "/chain/view.ms", 'import { midValue } from "./mid";
import { farValue } from "./far";
const v = midValue();
const w = farValue();');
	const edges = [["/chain/mid.ms", "/chain/logic.ms"], ["/chain/far.ms", "/chain/mid.ms"], ["/chain/view.ms", "/chain/mid.ms"], ["/chain/view.ms", "/chain/far.ms"]];
	for (const e of edges) recordModuleImport(db.moduleDeps, getFileId(db.fileInput, e[0]), getFileId(db.fileInput, e[1]));
	const order = ["/chain/logic.ms", "/chain/mid.ms", "/chain/far.ms", "/chain/view.ms"];
	const before = checkChain(db, order);
	assert localTypeName(before, "v") == "int32";
	assert localTypeName(before, "w") == "int32";
	dbSetFileText(db, "/chain/logic.ms", "export function value(): int64 { return 1; }");
	const after = checkChain(db, order);
	assert localTypeName(after, "v") == "int64";
	assert localTypeName(after, "w") == "int64";
}

test "exported field edits reach transitive readers through undo and redo" {
	const db = createTransAmDb(100);
	const paths = ["/fields/dep.ms", "/fields/view.ms", "/fields/far.ms", "/fields/stable.ms"];
	const integerSource = 'export interface Reading { value: int32; }
export const reading: Reading = { value: 1 };';
	const stringSource = 'export interface Reading { value: string; }
export const reading: Reading = { value: "ok" };';
	dbSetFileText(db, paths[0], integerSource);
	dbSetFileText(db, paths[1], 'import { reading } from "./dep";
export const observed = reading.value;');
	dbSetFileText(db, paths[2], 'import { observed } from "./view";
export const mirrored = observed;');
	dbSetFileText(db, paths[3], "export const stable: int32 = 7;");
	recordModuleImport(
		db.moduleDeps, getFileId(db.fileInput, paths[1]), getFileId(db.fileInput, paths[0]),
	);
	recordModuleImport(
		db.moduleDeps, getFileId(db.fileInput, paths[2]), getFileId(db.fileInput, paths[1]),
	);
	const counts: LowerCount[] = [{ n: 0 }, { n: 0 }, { n: 0 }, { n: 0 }];
	const names = ["reading", "observed", "mirrored", "stable"];
	const snapshots = [integerSource, stringSource, integerSource, stringSource];
	const types = ["int32", "string", "int32", "string"];
	for (let i = 0; i < snapshots.length; i++) {
		dbSetFileText(db, paths[0], snapshots[i]);
		for (const path of paths) dbParse(db, path);
		const expectedTypes = ["Reading", types[i], types[i], "int32"];
		for (let j = 0; j < paths.length; j++) {
			const ctx = dbTypeCheck(db, paths[j]);
			assert ctx.errors.length == 0;
			assert localTypeName(ctx, names[j]) == expectedTypes[j];
			const lowered = dbLower(db, paths[j], countLowering, counts[j]);
			const expectedCount = j == 3 ? 1 : i + 1;
			assert counts[j].n == expectedCount;
			assert dbLower(db, paths[j], countLowering, counts[j]) == lowered;
			assert dbTypeCheck(db, paths[j]) == ctx;
			assert counts[j].n == expectedCount;
		}
	}
}

test "inferred export changes recompute each transitive importer once per edit through undo and redo" {
	const db = createTransAmDb(100);
	const paths = ["/inferred/logic.ms", "/inferred/mid.ms", "/inferred/far.ms", "/inferred/stable.ms"];
	const narrow = "export function value(): int32 { return 1; }";
	const wide = "export function value(): int64 { return 1; }";
	dbSetFileText(db, paths[0], narrow);
	dbSetFileText(db, paths[1], 'import { value } from "./logic";
export function midValue() { return value(); }
export const viaMid = midValue();');
	dbSetFileText(db, paths[2], 'import { midValue } from "./mid";
export const farValue = () => midValue();
export const viaFar = farValue();');
	dbSetFileText(db, paths[3], "export const stable: int32 = 7;");
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, paths[1]), getFileId(db.fileInput, paths[0]));
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, paths[2]), getFileId(db.fileInput, paths[1]));
	const counts: LowerCount[] = [{ n: 0 }, { n: 0 }, { n: 0 }, { n: 0 }];
	const names = ["value", "viaMid", "viaFar", "stable"];
	const snapshots = [narrow, wide, narrow, wide];
	const types = ["int32", "int64", "int32", "int64"];
	for (let i = 0; i < snapshots.length; i++) {
		dbSetFileText(db, paths[0], snapshots[i]);
		for (const path of paths) dbParse(db, path);
		for (let j = 0; j < paths.length; j++) {
			const ctx = dbTypeCheck(db, paths[j]);
			assert ctx.errors.length == 0;
			const sym = lookupLocal(ctx.table, names[j]);
			assert sym != null;
			const shown = j == 0 ? sym.symbolType.typeReturn : sym.symbolType;
			assert shown != null;
			assert typeDisplayName(shown) == (j == 3 ? "int32" : types[i]);
			const lowered = dbLower(db, paths[j], countLowering, counts[j]);
			const expectedCount = j == 3 ? 1 : i + 1;
			assert counts[j].n == expectedCount;
			assert dbLower(db, paths[j], countLowering, counts[j]) == lowered;
			assert dbTypeCheck(db, paths[j]) == ctx;
			assert counts[j].n == expectedCount;
		}
	}
}

test "a line shift in a dependency moves the declaration its importer resolves in either check order" {
	const paths = ["/moved/dep.ms", "/moved/user.ms"];
	const source = "export function one(): int32 { return 1; }";
	const snapshots = [source, "\n\n" + source, source];
	const lines: int32[] = [1, 3, 1];
	for (const order of [[0, 1], [1, 0]]) {
		const db = createTransAmDb(100);
		dbSetFileText(db, paths[0], source);
		dbSetFileText(db, paths[1], 'import { one } from "./dep";
export const n = one();');
		recordModuleImport(db.moduleDeps, getFileId(db.fileInput, paths[1]), getFileId(db.fileInput, paths[0]));
		const counts: LowerCount[] = [{ n: 0 }, { n: 0 }];
		for (let i = 0; i < snapshots.length; i++) {
			dbSetFileText(db, paths[0], snapshots[i]);
			for (const path of paths) dbParse(db, path);
			for (const j of order) {
				const ctx = dbTypeCheck(db, paths[j]);
				assert ctx.errors.length == 0;
				const one = lookupLocal(ctx.table, "one");
				assert one != null;
				assert one.location.line == lines[i];
				assert one.declNode != null && one.declNode.location.line == lines[i];
				dbLower(db, paths[j], countLowering, counts[j]);
				assert counts[j].n == i + 1;
			}
		}
	}
}

test "a line shift in a module rechecks it at the new positions" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/shift/a.ms", "export function one(): int32 { return 1; }");
	checkChain(db, ["/shift/a.ms"]);
	assert (dbGetCheckedProgram(db, "/shift/a.ms").data as ProgramData).programStmts[0].location.line == 1;
	dbSetFileText(db, "/shift/a.ms", "

export function one(): int32 { return 1; }");
	checkChain(db, ["/shift/a.ms"]);
	assert (dbGetCheckedProgram(db, "/shift/a.ms").data as ProgramData).programStmts[0].location.line == 3;
}

interface LowerCount {
	n: int32;
}

function countLowering(checked: Node, ctx: CheckerContext, count: LowerCount): Node {
	count.n += 1;
	return checked;
}

test "a module's lowering is reused while its check stays green" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/lower/a.ms", "export function one(): int32 { return 1; }");
	dbSetFileText(db, "/lower/b.ms", "export function two(): int32 { return 2; }");
	const count: LowerCount = { n: 0 };
	const first = dbLower(db, "/lower/a.ms", countLowering, count);
	assert dbLower(db, "/lower/a.ms", countLowering, count) == first;
	dbSetFileText(db, "/lower/b.ms", "export function two(): int32 { return 3; }");
	dbParse(db, "/lower/a.ms");
	assert dbLower(db, "/lower/a.ms", countLowering, count) == first;
	assert count.n == 1;
}

test "a module's lowering reruns after its check reruns" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/lower/c.ms", "export function one(): int32 { return 1; }");
	const count: LowerCount = { n: 0 };
	dbLower(db, "/lower/c.ms", countLowering, count);
	dbSetFileText(db, "/lower/c.ms", "export function one(): int32 { return 7; }");
	dbParse(db, "/lower/c.ms");
	dbLower(db, "/lower/c.ms", countLowering, count);
	assert count.n == 2;
}

test "a user module's check keeps its file's durability" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/durable/a.ms", "export function one(): int32 { return 1; }");
	dbTypeCheck(db, "/durable/a.ms");
	const entry = cacheGet(db.cache, createQueryKey(TaQueryKind.TypeCheck, getFileId(db.fileInput, "/durable/a.ms")));
	assert entry.durability == TaDurability.Low;
}

const MAP_USE = "const m = new Map<string, int32>();\nm.set(\"k\", 1);\nconsole.log(m.get(\"k\"), [3, 4].findIndex((x: int32): boolean => x == 4));\n";

function checkAfterOpening(stdFile: string): string[] {
	resetInstantiationState();
	const db = createTransAmDb(100);
	const std = resolveRuntimeDir() + "/std";
	dbSetStdPath(db, std);
	dbSetFileText(db, "/p/a.ms", MAP_USE);
	const problems = dbTypeCheck(db, "/p/a.ms").errors.map((e: CheckerError): string => "before: " + e.message);
	const opened = std + stdFile;
	dbSetFileText(db, opened, try readStdFile(opened) catch "");
	dbTypeCheck(db, opened);
	if (lookupModuleCtx(opened) != null) problems.push(opened + " was registered over the prelude's copy");
	dbSetFileText(db, "/p/a.ms", MAP_USE + "const n = 2;\n");
	const after = dbTypeCheck(db, "/p/a.ms");
	if (lookupModuleCtx("/p/a.ms") != after) problems.push("the edited module is not registered");
	for (const e of after.errors) problems.push("after: " + e.message);
	return problems;
}

test "opening a module the shared prelude loaded leaves its generics on the prelude's copy" {
	const errors = checkAfterOpening("/core/struct.ms");
	assert errors.length == 0, errors.join("\n");
}

test "opening a directory module the shared prelude loaded leaves its generics on the prelude's copy" {
	const errors = checkAfterOpening("/core/array/index.cms");
	assert errors.length == 0, errors.join("\n");
}

test "an edited module checks clean again and stays registered for its importers" {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	for (const tail of ["", "const n = 1;\n", "const n = 2;\n"]) {
		dbSetFileText(db, "/p/b.ms", MAP_USE + tail);
		const ctx = dbTypeCheck(db, "/p/b.ms");
		assert ctx.errors.length == 0, ctx.errors.map((e: CheckerError): string => e.message).join("\n");
		assert lookupModuleCtx("/p/b.ms") == ctx;
	}
}

test "a module the shared prelude imports stays registered when checked, as a build registers it" {
	resetInstantiationState();
	const db = createTransAmDb(100);
	const std = resolveRuntimeDir() + "/std";
	dbSetStdPath(db, std);
	dbSetFileText(db, "/p/c.ms", MAP_USE);
	dbTypeCheck(db, "/p/c.ms");
	const imported = std + "/core/array/shared.ms";
	assert db.preludeCtx.preludeModuleScopes.has(imported), imported;
	dbSetFileText(db, imported, try readStdFile(imported) catch "");
	const ctx = dbTypeCheck(db, imported);
	assert lookupModuleCtx(imported) == ctx;
}
