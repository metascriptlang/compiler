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
import { CheckerContext, CheckerError, CancelCtx, createContext, nextDisamb } from "../../checker/context";
import { SymbolFlag, hasFlag, lookupLocal } from "../../checker/symbol";
import {
	TaQueryKey, TaQueryKind, TaQueryState, TaDurability,
	TaRevision, createRevision, incrementRevision, nextRevision, TA_REVISION_MAX,
	createQueryKey, queryKeysEqual
} from "./revision";
import { taHashString } from "./hash";
import { ifaceDigest, implDigest } from "./digest";
import { installBodyReadSink } from "../../checker/bodyReads";
import {
	TaCacheEntry, createCacheEntry,
	TaDependencyStack,
	createDependencyStack, pushFrame, popFrame, recordDependency, recordDurability,
} from "./query";
import { TaCacheStore, createCacheStore, cacheGet, cachePut, cacheContains, cacheRemove } from "./cache";
import { TaOutputStore, createOutputStore, outputChangedAt } from "./outputs";
import {
	TaFileInputStore, createFileInputStore,
	setFileText, getFileText, getFileId, getFilePath, hasFile,
	getFileCount, getFilePathByIndex,
	getFileDurability, setFileDurability
} from "./fileInput";
import {
	TaModuleDepGraph, createModuleDepGraph,
	recordModuleImport, clearImportsFor, getTransitiveDependents,
	getRegisteredAt, setRegisteredAt, resetRegisteredAt
} from "./moduleDeps";
import { tryMarkGreen, executeQueryWith, invalidateFile } from "./redGreen";
import {
	createCancelContext,
	getCancelVersion, checkCancel, requestCancel, resetCancel
} from "./cancel";

import { parseSource, parseSourceLenient } from "../../parser/statements/validation";
import { preludeContextFor, bindModuleForCheck, finishModuleCheck, BoundModule, sharedPreludeOwns, buildGlobalImportsLayer, bindModulePassesFrom } from "../../checker/checkPass";
import { resetCapturedAssignments, capturedAssignmentCount } from "../../checker/flow";
import { registerModuleProgram, registerModuleCtx, lookupModuleProgram, lookupModuleCtx, resetInstantiationState } from "../../checker/instantiate";
import { registerBoundModuleFn } from "../../checker/checkerCallbacks";
import { transformProgram } from "../../transform/index";
import { lowerIterInline } from "../../transform/lowering/iterInline";
import { createTransformContextWithChecker } from "../../transform/context";
import { analyzeProgram } from "../../analyzer/index";
import { RoutineDecls, createRoutineDecls, createWriteSummaries } from "../../analyzer/writeEffects";
import "../../codegen/raiser/eval"; // side-effect: registers macro evaluator callback
import { macroCompileCount, macroPreprocessCount } from "../meta/expand";
import { boundHandleCount } from "../meta/bridge"; // also registers the expandMacroInvocation callback
import "../meta/modulePass";
import "../meta/comptime"; // side-effect: registers evalComptimeBlock callback
import { lifecycleHookOp } from "../../checker/context";
import { lookupInstanceHook } from "../../checker/instantiate";
import { ExportRegistry, ExportedSymInfo, createExportRegistry, findModuleExports, registerModuleExports, updateModuleExports, findExportedSymbol, collectExports, buildExportInfo } from "../../checker/context";
import { collectTopLevelLocal, collectTopLevel } from "../../checker/collectPass";
import { Adoption, adoptDecls, adoptStmt, moduleSymbols, verifyAdoption } from "./adopt";
import { resolveDeclarations } from "../../checker/resolvePass";
import { openScope, ScopeKind } from "../../checker/symbol";
import { ProgramData, ClassDeclData } from "../../ast/node";
import { ModuleGraph, createModule, createModuleGraph, addModule, findModule, findModuleIndex, ImportEntry, createImportEntry, ParsedModule } from "../../module/graph";
import { getDirectImports } from "./moduleDeps";
import { headerModuleSource, createTaReadProvider, SourceProvider, MapEntry, createMapProvider, loadModuleGraph, parseModuleSourceLenient } from "../../module/loader";
import { cloneNodeForCheck, cloneNodeKeepSem } from "../../monomorphize/clone";
import { resolveRuntimeDir } from "../../utils/path";
import { forEachChild } from "../../ast/visitor";
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
	const exports = checkedByPrelude(db, filePath, collectExports(tmpCtx, filePath));
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
	outputs: TaOutputStore;
	moduleDeps: TaModuleDepGraph;
	cancelCtx: CancelCtx;
	exportRegistry: ExportRegistry;
	stdPath: string;
	resolverConfig: ResolverConfig;
	preludeCtx: CheckerContext;
	preprocessCache: HashMap<int32, string>;  // fileId → preprocessed source
	checkInProgress: HashSet<string>;          // cycle guard for macro-dep pre-checks
	verifying: HashSet<string>;                // modules whose recorded imports are being rechecked for early cutoff
	graph: ModuleGraph | null;                 // loaded graph whose modules this db checks
	editGraph: ModuleGraph;                    // the graph of every module bound outside `graph`; one compilation for the db's life, a rebind replaces the module
	parses: HashMap<int32, ParsedModule>;      // fileId → its parse
	trees: HashMap<int32, Node>;               // tree key → checked, transformed or analyzed tree
	contexts: HashMap<int32, CheckerContext>;  // check key → checker context
	bound: HashMap<string, BoundCheck>;         // bound and not finished: in progress, or bound on demand from an import cycle
	routineDecls: RoutineDecls;
	globalImports: TaGlobalImport[];            // the project's build.ms globalImports, resolved, in build.ms order
	globalClosures: TaGlobalImportClosures;
	globalLayers: TaGlobalImportsLayer[];       // [k - 1]: the names of the first k global imports
	passModules: HashMap<string, CheckerContext>; // global import → the check its module passes were bound from
	passesExemptFor: ModulePass[] | null;
	exemptFrom: TaGlobalImportClosures | null;
	handedToCheck: HashSet<int32> | null;       // null for a kept db; else the files whose parse tree their check took over
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
	inputs: int32[];
	unit: BoundModule;
}

const ABSENT_ENTRY: int32 = -1;

function dbTree(db: TransAmDb, key: int32): Node {
	return db.trees.get(key) ?? null as unknown as Node;
}

function dbContext(db: TransAmDb, key: int32): CheckerContext {
	return db.contexts.get(key) ?? null as unknown as CheckerContext;
}

export function createTransAmDb(cacheCapacity: int32, kept: boolean = true): TransAmDb {
	return {
		revision: createRevision(),
		fileInput: createFileInputStore(),
		depStack: createDependencyStack(),
		cache: createCacheStore(cacheCapacity),
		outputs: createOutputStore(),
		moduleDeps: createModuleDepGraph(),
		cancelCtx: createCancelContext(),
		exportRegistry: createExportRegistry(),
		stdPath: "",
		resolverConfig: createDefaultConfig(Backend.C, ""),
		preludeCtx: null as unknown as CheckerContext,
		preprocessCache: new HashMap<int32, string>(),
		checkInProgress: new HashSet<string>(),
		verifying: new HashSet<string>(),
		graph: null,
		editGraph: createModuleGraph(),
		parses: new HashMap<int32, ParsedModule>(),
		trees: new HashMap<int32, Node>(),
		contexts: new HashMap<int32, CheckerContext>(),
		bound: new HashMap<string, BoundCheck>(),
		routineDecls: createRoutineDecls(),
		globalImports: [],
		globalClosures: { revision: -1, closures: [], modules: [] },
		globalLayers: [],
		passModules: new HashMap<string, CheckerContext>(),
		passesExemptFor: null,
		exemptFrom: null,
		handedToCheck: kept ? null : new HashSet<int32>(),
	};
}

const STAGE_COUNT: int32 = 7;

function stageKey(fileId: int32, stage: int32): int32 {
	if (fileId < 0 || fileId > (2147483647 - stage) / STAGE_COUNT) throw new Error(`internal: Trans-Am file id ${fileId} has no stage key`);
	return fileId * STAGE_COUNT + stage;
}

function parseNodeKey(fileId: int32): int32 { return stageKey(fileId, 0); }
function checkCtxKey(fileId: int32): int32 { return stageKey(fileId, 1); }
function checkNodeKey(fileId: int32): int32 { return stageKey(fileId, 2); }
function transformNodeKey(fileId: int32): int32 { return stageKey(fileId, 3); }
function analyzeNodeKey(fileId: int32): int32 { return stageKey(fileId, 4); }
function lowerNodeKey(fileId: int32): int32 { return stageKey(fileId, 5); }
function exportNodeKey(fileId: int32): int32 { return stageKey(fileId, 6); }

// ===== Public API =====

// Set file content. Stores the RAW source as-is; preprocessing happens lazily via
// the Preprocess query (see dbPreprocess). This means .h files are stored as C source,
// .ms files are stored with unresolved .h imports. The Preprocess query handles both,
// with dep tracking so .h changes propagate to dependent .ms files automatically.
export function dbSetFileText(db: TransAmDb, filePath: string, rawSource: string): boolean {
	const known = getFileId(db.fileInput, filePath);
	if (known >= 0 && getFileText(db.fileInput, known) == rawSource) return false;
	const revision = nextRevision(db.revision);
	setFileText(db.fileInput, filePath, rawSource, revision);
	db.revision.value = revision;
	const fileId = getFileId(db.fileInput, filePath);
	// G2: Mark stdlib files as High durability (skip verification in tryMarkGreen)
	if (isStdPathFor(db, filePath)) {
		setFileDurability(db.fileInput, fileId, TaDurability.High, revision);
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
			for (const ie of buildImportEntries(db, path)) pending.push(ie.sourcePath);
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
		dbRecordDepImports(db, global.path);
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
		recordDependency(db.depStack, createQueryKey(TaQueryKind.FileText, headerId));
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
	recordDependency(db.depStack, createQueryKey(TaQueryKind.FileText, fileId));
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

	let changedAt = db.revision.value;
	const previous = cacheGet(db.cache, key);
	if (previous != null && db.preprocessCache.get(fileId) == out) changedAt = previous.changedAt;
	db.preprocessCache.set(fileId, out);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, changedAt, true);
	return out;
}

// The tree of a file's parse, before any check took it.
export function dbParse(db: TransAmDb, filePath: string): Node {
	const parsed = dbParsed(db, filePath);
	if (parsed == null) return null as unknown as Node;
	if (db.handedToCheck != null && db.handedToCheck.has(getFileId(db.fileInput, filePath))) throw new Error(`internal: the parse tree of ${filePath} was handed to its check`);
	if (parsed.consumedBy != "") throw new Error(`internal: dbParse read the parse of ${filePath} after ${parsed.consumedBy} took it`);
	return parsed.program;
}

// Execute parse query for a file.
function dbParsed(db: TransAmDb, filePath: string): ParsedModule | null {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null;
	const key = createQueryKey(TaQueryKind.Parse, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) return db.parses.get(fileId) ?? null;

	// Compute — get preprocessed source via the Preprocess query. This records
	// deps on the file's own FileText AND any .h files it imports, so parse
	// invalidates when the source OR any included header changes.
	const source = dbPreprocess(db, filePath);

	pushFrame(db.depStack, key);
	// Parse depends on Preprocess (for this file).
	const preprocessKey = createQueryKey(TaQueryKind.Preprocess, fileId);
	recordDependency(db.depStack, preprocessKey);
	// G2: Propagate durability so std/ parse queries inherit High durability
	const fileDur = getFileDurability(db.fileInput, fileId);
	recordDurability(db.depStack, fileDur);

	const parsed = adoptLoaderParse(db, filePath, source);
	if (parsed != null) db.parses.set(fileId, parsed);
	else db.parses.delete(fileId);
	const preprocessEntry = cacheGet(db.cache, preprocessKey);
	const changedAt = preprocessEntry != null ? preprocessEntry.changedAt : db.revision.value;
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, changedAt, true);
	return parsed;
}

function adoptLoaderParse(db: TransAmDb, filePath: string, source: string): ParsedModule | null {
	const loaded = takeGraphParse(db, filePath, source);
	if (loaded != null) return loaded;
	// Use lenient parse: LSP needs partial ASTs from incomplete code (e.g. "config.")
	const parseResult = parseModuleSourceLenient(source);
	return parseResult.ok ? parseResult.value : null;
}

function takeGraphParse(db: TransAmDb, filePath: string, source: string): ParsedModule | null {
	const graphMod = db.graph != null ? findModule(db.graph, filePath) : null;
	if (graphMod == null || graphMod.program == null || graphMod.source != source) return null;
	const parsed: ParsedModule = { program: graphMod.program!, imports: graphMod.parsedImports, consumedBy: "" };
	graphMod.program = null;
	return parsed;
}

// The parse of a file as it was before any check. A loaded graph parses every module again on each
// load, so a parse an earlier revision's check took is replaced by the graph's.
function preCheckParse(db: TransAmDb, filePath: string, reader: string): ParsedModule | null {
	const parsed = dbParsed(db, filePath);
	if (parsed == null || parsed.consumedBy == "") return parsed;
	const fileId = getFileId(db.fileInput, filePath);
	const loaded = takeGraphParse(db, filePath, db.preprocessCache.get(fileId) ?? "");
	if (loaded == null) throw new Error(`internal: ${reader} read the parse of ${filePath} after ${parsed.consumedBy} took it`);
	db.parses.set(fileId, loaded);
	return loaded;
}

// The tree a check of filePath mutates. A module outside the loaded graph is checked on a clone,
// because the LSP reads its parse after the check and rechecks it after an edit elsewhere.
function treeForCheck(db: TransAmDb, filePath: string, reader: string): Node {
	const parsed = preCheckParse(db, filePath, reader);
	if (parsed == null) return null as unknown as Node;
	if (db.handedToCheck == null && (db.graph == null || findModule(db.graph, filePath) == null)) return cloneNodeForCheck(parsed.program);
	parsed.consumedBy = reader;
	return parsed.program;
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

// Resolve a parse's import declarations, load their files, record dep edges.
// Enables depth-first traversal in dbEnsureExportsRegistered.
function dbRecordDepImports(db: TransAmDb, depPath: string): void {
	const depFileId = getFileId(db.fileInput, depPath);
	if (depFileId < 0) return;
	const parsed = dbParsed(db, depPath);
	if (parsed == null) return;
	for (const imp of parsed.imports) {
		if (imp.dynamic) continue;
		const targetPath = dbResolveImport(db, depPath, imp.sourceSpecifier);
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
		const registeredAt = getRegisteredAt(db.moduleDeps, depId);
		if (registeredAt != null && registeredAt >= db.revision.value) continue;

		// Skip if already registered (but still recurse for transitive deps).
		if (findModuleExports(db.exportRegistry, depPath) != null) {
			// Ensure dep's import edges are recorded before recursing
			if (!visited.has(depPath)) dbRecordDepImports(db, depPath);
			dbEnsureExportsRegistered(db, depPath, visited, startVersion);
			continue;
		}

		// Phase 1: parse dep, record its import edges, then depth-first recurse.
		const depParse = preCheckParse(db, depPath, "dbEnsureExportsRegistered");
		if (depParse == null) continue;

		// Record dep's own import edges so depth-first recursion can traverse them
		dbRecordDepImports(db, depPath);
		// Recurse into transitive deps BEFORE resolving this dep
		dbEnsureExportsRegistered(db, depPath, visited, startVersion);
		const registeredAtNow = getRegisteredAt(db.moduleDeps, depId);
		if (registeredAtNow != null && registeredAtNow >= db.revision.value) continue;
		if (registerCheckedExports(db, depPath, depId)) continue;

		// Wire db.exportRegistry + module imports so collectImport can resolve
		// cross-module types (e.g., DrcContext.ctx: TransformContext).
		const tmpCtx = createTempCollectContext(depPath);
		tmpCtx.exportRegistry = db.exportRegistry;
		const depMod = createModule(depPath);
		depMod.imports = buildImportEntries(db, depPath);
		tmpCtx.currentModule = depMod;
		const collected = cloneNodeForCheck(depParse.program);
		const adoption = earlyAdoptions(db, depPath);
		tmpCtx.adoptedDecls = adoption.decls;
		tmpCtx.adoptStmt = (stmt: Node): void => adoptStmt(adoption, stmt);
		collectTopLevel(tmpCtx, collected);
		db.cache.collected += 1;
		resolveDeclarations(tmpCtx, collected);
		if (!checkCancel(db.cancelCtx, startVersion)) verifyAdoption(adoption);
		db.trees.set(exportNodeKey(depId), collected);

		const earlyExports = checkedByPrelude(db, depPath, collectExports(tmpCtx, depPath));
		registerModuleExports(db.exportRegistry, depPath, earlyExports);
		setRegisteredAt(db.moduleDeps, depId, db.revision.value);
		dbRegisterMacroExpandedExports(db, depPath, depMod.imports, startVersion);
	}
}

function registerCheckedExports(db: TransAmDb, depPath: string, depId: int32): boolean {
	const ctx = db.contexts.get(checkCtxKey(depId));
	if (ctx == null || checkedElsewhere(db, depPath)) return false;
	if (!tryMarkGreen(db.cache, db.fileInput, createQueryKey(TaQueryKind.TypeCheck, depId), db.revision.value)) return false;
	updateModuleExports(db.exportRegistry, depPath, collectExports(ctx, depPath));
	setRegisteredAt(db.moduleDeps, depId, db.revision.value);
	return true;
}

// A module the shared prelude holds is body-checked once, there, and the graph never checks it again: its
// importers must receive that checked copy, not the declaration-only symbols this collection produced.
function checkedByPrelude(db: TransAmDb, modulePath: string, collected: ExportedSymInfo[]): ExportedSymInfo[] {
	const prelude = db.preludeCtx;
	if (prelude == null || !prelude.preludeModuleScopes.has(modulePath)) return collected;
	const out: ExportedSymInfo[] = [];
	for (const info of collected) {
		const routine = info.sym.symbolKind == SymbolKind.Function || info.sym.symbolKind == SymbolKind.Method;
		if (!routine || !prelude.preludeModuleScopes.has(info.sym.modulePath)) {
			out.push(info);
			continue;
		}
		const held = preludeHeldSymbol(prelude, info);
		if (held == null) throw new Error(`internal: the shared prelude holds ${info.sym.modulePath} but no symbol '${info.sym.name}' of it, exported by ${modulePath}`);
		out.push(buildExportInfo(held, prelude.extensionRegistry, modulePath, prelude, info.name));
	}
	return out;
}

// The prelude's own copy of an export: a module-scope symbol, a static member of one, or the extension routine registered for it.
function preludeHeldSymbol(prelude: CheckerContext, info: ExportedSymInfo): Symbol | null {
	const home = info.sym.modulePath;
	const scope = prelude.preludeModuleScopes.get(home);
	if (scope == null) return null;
	for (const sym of scope) {
		if (sym.name == info.sym.name && sym.modulePath == home) return sym;
		if (sym.staticFields == null) continue;
		for (const field of sym.staticFields) {
			if (field.name == info.sym.name && field.modulePath == home) return field;
		}
	}
	const ext = info.ext;
	if (ext == null || prelude.extensionRegistry == null) return null;
	for (const held of prelude.extensionRegistry.methods) {
		if (held.sym == null || held.methodName != ext.methodName || held.isStatic != ext.isStatic || held.sym.modulePath != home) continue;
		if (sameDeclaration(held.sym, info.sym)) return held.sym;
	}
	return null;
}

function sameDeclaration(a: Symbol, b: Symbol): boolean {
	return a.declNode != null && b.declNode != null && a.declNode.location.line == b.declNode.location.line && a.declNode.location.column == b.declNode.location.column;
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
	const parsed = preCheckParse(db, filePath, "dbEnsureModuleExports");
	if (parsed == null) return;
	dbRecordDepImports(db, filePath);
	dbEnsureExportsRegistered(db, filePath, new HashSet<string>(), getCancelVersion(db.cancelCtx));
	const tmpCtx = createTempCollectContext(filePath);
	tmpCtx.exportRegistry = db.exportRegistry;
	const depMod = createModule(filePath);
	depMod.imports = buildImportEntries(db, filePath);
	tmpCtx.currentModule = depMod;
	const collected = cloneNodeForCheck(parsed.program);
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

// The parse's imports, resolved with the same resolver as everything else.
function buildImportEntries(db: TransAmDb, filePath: string): ImportEntry[] {
	const entries: ImportEntry[] = [];
	const parsed = dbParsed(db, filePath);
	if (parsed == null) return entries;
	for (const imp of parsed.imports) {
		entries.push(createImportEntry(imp.names, imp.aliases, dbResolveImport(db, filePath, imp.sourceSpecifier), imp.sourceSpecifier, imp.dynamic));
	}
	return entries;
}

function earlyAdoptions(db: TransAmDb, filePath: string): Adoption {
	const fileId = getFileId(db.fileInput, filePath);
	const checked = dbTree(db, checkNodeKey(fileId));
	const checkedCtx = db.contexts.get(checkCtxKey(fileId));
	if (checked != null && checkedCtx != null) return adoptDecls(checked, moduleSymbols(checkedCtx.table, filePath), filePath);
	const entry = findModuleExports(db.exportRegistry, filePath);
	const parsed = dbTree(db, exportNodeKey(fileId));
	if (entry == null || parsed == null) return new Adoption();
	const exported: Symbol[] = [];
	for (const info of entry.symbols) exported.push(info.sym);
	return adoptDecls(parsed, exported, filePath);
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
	dbBoundModule(modulePath);
	_checkingDb = outerDb;
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
	return entry.revision == db.revision.value || sameInputs(entry.inputs, bindInputs(db, filePath));
}

function sameInputs(a: int32[], b: int32[]): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

function bindInputs(db: TransAmDb, filePath: string): int32[] {
	const inputs: int32[] = [];
	const seen = new HashSet<int32>();
	const pending: int32[] = [getFileId(db.fileInput, filePath)];
	while (pending.length > 0) {
		const fileId = pending.pop()!;
		if (fileId < 0 || seen.has(fileId)) continue;
		seen.add(fileId);
		inputs.push(fileId);
		inputs.push(getFileChangedAt(db.fileInput, fileId) ?? ABSENT_ENTRY);
		for (const kind of [TaQueryKind.Parse, TaQueryKind.TypeCheck]) {
			const entry = cacheGet(db.cache, createQueryKey(kind, fileId));
			inputs.push(entry != null ? entry.changedAt : ABSENT_ENTRY);
		}
		for (const depId of getDirectImports(db.moduleDeps, fileId)) pending.push(depId);
	}
	return inputs;
}

function reusableBound(db: TransAmDb, filePath: string): BoundModule | null {
	const entry = db.bound.get(filePath);
	return entry != null && boundInputsUnchanged(db, filePath) ? entry.unit : null;
}

function dbBindModule(db: TransAmDb, filePath: string, program: Node, imports: ImportEntry[], globals: CheckerContext[], startVersion: int32): BoundModule {
	const graphMod = db.graph != null ? findModule(db.graph, filePath) : null;
	const graph: ModuleGraph = graphMod != null ? db.graph! : db.editGraph;
	const mod = graphMod != null ? graphMod : createModule(filePath);
	if (graphMod == null) {
		mod.imports = imports;
		const at = findModuleIndex(graph, filePath);
		if (at >= 0) graph.modules[at] = mod;
		else addModule(graph, mod);
	}
	if (db.preludeCtx == null) db.preludeCtx = preludeContextFor(db.stdPath, ".cms");
	resetCapturedAssignments();
	registerModuleProgram(filePath, program);
	db.cache.bound += 1;
	const adoption = earlyAdoptions(db, filePath);
	const unit = bindModuleForCheck(
		program, db.exportRegistry, graph, mod,
		db.preludeCtx, db.cancelCtx, startVersion,
		adoption.decls,
		(stmt: Node): void => adoptStmt(adoption, stmt),
		true,
		globalImportsLayer(db, globals)
	);
	if (!checkCancel(db.cancelCtx, startVersion)) verifyAdoption(adoption);
	if (!checkCancel(db.cancelCtx, startVersion)) db.bound.set(filePath, { revision: db.revision.value, inputs: bindInputs(db, filePath), unit });
	return unit;
}

let _checkingDb: TransAmDb | null = null;

function dbBoundModule(modulePath: string): CheckerContext | null {
	const db = _checkingDb;
	if (db == null) return null;
	const fileId = getFileId(db.fileInput, modulePath);
	if (fileId < 0) return null;
	const filePath = getFilePath(db.fileInput, fileId);
	const bound = reusableBound(db, filePath);
	if (bound != null) return bound.ctx;
	if (db.checkInProgress.has(filePath)) return null;
	const unchecked: string[] = [];
	const globals = checkGlobalImports(db, filePath, unchecked);
	const program = treeForCheck(db, filePath, "dbBoundModule");
	if (program == null) return null;
	const startVersion = getCancelVersion(db.cancelCtx);
	dbEnsureExportsRegistered(db, filePath, new HashSet<string>(), startVersion);
	const imports = buildImportEntries(db, filePath);
	db.checkInProgress.add(filePath);
	checkMacroDeps(db, filePath, imports);
	const unit = dbBindModule(db, filePath, program, imports, globals, startVersion);
	for (const message of unchecked) addError(unit.ctx, message, 1, 1);
	db.checkInProgress.delete(filePath);
	if (!checkedElsewhere(db, filePath) && !checkCancel(db.cancelCtx, startVersion)) registerModuleCtx(filePath, unit.ctx);
	return unit.ctx;
}

registerBoundModuleFn(dbBoundModule);

// An import this db only binds has no TypeCheck entry to depend on: its bound exports read the
// parses of its own imports, down to the modules this db checks.
function recordBoundImportReads(db: TransAmDb, boundId: int32, reached: HashSet<int32>): void {
	const pending: int32[] = [];
	for (const depId of getDirectImports(db.moduleDeps, boundId)) pending.push(depId);
	while (pending.length > 0) {
		const depId = pending.pop()!;
		if (reached.has(depId)) continue;
		reached.add(depId);
		const parseKey = createQueryKey(TaQueryKind.Parse, depId);
		const parseEntry = cacheGet(db.cache, parseKey);
		if (parseEntry == null) continue;
		recordDependency(db.depStack, parseKey);
		if (checkedElsewhere(db, getFilePath(db.fileInput, depId))) continue;
		const checkKey = createQueryKey(TaQueryKind.TypeCheck, depId);
		if (cacheGet(db.cache, checkKey) != null) {
			recordDependency(db.depStack, checkKey);
			continue;
		}
		for (const next of getDirectImports(db.moduleDeps, depId)) pending.push(next);
	}
}

// The discarded unit's export Symbols die with it, so a reader that kept them is rechecked
// against the next unit, as a recompiled module marks its clients dirty.
function forgetClientsOfDiscardedUnit(db: TransAmDb, fileId: int32): void {
	dbInvalidateExports(db, fileId);
	for (const clientId of getTransitiveDependents(db.moduleDeps, fileId)) {
		cacheRemove(db.cache, createQueryKey(TaQueryKind.TypeCheck, clientId));
	}
}

// Execute type check query. Returns CheckerContext.
export function dbTypeCheck(db: TransAmDb, filePath: string): CheckerContext {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as CheckerContext;
	const key = createQueryKey(TaQueryKind.TypeCheck, fileId);
	recordGlobalImportEdges(db, filePath, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return dbContext(db, checkCtxKey(fileId));
	}
	if (recheckImports(db, key) && tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return dbContext(db, checkCtxKey(fileId));
	}
	const unchecked: string[] = [];
	const globals = checkGlobalImports(db, filePath, unchecked);

	if (dbParsed(db, filePath) == null) return null as unknown as CheckerContext;

	const startVersion = getCancelVersion(db.cancelCtx);

	// Ensure cross-module exports are registered for all dependencies
	const visitedPaths: HashSet<string> = new HashSet<string>();
	dbEnsureExportsRegistered(db, filePath, visitedPaths, startVersion);

	const bound = reusableBound(db, filePath);
	const program = bound != null ? bound.program : treeForCheck(db, filePath, "dbTypeCheck");

	// Macro-declaring deps need a FULL check first: checkProgram registers their
	// module ctx (registerModuleCtx), which the comptime engine seeds macro-body
	// imports from (eval.ms lookupModuleCtx). Batch compile gets this for free
	// from dep-order compilation; the db must do it on demand.
	const imports = buildImportEntries(db, filePath);
	db.checkInProgress.add(filePath);
	checkMacroDeps(db, filePath, imports);

	pushFrame(db.depStack, key);
	const pKey = createQueryKey(TaQueryKind.Parse, fileId);
	recordDependency(db.depStack, pKey);
	recordDurability(db.depStack, getFileDurability(db.fileInput, fileId));

	const importDepIds = getDirectImports(db.moduleDeps, fileId);
	const interfaceDeps: TaQueryKey[] = [];
	const reached = new HashSet<int32>();
	reached.add(fileId);
	for (const depId of importDepIds) reached.add(depId);
	for (let di = 0; di < importDepIds.length; di = di + 1) {
		const depId = importDepIds[di];
		const depCheckKey = createQueryKey(TaQueryKind.TypeCheck, depId);
		const depCheckEntry = checkedElsewhere(db, getFilePath(db.fileInput, depId)) ? null : cacheGet(db.cache, depCheckKey);
		if (depCheckEntry != null) {
			recordDependency(db.depStack, depCheckKey);
			if (!importReaches(db, depId, fileId)) interfaceDeps.push(depCheckKey);
			continue;
		}
		recordParseRead(db, depId);
		if (!checkedElsewhere(db, getFilePath(db.fileInput, depId))) recordBoundImportReads(db, depId, reached);
	}

	if (!modulePassExempt(filePath)) {
		for (const pass of modulePasses()) {
			const passId = getFileId(db.fileInput, pass.modulePath);
			if (passId < 0) continue;
			recordDependency(db.depStack, createQueryKey(TaQueryKind.TypeCheck, passId));
		}
	}

	const outerDb = _checkingDb;
	_checkingDb = db;
	if (bound == null && db.handedToCheck != null) db.handedToCheck.add(fileId);
	const bodyReads = new HashSet<string>();
	const outerSink = installBodyReadSink((modulePath: string): void => { bodyReads.add(modulePath); });
	const unit = bound != null ? bound : dbBindModule(db, filePath, program, imports, globals, startVersion);
	const checkerCtx = finishModuleCheck(unit);
	for (const message of unchecked) addError(checkerCtx, message, 1, 1);
	installBodyReadSink(outerSink);
	_checkingDb = outerDb;
	db.bound.delete(filePath);

	// If cancelled, discard frame without caching — partial result not reliable
	if (checkCancel(db.cancelCtx, startVersion)) {
		popFrame(db.depStack);
		db.checkInProgress.delete(filePath);
		forgetClientsOfDiscardedUnit(db, fileId);
		return checkerCtx;
	}

	checkerCtx.disambAfterCheck = copyDisambTable(checkerCtx.disambTable);
	db.contexts.set(checkCtxKey(fileId), checkerCtx);
	updateModuleExports(db.exportRegistry, filePath, collectExports(checkerCtx, filePath));
	if (db.graph != null && findModule(db.graph, filePath) != null) setRegisteredAt(db.moduleDeps, fileId, db.revision.value);
	db.trees.set(checkNodeKey(fileId), program);  // cache checked program (has resolvedSym/nodeType)
	for (const read of bodyReads) {
		const readId = getFileId(db.fileInput, read);
		if (readId >= 0 && readId != fileId) recordImplRead(db, readId);
	}
	const kept = db.handedToCheck == null;
	const iface = kept ? ifaceDigest(checkerCtx) : null;
	const checkChangedAt = outputChangedAt(db.outputs, db.cache, key, iface, interfaceDeps, db.revision.value);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, checkChangedAt, true);
	if (kept) storeImpl(db, fileId, implDigest(cachedProgram));
	db.checkInProgress.delete(filePath);
	return checkerCtx;
}

function recordImplRead(db: TransAmDb, readId: int32): void {
	const implKey = createQueryKey(TaQueryKind.Impl, readId);
	if (cacheGet(db.cache, implKey) == null) recordParseRead(db, readId);
	else recordDependency(db.depStack, implKey);
}

function recordParseRead(db: TransAmDb, readId: int32): void {
	recordDependency(db.depStack, createQueryKey(TaQueryKind.Parse, readId));
}

function storeImpl(db: TransAmDb, fileId: int32, impl: string): void {
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	const implKey = createQueryKey(TaQueryKind.Impl, fileId);
	pushFrame(db.depStack, implKey);
	recordDependency(db.depStack, checkKey);
	recordDurability(db.depStack, getFileDurability(db.fileInput, fileId));
	const changedAt = outputChangedAt(db.outputs, db.cache, implKey, impl, [checkKey], db.revision.value);
	executeQueryWith(db.cache, db.fileInput, db.depStack, implKey, db.revision.value, changedAt, true);
}

// A module in an import cycle with another leaves that one's digest out of its own, so two modules never chain each other's.
function importReaches(db: TransAmDb, fromId: int32, targetId: int32): boolean {
	const seen = new HashSet<int32>();
	const pending: int32[] = [fromId];
	while (pending.length > 0) {
		const id = pending.pop()!;
		if (id == targetId) return true;
		if (seen.has(id)) continue;
		seen.add(id);
		for (const next of getDirectImports(db.moduleDeps, id)) pending.push(next);
	}
	return false;
}

// Salsa's deep verify: a check that is not green yet rechecks the modules it depends on first, so each one's
// recomputed output hash is there for the early cutoff to compare. Only modules this db already checked are visited.
function recheckImports(db: TransAmDb, key: TaQueryKey): boolean {
	const entry = cacheGet(db.cache, key);
	if (entry == null) return false;
	const path = getFilePath(db.fileInput, key.fileId);
	db.verifying.add(path);
	for (const dep of entry.dependencies) {
		const kind = dep.queryKind;
		if (kind != TaQueryKind.TypeCheck && kind != TaQueryKind.Impl) continue;
		if (dep.fileId == key.fileId || cacheGet(db.cache, createQueryKey(TaQueryKind.TypeCheck, dep.fileId)) == null) continue;
		const depPath = getFilePath(db.fileInput, dep.fileId);
		if (db.verifying.has(depPath) || db.checkInProgress.has(depPath) || checkedElsewhere(db, depPath)) continue;
		dbTypeCheck(db, depPath);
	}
	db.verifying.delete(path);
	return true;
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

function copyDisambTable(table: HashMap<string, int32>): HashMap<string, int32> {
	const copy = new HashMap<string, int32>();
	for (const [name, count] of table) copy.set(name, count);
	return copy;
}

export function dbLower<T>(db: TransAmDb, filePath: string, lower: (checked: Node, ctx: CheckerContext, arg: T) => Node, arg: T): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const key = createQueryKey(TaQueryKind.Lower, fileId);
	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) return dbTree(db, lowerNodeKey(fileId));
	const ctx = dbTypeCheck(db, filePath);
	if (ctx == null) return null as unknown as Node;
	if (recheckImports(db, key) && tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) return dbTree(db, lowerNodeKey(fileId));
	const checked = dbTree(db, checkNodeKey(fileId));
	pushFrame(db.depStack, key);
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	recordDependency(db.depStack, checkKey);
	recordInputsOfBackdatedCheck(db, checkKey);
	recordDurability(db.depStack, getFileDurability(db.fileInput, fileId));
	const afterCheck = ctx.disambAfterCheck;
	if (afterCheck == null) throw new Error(`internal: ${filePath} is lowered from a context with no post-check disambiguation table`);
	const checkTable = ctx.disambTable;
	ctx.disambTable = copyDisambTable(afterCheck);
	const lowerReads = new HashSet<string>();
	const outerSink = installBodyReadSink((modulePath: string): void => { lowerReads.add(modulePath); });
	const lowered = lower(checked, ctx, arg);
	installBodyReadSink(outerSink);
	ctx.disambTable = checkTable;
	for (const read of lowerReads) {
		const readId = getFileId(db.fileInput, read);
		if (readId >= 0 && readId != fileId) recordImplRead(db, readId);
	}
	db.trees.set(lowerNodeKey(fileId), lowered);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, db.revision.value, true);
	return lowered;
}

function recordInputsOfBackdatedCheck(db: TransAmDb, checkKey: TaQueryKey): void {
	const checkEntry = cacheGet(db.cache, checkKey);
	if (checkEntry != null) for (const dep of checkEntry.dependencies) recordDependency(db.depStack, dep);
}

export function dbStoreLowered(db: TransAmDb, filePath: string, lowered: Node): void {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) throw new Error(`internal: no file id for lowered module ${filePath}`);
	db.trees.set(lowerNodeKey(fileId), lowered);
}

// Transform and analysis read the module's text and, through call summaries, the bodies of any module it reaches.
function recordSourceAndImplClosure(db: TransAmDb, fileId: int32): void {
	recordParseRead(db, fileId);
	const seen = new HashSet<int32>();
	const pending: int32[] = getDirectImports(db.moduleDeps, fileId);
	while (pending.length > 0) {
		const id = pending.pop()!;
		if (id == fileId || seen.has(id)) continue;
		seen.add(id);
		recordImplRead(db, id);
		for (const next of getDirectImports(db.moduleDeps, id)) pending.push(next);
	}
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
	if (dbParsed(db, filePath) == null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	// Fresh parse for transform — checker already mutated its own copy
	// (enum MemberExpr → Identifier), and transforms also mutate the AST.
	const analyzeSrc = getFileText(db.fileInput, fileId);
	const analyzeParse = parseSource(analyzeSrc);
	const program = analyzeParse.ok ? analyzeParse.value : null as unknown as Node;
	if (program == null) return null as unknown as Node;

	pushFrame(db.depStack, key);
	const ckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	recordDependency(db.depStack, ckKey);
	recordSourceAndImplClosure(db, fileId);

	const transformed = transformProgram(program, checkerCtx, false);
	const analyzed = analyzeProgram(transformed, checkerCtx, createWriteSummaries(db.routineDecls, []));
	db.trees.set(analyzeNodeKey(fileId), analyzed);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, db.revision.value, true);
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

	if (dbParsed(db, filePath) == null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	// Fresh parse — checker mutates AST, transforms also mutate
	const txSrc = getFileText(db.fileInput, fileId);
	const txParse = parseSource(txSrc);
	const program = txParse.ok ? txParse.value : null as unknown as Node;
	if (program == null) return null as unknown as Node;

	pushFrame(db.depStack, key);
	const tckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	recordDependency(db.depStack, tckKey);
	recordSourceAndImplClosure(db, fileId);

	const transformed = transformProgram(program, checkerCtx, false);
	db.trees.set(transformNodeKey(fileId), transformed);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, db.revision.value, true);
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
		+ ` macros=${macroCompileCount()}`
		+ ` recomputed:${recomputed}`;
}

// ===== Re-exports =====

export {
	TaQueryKind, TaQueryState, TaDurability, TaRevision,
	TaQueryKey, createQueryKey, queryKeysEqual,
	createRevision, incrementRevision
} from "./revision";
export {
	TaCacheEntry, createCacheEntry,
	TaDependencyStack, createDependencyStack
} from "./query";
export { TaCacheStore, createCacheStore, cacheGet, cachePut } from "./cache";
export {
	TaFileInputStore, createFileInputStore,
	setFileText, getFileText, getFileChangedAt, getFileId, getFilePath, hasFile,
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

// ===== Early Cutoff Integration Tests =====

function lowerMinting(db: TransAmDb, path: string, names: string[]): int32[] {
	const minted: int32[] = [];
	cacheRemove(db.cache, createQueryKey(TaQueryKind.Lower, getFileId(db.fileInput, path)));
	dbLower(db, path, (checked: Node, ctx: CheckerContext, arg: string[]): Node => {
		for (const name of arg) minted.push(nextDisamb(ctx, "/t.ms", name));
		return checked;
	}, names);
	return minted;
}

test "lowering a checked module twice mints the same disamb for a clone" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/t.ms", "function f(a: int32): int32 { return a; }");
	const first = lowerMinting(db, "/t.ms", ["f$lent", "f$lent"]);
	const second = lowerMinting(db, "/t.ms", ["f$lent", "f$lent"]);
	assert first.join(",") == "0,1";
	assert second.join(",") == first.join(",");
}

test "a relowering continues a name the check declared from the check's count, not the last lowering's" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/t.ms", "function f(a: int32): int32 { return a; } function f(a: string): string { return a; }");
	const first = lowerMinting(db, "/t.ms", ["f", "g$lent"]);
	const second = lowerMinting(db, "/t.ms", ["f", "g$lent"]);
	assert first.join(",") == "2,0";
	assert second.join(",") == first.join(",");
	assert dbTypeCheck(db, "/t.ms").disambTable.get("/t.ms\tf") == 2;
}

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

	// TypeCheck should NOT verify green (the parse changed)
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	assert !tryMarkGreen(db.cache, db.fileInput, checkKey, db.revision.value);
}

function changedAtOf(db: TransAmDb, kind: TaQueryKind, path: string): int32 {
	return cacheGet(db.cache, createQueryKey(kind, getFileId(db.fileInput, path))).changedAt;
}

test "a preprocess and its parse change at the revision their text last changed, through edit and undo" {
	const db = createTransAmDb(100);
	const path = "/revisions/value.ms";
	const texts = ["const x = 1;", "const x = 2;", "const x = 1;"];
	for (let i = 0; i < texts.length; i += 1) {
		dbSetFileText(db, path, texts[i]);
		dbParse(db, path);
		assert db.revision.value == i + 1;
		assert changedAtOf(db, TaQueryKind.Preprocess, path) == i + 1;
		assert changedAtOf(db, TaQueryKind.Parse, path) == i + 1;
	}
}

test "text restored before any query keeps the change revisions of its preprocess and parse" {
	const db = createTransAmDb(100);
	const path = "/restore/value.ms";
	const first = "export const value: int32 = 1;";
	dbSetFileText(db, path, first);
	const ctx = dbTypeCheck(db, path);
	dbSetFileText(db, path, "export const value: int32 = 2;");
	dbSetFileText(db, path, first);
	dbParse(db, path);
	assert changedAtOf(db, TaQueryKind.Preprocess, path) == 1;
	assert changedAtOf(db, TaQueryKind.Parse, path) == 1;
	assert cacheGet(db.cache, createQueryKey(TaQueryKind.Parse, getFileId(db.fileInput, path))).computedAt == 3;
	assert dbTypeCheck(db, path) == ctx;
}

test "dbTypeCheck records its parse dependency" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	dbTypeCheck(db, "test.ms");

	const entry = cacheGet(db.cache, createQueryKey(TaQueryKind.TypeCheck, 0));
	assert entry != null;
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	let foundParseDep = false;
	for (const dep of entry.dependencies) {
		if (queryKeysEqual(dep, parseKey)) foundParseDep = true;
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

test "a syntax error parse is still stored" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "bad.ms", "const = ;");
	dbParse(db, "bad.ms");

	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = cacheGet(db.cache, parseKey);
	assert entry != null;
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

test "a line shift in a dependency moves the declaration its importer resolves without rechecking the importer" {
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
				// An importer checked before its dependency has no digest to read at first and reads the dependency's text once.
				const importerCount = order[0] == 0 || i == 0 ? 1 : 2;
				assert counts[j].n == (j == 0 ? i + 1 : importerCount), `${j} ${i}: ${counts[j].n}`;
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

function inlineLowering(checked: Node, ctx: CheckerContext, count: LowerCount): Node {
	count.n += 1;
	return lowerIterInline(cloneNodeKeepSem(checked), createTransformContextWithChecker(ctx));
}

test "a module's lowering reruns after a generator body it expanded changes in another module" {
	const db = createTransAmDb(100);
	const gen = "export function* g(): Iterator<int32> { yield 1; }";
	dbSetFileText(db, "/inl/a.ms", gen);
	dbSetFileText(db, "/inl/b.ms", 'import { g } from "./a";\nlet s: int32 = 0;\nfor (const x of g()) { s += x; }');
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/inl/b.ms"), getFileId(db.fileInput, "/inl/a.ms"));
	const a: LowerCount = { n: 0 };
	const b: LowerCount = { n: 0 };
	dbLower(db, "/inl/a.ms", inlineLowering, a);
	const expanded = dbLower(db, "/inl/b.ms", inlineLowering, b);
	assert (expanded.data as ProgramData).programStmts[2].kind == NodeKind.BlockStmt;
	dbSetFileText(db, "/inl/a.ms", gen.replace("yield 1", "yield 2"));
	dbParse(db, "/inl/a.ms");
	dbLower(db, "/inl/a.ms", inlineLowering, a);
	dbLower(db, "/inl/b.ms", inlineLowering, b);
	assert a.n == 2;
	assert b.n == 2;
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

const MACRO_TWICE = 'import { Node } from "std/meta";\nexport macro twice(n: Node): Node {\n\treturn quote { (${n} * 2) };\n}\n';
const MACRO_USER = 'import { twice } from "./mac";\nexport const x: int32 = twice(2);\n';

function macroDb(macroText: string, userText: string): TransAmDb {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/m/mac.ms", macroText);
	dbSetFileText(db, "/m/use.ms", userText);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/m/use.ms"), getFileId(db.fileInput, "/m/mac.ms"));
	return db;
}

function checkMessages(db: TransAmDb, path: string): string {
	const ctx = dbTypeCheck(db, path);
	return ctx.errors.map((e: CheckerError): string => e.message).join("\n");
}

test "editing a call site reuses the macro build" {
	const db = macroDb(MACRO_TWICE, MACRO_USER);
	assert checkMessages(db, "/m/use.ms") == "";
	const built = macroCompileCount();
	dbSetFileText(db, "/m/use.ms", MACRO_USER.replace("twice(2)", "twice(3)"));
	assert checkMessages(db, "/m/use.ms") == "";
	dbSetFileText(db, "/m/use.ms", MACRO_USER + "export const y: int32 = twice(4);\n");
	assert checkMessages(db, "/m/use.ms") == "";
	assert macroCompileCount() == built, `${macroCompileCount() - built} recompiles`;
}

const GENERIC_LIB = "export function twice<T>(x: T): T { const y = x; return y; }\nexport class Box<T> { v: T; constructor(v: T) { this.v = v; } }\n";
const GENERIC_USE = 'import { twice, Box } from "./lib";\nconst a: int32 = twice(1);\nconst b = new Box<int32>(2);\nconst c: string = twice("s");\n';

function instanceBodiesKept(libPath: string, usePath: string, lib: string, use: string): string {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, libPath, lib);
	dbSetFileText(db, usePath, use);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, usePath), getFileId(db.fileInput, libPath));
	const kept = (): int32 => {
		const libCtx = lookupModuleCtx(libPath)!;
		return libCtx.table.allScopes.length + libCtx.symRecords.length;
	};
	for (let k = 0; k < 2; k += 1) {
		dbSetFileText(db, usePath, use + `const n${k} = ${k};\n`);
		const errors = dbTypeCheck(db, usePath).errors;
		if (errors.length != 0) return errors[0].message;
	}
	const afterTwo = kept();
	for (let k = 2; k < 8; k += 1) {
		dbSetFileText(db, usePath, use + `const n${k} = ${k};\n`);
		const errors = dbTypeCheck(db, usePath).errors;
		if (errors.length != 0) return errors[0].message;
	}
	const grown = kept() - afterTwo;
	return grown == 0 ? "" : `${grown} scopes and records stayed`;
}

test "rechecking a module leaves no instance body on the module that defines its generics" {
	const left = instanceBodiesKept("/g/lib.ms", "/g/use.ms", GENERIC_LIB, GENERIC_USE);
	assert left == "", left;
}

test "rechecking a module leaves no instance body on the module whose class constructor it instantiates" {
	const use = 'import { Box } from "./lib2";\nconst b = new Box<int32>(2);\nconst c = new Box<string>("s");\n';
	const left = instanceBodiesKept("/g/lib2.ms", "/g/use2.ms", GENERIC_LIB, use);
	assert left == "", left;
}

function capturedFlowKept(libPath: string, usePath: string, lib: string, use: string): string {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, libPath, lib);
	dbSetFileText(db, usePath, use);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, usePath), getFileId(db.fileInput, libPath));
	const edit = (k: int32): string => {
		dbSetFileText(db, usePath, use + `const n${k} = ${k};\n`);
		const errors = dbTypeCheck(db, usePath).errors;
		return errors.length == 0 ? "" : errors[0].message;
	};
	for (let k = 0; k < 2; k += 1) { if (edit(k) != "") return edit(k); }
	const afterTwo = capturedAssignmentCount();
	if (afterTwo == 0) return "no captured assignment was recorded, the pin observes nothing";
	for (let k = 2; k < 8; k += 1) { if (edit(k) != "") return edit(k); }
	const grown = capturedAssignmentCount() - afterTwo;
	return grown == 0 ? "" : `${grown} captured-assignment entries stayed`;
}

test "rechecking a module keeps no captured-assignment entry of an instance body it replaced" {
	const lib = "export function twice<T>(x: T): T { let y = x; const f = (): T => y; return f(); }\n";
	const use = 'import { twice } from "./lib3";\nconst a: int32 = twice(1);\nconst c: string = twice("s");\n';
	const left = capturedFlowKept("/g/lib3.ms", "/g/use3.ms", lib, use);
	assert left == "", left;
}

test "rechecking a module keeps no captured-assignment entry of a class method body it replaced" {
	const lib = "export class Box<T> { v: T; constructor(v: T) { this.v = v; } get(): T { let y = this.v; const f = (): T => y; return f(); } }\n";
	const use = 'import { Box } from "./lib4";\nconst a: int32 = new Box<int32>(2).get();\nconst c: string = new Box<string>("s").get();\n';
	const left = capturedFlowKept("/g/lib4.ms", "/g/use4.ms", lib, use);
	assert left == "", left;
}

test "editing the macro body rebuilds it and the new expansion reaches the importer" {
	const db = macroDb(MACRO_TWICE, MACRO_USER);
	assert checkMessages(db, "/m/use.ms") == "";
	const built = macroCompileCount();
	dbSetFileText(db, "/m/mac.ms", MACRO_TWICE.replace("(${n} * 2)", "\"two\""));
	assert checkMessages(db, "/m/use.ms") != "";
	assert macroCompileCount() == built + 1;
	dbSetFileText(db, "/m/mac.ms", MACRO_TWICE);
	assert checkMessages(db, "/m/use.ms") == "";
}

test "a macro that fails to compile is reported on every check that reaches it" {
	const db = macroDb(MACRO_TWICE.replace("quote { (${n} * 2) }", "missingHelper(${n})"), MACRO_USER);
	const first = checkMessages(db, "/m/use.ms");
	assert first != "";
	dbSetFileText(db, "/m/use.ms", MACRO_USER.replace("twice(2)", "twice(3)"));
	assert checkMessages(db, "/m/use.ms") != "";
	dbSetFileText(db, "/m/use.ms", MACRO_USER.replace("twice(2)", "twice(4)"));
	assert checkMessages(db, "/m/use.ms") != "";
}

test "editing a helper module the macro imports rebuilds the macro" {
	const helper = (text: string): string => `export function pick(): string {\n\treturn ${text};\n}\n`;
	const mac = 'import { Node } from "std/meta";\nimport { pick } from "./h";\nexport macro twice(n: Node): Node {\n\tconst s = pick();\n\treturn quote { (${n} * 2) };\n}\n';
	const db = macroDb(mac, MACRO_USER);
	dbSetFileText(db, "/m/h.ms", helper('"a"'));
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/m/mac.ms"), getFileId(db.fileInput, "/m/h.ms"));
	assert checkMessages(db, "/m/use.ms") == "";
	const built = macroCompileCount();
	dbSetFileText(db, "/m/h.ms", helper('"b"'));
	assert checkMessages(db, "/m/use.ms") == "";
	assert macroCompileCount() == built + 1, `${macroCompileCount() - built} recompiles`;
	dbSetFileText(db, "/m/use.ms", MACRO_USER.replace("twice(2)", "twice(3)"));
	assert checkMessages(db, "/m/use.ms") == "";
	assert macroCompileCount() == built + 1;
}

test "a macro body is preprocessed once per declaration, not once per call site or check" {
	const db = macroDb(MACRO_TWICE, MACRO_USER + "export const y: int32 = twice(4);\n");
	const before = macroPreprocessCount();
	assert checkMessages(db, "/m/use.ms") == "";
	assert macroPreprocessCount() == before + 1, `${macroPreprocessCount() - before} preprocesses for two call sites`;
	dbSetFileText(db, "/m/use.ms", MACRO_USER.replace("twice(2)", "twice(3)"));
	assert checkMessages(db, "/m/use.ms") == "";
	assert macroPreprocessCount() == before + 1;
	dbSetFileText(db, "/m/mac.ms", MACRO_TWICE.replace("* 2", "* 3"));
	assert checkMessages(db, "/m/use.ms") == "";
	assert macroPreprocessCount() == before + 2;
}

test "rechecking a module that passes typed arguments to a macro keeps no handle table entry" {
	const user = MACRO_USER.replace("twice(2)", "twice(a)").replace("export const x", "const a: int32 = 2;\nexport const x");
	const db = macroDb(MACRO_TWICE, user);
	const edit = (k: int32): string => {
		dbSetFileText(db, "/m/use.ms", user + `const n${k} = ${k};\n`);
		return checkMessages(db, "/m/use.ms");
	};
	for (let k = 0; k < 2; k += 1) assert edit(k) == "";
	const afterTwo = boundHandleCount();
	for (let k = 2; k < 8; k += 1) assert edit(k) == "";
	assert boundHandleCount() == afterTwo, `${boundHandleCount() - afterTwo} handles stayed over 6 rechecks`;
}

const HANDLE_LIB = 'import { Node, NodeKind, bindSym, getImpl } from "std/meta";\n'
	+ 'export function helper(x: int32): int32 { return x + 100; }\n'
	+ 'export function other(): string { return "o"; }\n'
	+ 'export macro wrapped(n: Node): Node {\n'
	+ '\treturn { kind: NodeKind.CallExpr, line: n.line, column: n.column, callee: bindSym("helper"), arguments: [n] };\n'
	+ '}\n'
	+ 'export macro hasImpl(fn: Node): Node {\n'
	+ '\tconst decl = getImpl(bindSym(fn.name));\n'
	+ '\treturn { kind: NodeKind.NumberLiteral, line: fn.line, column: fn.column, value: decl === null ? 0 : 1, isFloat: false };\n'
	+ '}\n';
const HANDLE_USE = 'import { wrapped, hasImpl, other } from "./hlib";\n'
	+ 'const found = hasImpl(later);\n'
	+ 'function later(): int32 { return wrapped(1); }\n'
	+ 'const second: int32 = wrapped(other().length + other().length + other().length + other().length + other().length + other().length);\n';

test "a macro first built inside another macro's run keeps the symbol its body baked" {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/h/hlib.ms", HANDLE_LIB);
	dbSetFileText(db, "/h/use.ms", HANDLE_USE);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/h/use.ms"), getFileId(db.fileInput, "/h/hlib.ms"));
	for (let k = 0; k < 3; k += 1) {
		dbSetFileText(db, "/h/use.ms", HANDLE_USE + `const n${k} = ${k};\n`);
		const messages = checkMessages(db, "/h/use.ms");
		assert messages == "", `check ${k}: ${messages}`;
	}
}

function typedNodeCount(node: Node): int32 {
	const counts: int32[] = [node.nodeType != null ? 1 : 0];
	forEachChild(node, (child: Node): void => { counts[0] += typedNodeCount(child); });
	return counts[0];
}

const DEP_LIB = "export function twice(n: int32): int32 { return n * 2; }\n";

function oneShotDb(kept: boolean): TransAmDb {
	const db = createTransAmDb(100, kept);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/o/dep.ms", DEP_LIB);
	return db;
}

test "a db that is not kept checks its parse tree without cloning it" {
	const db = oneShotDb(false);
	const parsed = dbParse(db, "/o/dep.ms");
	assert typedNodeCount(parsed) == 0;
	assert checkMessages(db, "/o/dep.ms") == "";
	assert dbGetCheckedProgram(db, "/o/dep.ms") == parsed;
	assert typedNodeCount(parsed) > 0;
}

test "a kept db clones its parse tree and leaves it clean" {
	const db = oneShotDb(true);
	const parsed = dbParse(db, "/o/dep.ms");
	assert checkMessages(db, "/o/dep.ms") == "";
	assert dbGetCheckedProgram(db, "/o/dep.ms") != parsed;
	assert typedNodeCount(parsed) == 0;
	assert dbParse(db, "/o/dep.ms") == parsed;
}

test "a parse read after the check took the tree fails loud" {
	const db = oneShotDb(false);
	dbTypeCheck(db, "/o/dep.ms");
	let message = "";
	try { dbParse(db, "/o/dep.ms"); } catch (e) { message = (e as Error).message; }
	assert message == "internal: the parse tree of /o/dep.ms was handed to its check";
}

function graphMessages(kept: boolean): string {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/g/dep.ms", entrySource: DEP_LIB });
	entries.push({ entryPath: "/g/use.ms", entrySource: 'import { twice } from "./dep";\nconst r: string = twice(2);\n' });
	const graph = loadModuleGraph("/g/use.ms", createMapProvider(entries));
	const db = createTransAmDb(100, kept);
	dbBindGraph(db, graph);
	const messages: string[] = [];
	for (const path of graph.loadOrder) messages.push(checkMessages(db, path));
	return messages.join("|");
}

test "a dependent checked after its dependency gives the same diagnostics whether or not the db is kept" {
	const once = graphMessages(false);
	assert once.indexOf("string") >= 0;
	assert once == graphMessages(true);
}

// ===== Change-revision pins =====

import { taHashString } from "./hash";
import { getLastChange } from "./fileInput";

test "different source texts with the same hash refresh preprocessing" {
	for (const pair of [
		["export const Az = 1;", "export const BY = 1;"],
		["export const value = \"Az\";", "export const value = \"BY\";"],
	]) {
		assert pair[0] != pair[1];
		assert taHashString(pair[0]) == taHashString(pair[1]);
		const db = createTransAmDb(100);
		dbSetFileText(db, "/collision/source.ms", pair[0]);
		assert dbPreprocess(db, "/collision/source.ms") == pair[0];
		assert dbSetFileText(db, "/collision/source.ms", pair[1]);
		assert dbPreprocess(db, "/collision/source.ms") == pair[1];
	}
}

test "renaming an export to a same-hash name refreshes its checked symbols" {
	for (const pair of [["Az", "BY"], ["Cx", "DW"]]) {
		const db = createTransAmDb(100);
		const path = "/collision/export.ms";
		dbSetFileText(db, path, `export const ${pair[0]} = 1;`);
		assert lookupLocal(dbTypeCheck(db, path).table, pair[0]) != null;
		dbSetFileText(db, path, `export const ${pair[1]} = 1;`);
		const ctx = dbTypeCheck(db, path);
		assert lookupLocal(ctx.table, pair[1]) != null;
		assert lookupLocal(ctx.table, pair[0]) == null;
	}
}

test "a same-hash rename and its undo return the right names at every step" {
	for (const pair of [["Az", "BY"], ["Cx", "DW"]]) {
		const db = createTransAmDb(100);
		const path = "/collision/undo.ms";
		const names = [pair[0], pair[1], pair[0]];
		for (let i = 0; i < names.length; i += 1) {
			dbSetFileText(db, path, `export const ${names[i]} = 1;`);
			assert dbPreprocess(db, path) == `export const ${names[i]} = 1;`;
			const ctx = dbTypeCheck(db, path);
			assert lookupLocal(ctx.table, names[i]) != null;
			assert lookupLocal(ctx.table, names[i] == pair[0] ? pair[1] : pair[0]) == null;
		}
	}
}

test "a same-hash rename undone before any query returns the original names" {
	for (const pair of [["Az", "BY"], ["Cx", "DW"]]) {
		const db = createTransAmDb(100);
		const path = "/collision/restore.ms";
		dbSetFileText(db, path, `export const ${pair[0]} = 1;`);
		dbTypeCheck(db, path);
		dbSetFileText(db, path, `export const ${pair[1]} = 1;`);
		dbSetFileText(db, path, `export const ${pair[0]} = 1;`);
		const ctx = dbTypeCheck(db, path);
		assert lookupLocal(ctx.table, pair[0]) != null;
		assert lookupLocal(ctx.table, pair[1]) == null;
	}
}

test "a same-hash edit of an import this db only binds re-checks its reader" {
	const root = "/boundHash";
	const texts = ["export const Az: int32 = 1;", "export const BY: int32 = 1;"];
	assert taHashString(texts[0]) == taHashString(texts[1]);
	const db = createTransAmDb(100);
	dbSetFileText(db, `${root}/dep.ms`, texts[0]);
	dbSetFileText(db, `${root}/user.ms`, 'import { Az } from "./dep";\nexport const seen = Az;');
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, `${root}/user.ms`), getFileId(db.fileInput, `${root}/dep.ms`));
	assert dbTypeCheck(db, `${root}/user.ms`).errors.length == 0;
	const bound = db.cache.bound;
	dbSetFileText(db, `${root}/dep.ms`, texts[1]);
	assert dbTypeCheck(db, `${root}/user.ms`).errors.length > 0;
	assert db.cache.bound - bound == 2, `${db.cache.bound - bound}`;
}

test "an edited bind-only import is not reused before its parse reruns" {
	const root = "/boundStale";
	const db = createTransAmDb(100);
	dbSetFileText(db, `${root}/dep.ms`, "export const Az: int32 = 1;");
	dbSetFileText(db, `${root}/user.ms`, 'import { Az } from "./dep";\nexport const seen = Az;');
	const depId = getFileId(db.fileInput, `${root}/dep.ms`);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, `${root}/user.ms`), depId);
	assert dbTypeCheck(db, `${root}/user.ms`).errors.length == 0;
	assert boundInputsUnchanged(db, `${root}/dep.ms`);
	dbSetFileText(db, `${root}/dep.ms`, "export const BY: int32 = 1;");
	assert !boundInputsUnchanged(db, `${root}/dep.ms`);
}

test "stage keys of different files never meet" {
	const keys = new HashSet<int32>();
	for (let fileId: int32 = 0; fileId <= 6000; fileId += 1) {
		for (const key of [parseNodeKey(fileId), checkCtxKey(fileId), checkNodeKey(fileId), transformNodeKey(fileId), analyzeNodeKey(fileId), lowerNodeKey(fileId), exportNodeKey(fileId)]) keys.add(key);
	}
	assert keys.size == 7 * 6001;
}

test "a stage key past the int32 range is refused" {
	const last: int32 = (2147483647 - 6) / STAGE_COUNT;
	assert exportNodeKey(last) == last * STAGE_COUNT + 6;
	let refused = false;
	try { exportNodeKey(last + 1); } catch (e) { refused = true; }
	assert refused;
}

test "at the revision maximum an edit is refused before anything changes" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/ceiling/a.ms", "export const a = 1;");
	const fileId = getFileId(db.fileInput, "/ceiling/a.ms");
	db.revision.value = TA_REVISION_MAX;
	const changedAt = getFileChangedAt(db.fileInput, fileId);
	const marker = getLastChange(db.fileInput, TaDurability.Low);
	assert !dbSetFileText(db, "/ceiling/a.ms", "export const a = 1;");
	let refused = false;
	try { dbSetFileText(db, "/ceiling/a.ms", "export const a = 2;"); } catch (e) { refused = true; }
	assert refused;
	assert getFileText(db.fileInput, fileId) == "export const a = 1;";
	assert getFileChangedAt(db.fileInput, fileId) == changedAt;
	assert getLastChange(db.fileInput, TaDurability.Low) == marker;
	assert db.revision.value == TA_REVISION_MAX;
}

test "a file under the std path is written at high durability" {
	const db = createTransAmDb(100);
	dbSetStdPath(db, "/pin/std");
	dbSetFileText(db, "/pin/std/dep.ms", "export const shared: int32 = 1;");
	dbSetFileText(db, "/pin/user.ms", "export const user = 1;");
	assert getFileDurability(db.fileInput, getFileId(db.fileInput, "/pin/std/dep.ms")) == TaDurability.High;
	assert getFileDurability(db.fileInput, getFileId(db.fileInput, "/pin/user.ms")) == TaDurability.Low;
	assert getLastChange(db.fileInput, TaDurability.High) == 0;
	dbSetFileText(db, "/pin/std/dep.ms", "export const shared: int32 = 2;");
	assert getLastChange(db.fileInput, TaDurability.High) == db.revision.value;
}

test "an edit to a high-durability module reaches the check of its importer" {
	const db = createTransAmDb(100);
	const dep = "/highDep/dep.ms";
	const user = "/highDep/user.ms";
	dbSetFileText(db, dep, "export const shared: int32 = 1;");
	dbSetFileText(db, user, 'import { shared } from "./dep";\nexport const seen = shared;');
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, user), getFileId(db.fileInput, dep));
	setFileDurability(db.fileInput, getFileId(db.fileInput, dep), TaDurability.High, db.revision.value);
	const first = dbTypeCheck(db, user);
	assert localTypeName(first, "seen") == "int32";
	dbSetFileText(db, "/highDep/other.ms", "export const other = 1;");
	assert dbTypeCheck(db, user) == first;
	dbSetFileText(db, dep, 'export const shared: string = "s";');
	assert localTypeName(dbTypeCheck(db, user), "seen") == "string";
	dbSetFileText(db, dep, "export const shared: int32 = 1;");
	assert localTypeName(dbTypeCheck(db, user), "seen") == "int32";
}

const GENERATED_MAC = 'import { Node, NodeKind, DeclKind } from "std/meta";\nexport macro pair(): Node {\n\treturn { kind: NodeKind.SpliceMany, line: 0, column: 0, spliceNodes: [{ kind: NodeKind.ExportDecl, line: 0, column: 0, exportedDecl: { kind: NodeKind.VariableDecl, line: 0, column: 0, declName: "a", declType: "int32", initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 1, isFloat: false }, declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 } } }] };\n}\n';
const GENERATED_USE = 'import { pair } from "./mac";\npair();\n';

function exportedSym(db: TransAmDb, path: string, name: string): Symbol {
	const entry = findModuleExports(db.exportRegistry, path);
	if (entry == null) throw new Error(`${path} has no registered exports`);
	for (const info of entry.symbols) {
		if (info.name == name) return info.sym;
	}
	throw new Error(`${path} exports no '${name}'`);
}

test "a declaration a macro generated keeps its Symbol when its module is edited" {
	const db = macroDb(GENERATED_MAC, GENERATED_USE);
	assert checkMessages(db, "/m/use.ms") == "";
	const held = exportedSym(db, "/m/use.ms", "a");
	dbSetFileText(db, "/m/use.ms", "const n: int32 = 1;\n" + GENERATED_USE);
	assert checkMessages(db, "/m/use.ms") == "";
	assert exportedSym(db, "/m/use.ms", "a") == held;
}

const RESIZE_HEAD = 'struct S { n: int32; }\nfunction grow(a: S[]): void { }\nfunction run(): int32 { let xs: S[] = [{ n: 1 }]; const sp: Span<S> = xs; grow(xs); return sp[0].n; }\nrun();\n';

test "an edit that makes a callee resize is seen by the borrow check of its adopted Symbol" {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/r/a.ms", RESIZE_HEAD);
	assert checkMessages(db, "/r/a.ms") == "";
	dbSetFileText(db, "/r/a.ms", RESIZE_HEAD.replace("grow(a: S[]): void { }", "grow(a: S[]): void { a.push({ n: 2 }); }"));
	assert checkMessages(db, "/r/a.ms").indexOf("cannot borrow") >= 0;
}

const HOOK_BOX = 'export class Box<T> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n\tonDestroy(): void { }\n}\n';
const HOOK_USE = 'import { Box } from "./box";\nexport const held: Box<int32> = new Box<int32>(1);\n';

test "a generic class's instance hook is forgotten when its module is edited to drop the hook" {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/h/box.ms", HOOK_BOX);
	dbSetFileText(db, "/h/use.ms", HOOK_USE);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/h/use.ms"), getFileId(db.fileInput, "/h/box.ms"));
	assert checkMessages(db, "/h/box.ms") == "";
	assert checkMessages(db, "/h/use.ms") == "";
	const op = lifecycleHookOp("onDestroy");
	assert lookupInstanceHook(exportedSym(db, "/h/use.ms", "held").symbolType, op) != null;
	dbSetFileText(db, "/h/box.ms", HOOK_BOX.replace("\tonDestroy(): void { }\n", ""));
	assert checkMessages(db, "/h/box.ms") == "";
	assert checkMessages(db, "/h/use.ms") == "";
	assert lookupInstanceHook(exportedSym(db, "/h/use.ms", "held").symbolType, op) == null;
}

test "a method removed from a class is not an overridden method of its subclass in another module" {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	const base = "export class C {\n\tm(): void { }\n}\n";
	dbSetFileText(db, "/d/base.ms", base);
	dbSetFileText(db, "/d/sub.ms", 'import { C } from "./base";\nexport class D extends C {\n\tm<T>(): void { }\n}\n');
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/d/sub.ms"), getFileId(db.fileInput, "/d/base.ms"));
	assert checkMessages(db, "/d/base.ms") == "";
	assert checkMessages(db, "/d/sub.ms").indexOf("overrides") >= 0;
	dbSetFileText(db, "/d/base.ms", "export class C {\n}\n");
	assert checkMessages(db, "/d/base.ms") == "";
	assert checkMessages(db, "/d/sub.ms") == "";
}

function cancelledBoundProject(root: string): TransAmDb {
	const db = createTransAmDb(100);
	dbSetFileText(db, `${root}/shapes.ms`, "export class Box {\n\tv: int32;\n\tconstructor(v: int32) {\n\t\tthis.v = v;\n\t}\n}\nexport class Holder<T> {\n\titem: T;\n\tconstructor(item: T) {\n\t\tthis.item = item;\n\t}\n}\n");
	dbSetFileText(db, `${root}/makers.ms`, 'import { Box, Holder } from "./shapes";\nexport function mkBox(): Box {\n\treturn new Box(4);\n}\nexport function mkHolder(): Holder<Box> {\n\treturn new Holder<Box>(new Box(5));\n}\n');
	dbSetFileText(db, `${root}/use.ms`, 'import { Box, Holder } from "./shapes";\nimport { mkBox, mkHolder } from "./makers";\nconst b: Box = mkBox();\nconst h: Holder<Box> = mkHolder();\n');
	const shapes = getFileId(db.fileInput, `${root}/shapes.ms`);
	const makers = getFileId(db.fileInput, `${root}/makers.ms`);
	const use = getFileId(db.fileInput, `${root}/use.ms`);
	recordModuleImport(db.moduleDeps, makers, shapes);
	recordModuleImport(db.moduleDeps, use, shapes);
	recordModuleImport(db.moduleDeps, use, makers);
	return db;
}

function cancelledFirstCheck(db: TransAmDb, path: string): void {
	db.cancelCtx.inputPending = () => true;
	dbTypeCheck(db, path);
	db.cancelCtx.inputPending = null;
	resetCancel(db.cancelCtx);
}

function importerErrorsAfterEdit(db: TransAmDb, root: string): string[] {
	const use = `${root}/use.ms`;
	dbSetFileText(db, use, getFileText(db.fileInput, getFileId(db.fileInput, use)) + "// edited\n");
	const messages: string[] = [];
	for (const e of dbTypeCheck(db, use).errors) messages.push(e.message);
	return messages;
}

test "a cancelled first check of a bound-only module keeps the class its importer names" {
	const root = "/cancelBoundShapes";
	const db = cancelledBoundProject(root);
	assert dbTypeCheck(db, `${root}/use.ms`).errors.length == 0;
	cancelledFirstCheck(db, `${root}/shapes.ms`);
	assert dbTypeCheck(db, `${root}/shapes.ms`).errors.length == 0;
	const messages = importerErrorsAfterEdit(db, root);
	assert messages.length == 0, messages.join("; ");
}

test "a cancelled first check of a bound-only importing module keeps the class its importer names" {
	const root = "/cancelBoundMakers";
	const db = cancelledBoundProject(root);
	assert dbTypeCheck(db, `${root}/use.ms`).errors.length == 0;
	cancelledFirstCheck(db, `${root}/makers.ms`);
	assert dbTypeCheck(db, `${root}/makers.ms`).errors.length == 0;
	const messages = importerErrorsAfterEdit(db, root);
	assert messages.length == 0, messages.join("; ");
}
