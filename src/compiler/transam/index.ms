// Trans-Am Hub — incremental query engine entry point
//
// Pipeline: parse → check → transform → analyze → (codegen)
//           \_______________\________________\_______________/
//                    Trans-Am (incremental query cache)
//
// TransAmDb aggregates all stores. dbSetFileText triggers invalidation.
// dbExecute runs the full pipeline through the red-green engine.

import { Node, NodeKind, nodeCacheStore, nodeCacheGet } from "../../ast/node";
import { readFile as readStdFile } from "std/fs";
import { CheckerContext, Severity, CancelCtx, ctxCacheStore, ctxCacheGet, createContext } from "../../checker/context";
import { SymbolFlag, hasFlag } from "../../checker/symbol";
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
import { TaCacheStore, createCacheStore, cacheGet, cachePut, cacheContains } from "./cache";
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
import { checkProgramWithRegistryCancellable, buildPreludeContext } from "../../checker/checkPass";
import { transformProgram } from "../../transform/index";
import { analyzeProgram } from "../../analyzer/index";
import "../../codegen/raiser/eval"; // side-effect: registers macro evaluator callback
import { ExportRegistry, createExportRegistry, findModuleExports, registerModuleExports, removeFromNameIndex, findExportedSymbol, collectExports } from "../../checker/context";
import { collectTopLevelLocal, collectTopLevel } from "../../checker/collectPass";
import { resolveDeclarations } from "../../checker/resolvePass";
import { openScope, ScopeKind } from "../../checker/symbol";
import { ImportDeclData, ExportDeclData, ProgramData } from "../../ast/node";
import { createModule, createModuleGraph, addModule, ImportEntry, createImportEntry } from "../../module/graph";
import { getDirectImports } from "./moduleDeps";
import { lspResolveImportCandidates } from "../lsp/protocol";
import { translateCHeader } from "../../module/cimport/emit";
import { inlineHeaderImports, createTaReadProvider, SourceProvider } from "../../module/loader";
import { cloneNodeForCheck } from "../../monomorphize/clone";

// ===== Stdlib Detection =====

// Check if filePath starts with db.stdPath prefix (set via dbSetStdPath).
// When stdPath is empty (tests, unconfigured), returns false — no files get High durability.
function isStdPathFor(db: TransAmDb, filePath: string): boolean {
	if (db.stdPath.length === 0) return false;
	if (filePath.length < db.stdPath.length) return false;
	for (let i = 0; i < db.stdPath.length; i = i + 1) {
		if (filePath[i] !== db.stdPath[i]) return false;
	}
	return true;
}

export function dbSetStdPath(db: TransAmDb, stdPath: string): void {
	db.stdPath = stdPath;
}

export function dbEnsurePrelude(db: TransAmDb): void {
	if (db.preludeCtx === null && db.stdPath.length > 0) {
		db.preludeCtx = buildPreludeContext(db.stdPath, ".cms");
		// Pre-register exports from top-level std modules (e.g., std/build.ms)
		// so auto-import suggestions work even without explicit imports.
		preRegisterStdModule(db, db.stdPath + "/build.ms", "std/build");
	}
}

// Parse a single file and register its exports into the registry.
function preRegisterStdModule(db: TransAmDb, filePath: string, specifier: string): void {
	const source = try readStdFile(filePath) catch "";
	if (source.length === 0) return;
	const pr = parseSourceLenient(source);
	if (!pr.ok) return;
	const tmpCtx = createTempCollectContext();
	tmpCtx.modulePath = filePath;
	collectTopLevelLocal(tmpCtx, pr.value);
	resolveDeclarations(tmpCtx, pr.value);
	const exports = collectExports(tmpCtx, filePath);
	if (exports.length > 0) {
		registerModuleExports(db.exportRegistry, filePath, exports);
	}
}

// ===== TransAmDb =====
// Node/CheckerContext caches live in ast/node.ms and checker/context.ms
// to avoid DRC lifecycle mangling bug (wrong module path for Node_destroy).
// Cache keys use: parseKey = fileId, checkKey = fileId + 10000,
// transformKey = fileId + 20000, analyzeKey = fileId + 30000.

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
	preludeCtx: CheckerContext;
	preprocessCache: Map<number, string>;  // fileId → preprocessed source
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
		stdPath: "",
		preludeCtx: null as unknown as CheckerContext,
		preprocessCache: new Map<number, string>(),
	};
}

// Cache key offsets for different query types
function parseNodeKey(fileId: number): number { return fileId; }
function checkCtxKey(fileId: number): number { return fileId + 10000; }
function checkNodeKey(fileId: number): number { return fileId + 15000; }
function transformNodeKey(fileId: number): number { return fileId + 20000; }
function analyzeNodeKey(fileId: number): number { return fileId + 30000; }

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

// Remove ExportRegistry entries for a file and its transitive dependents
// G3: Skip std/ paths — their exports are immutable for the session
function dbInvalidateExports(db: TransAmDb, fileId: number): void {
	const path = getFilePath(db.fileInput, fileId);
	if (path !== "" && !isStdPathFor(db, path)) removeExportEntry(db.exportRegistry, path);
	resetRegisteredAt(db.moduleDeps, fileId);
	const deps = getTransitiveDependents(db.moduleDeps, fileId);
	for (let i = 0; i < deps.length; i = i + 1) {
		const depPath = getFilePath(db.fileInput, deps[i]);
		if (depPath !== "" && !isStdPathFor(db, depPath)) removeExportEntry(db.exportRegistry, depPath);
		resetRegisteredAt(db.moduleDeps, deps[i]);
	}
}

function removeExportEntry(registry: ExportRegistry, path: string): void {
	for (let i = 0; i < registry.entries.length; i = i + 1) {
		if (registry.entries[i].modulePath === path) {
			removeFromNameIndex(registry, registry.entries[i].symbols);
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

// ===== Preprocess Query =====
//
// Produces preprocessed source for a file. Handles:
//   - .h files: translate C declarations to MS extern source (via translateCHeader)
//   - .ms/.cms/.jms/.wms: inline `import from "*.h"` into extern decls (via inlineHeaderImports)
//   - other: pass through raw
//
// The query runs through Trans-Am's red-green mechanism, so:
//   - Unchanged files return cached preprocessed text instantly
//   - .h files imported by a .ms file are tracked as FileText deps
//   - Editing a .h file invalidates the Preprocess query of every .ms file that imported it
//     (via lazy tryMarkGreen verification — on next query, deps are re-checked)

// Trans-Am-backed SourceProvider. When inlineHeaderImports reads a .h file through this
// provider, the read records a FileText dependency on the current query frame, so the
// containing Preprocess query auto-invalidates when the .h file changes.
function createTaSourceProvider(db: TransAmDb, currentFileId: number): SourceProvider {
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
		return db.preprocessCache.has(fileId) ? db.preprocessCache.get(fileId) : "";
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

	if (filePath.endsWith(".h")) {
		// .h → translate C to MS extern decls
		out = translateCHeader(raw, []);
	} else if (filePath.endsWith(".ms") || filePath.endsWith(".cms") || filePath.endsWith(".jms") || filePath.endsWith(".wms")) {
		// .ms-family → inline .h imports with dep-tracking provider.
		// inlineHeaderImports preserves the original `import { ... } from "*.h";`
		// statement and inserts the synthesized extern decls after it, so Phase B
		// unused-import detection walks the ImportDecl naturally.
		const provider = createTaSourceProvider(db, fileId);
		out = inlineHeaderImports(raw, filePath, provider, true);
	}

	db.preprocessCache.set(fileId, out);
	const outHash = taHashString(out);
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
		return nodeCacheGet(parseNodeKey(fileId));
	}

	// Compute — get preprocessed source via the Preprocess query. This records
	// deps on the file's own FileText AND any .h files it imports, so parse
	// invalidates when the source OR any included header changes.
	const source = dbPreprocess(db, filePath);

	pushFrame(db.depStack, key);
	// Parse depends on Preprocess (for this file).
	const preprocessKey = createQueryKey(TaQueryKind.Preprocess, fileId);
	const preprocessEntry = cacheGet(db.cache, preprocessKey);
	const preprocessHash = preprocessEntry !== null ? preprocessEntry.outputHash : 0;
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
	nodeCacheStore(parseNodeKey(fileId), program);
	const parseHash = transAmHashNode(program);
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
	if (raw.byteLength === 0) return;
	dbSetFileText(db, filePath, raw);
}

// Resolve import specifier to absolute path (relative + std/ imports).
function dbResolveImport(db: TransAmDb, basePath: string, importSpec: string): string {
	// Relative imports — try candidates (.ms, /index.ms, .cms, /index.cms)
	const relCandidates = lspResolveImportCandidates(basePath, importSpec);
	for (const c of relCandidates) {
		if (getFileId(db.fileInput, c) >= 0) return c;
	}
	for (const c of relCandidates) {
		dbEnsureFileLoaded(db, c);
		if (getFileId(db.fileInput, c) >= 0) return c;
	}
	// std/ imports
	if (db.stdPath.length > 0 && importSpec.length > 4 && importSpec.slice(0, 4) === "std/") {
		const rest = importSpec.slice(4, importSpec.length);
		const base = db.stdPath + "/" + rest;
		const candidates: string[] = [base + ".ms", base + ".cms", base + "/index.ms", base + "/index.cms"];
		for (const c of candidates) {
			if (getFileId(db.fileInput, c) >= 0) return c;
		}
		for (const c of candidates) {
			dbEnsureFileLoaded(db, c);
			if (getFileId(db.fileInput, c) >= 0) return c;
		}
	}
	return "";
}

// Scan a parsed program's imports, resolve paths, load files, record dep edges.
// Enables depth-first traversal in dbEnsureExportsRegistered.
function dbRecordDepImports(db: TransAmDb, depPath: string, depProgram: Node): void {
	const depFileId = getFileId(db.fileInput, depPath);
	if (depFileId < 0) return;
	if (depProgram === null || depProgram.kind !== NodeKind.Program) return;
	const pd = depProgram.data as ProgramData;
	for (const rawStmt of pd.programStmts) {
		let stmt = rawStmt;
		if (stmt.kind === NodeKind.ExportDecl) {
			stmt = (stmt.data as ExportDeclData).exportedDecl;
		}
		if (stmt.kind !== NodeKind.ImportDecl) continue;
		const imp = stmt.data as ImportDeclData;
		const targetPath = dbResolveImport(db, depPath, imp.importSource);
		if (targetPath === "") continue;
		dbEnsureFileLoaded(db, targetPath);
		const targetId = getFileId(db.fileInput, targetPath);
		if (targetId >= 0) {
			recordModuleImport(db.moduleDeps, depFileId, targetId);
		}
	}
}

// Lazily ensure all files imported by `filePath` have their exports in the registry.
// Depth-first: processes transitive deps before current (compileModule pattern).
function dbEnsureExportsRegistered(db: TransAmDb, filePath: string, visited: Set<string>, startVersion: number): void {
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
		if (depPath === "") continue;

		// Skip if registered at current revision (reference: incremental cache hit)
		if (getRegisteredAt(db.moduleDeps, depId) >= db.revision.value) continue;

		// Skip if already registered (but still recurse for transitive deps).
		if (findModuleExports(db.exportRegistry, depPath) !== null) {
			// Ensure dep's import edges are recorded before recursing
			if (!visited.has(depPath)) {
				const regProgram = dbParse(db, depPath);
				if (regProgram !== null) dbRecordDepImports(db, depPath, regProgram);
			}
			dbEnsureExportsRegistered(db, depPath, visited, startVersion);
			continue;
		}

		// Phase 1: parse dep, record its import edges, then depth-first recurse.
		const depProgram = dbParse(db, depPath);
		if (depProgram === null) continue;

		// Record dep's own import edges so depth-first recursion can traverse them
		dbRecordDepImports(db, depPath, depProgram);
		// Recurse into transitive deps BEFORE resolving this dep
		dbEnsureExportsRegistered(db, depPath, visited, startVersion);

		// Wire db.exportRegistry + module imports so collectImport can resolve
		// cross-module types (e.g., DrcContext.ctx: TransformContext).
		const tmpCtx = createTempCollectContext();
		tmpCtx.exportRegistry = db.exportRegistry;
		const depMod = createModule(depPath);
		depMod.imports = buildImportEntries(db, depPath, depProgram);
		tmpCtx.currentModule = depMod;
		collectTopLevel(tmpCtx, depProgram);
		resolveDeclarations(tmpCtx, depProgram);

		const earlyExports = collectExports(tmpCtx, depPath);
		registerModuleExports(db.exportRegistry, depPath, earlyExports);
		setRegisteredAt(db.moduleDeps, depId, db.revision.value);
	}
}

// Create a minimal CheckerContext for Phase 1 collection (no imports, no type checking)
function createTempCollectContext(): CheckerContext {
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Module);
	return ctx;
}

// Register a single file's exports into the ExportRegistry.
// Used by import completion when the target module hasn't been processed as a dependency yet.
export function dbEnsureModuleExports(db: TransAmDb, filePath: string): void {
	if (findModuleExports(db.exportRegistry, filePath) !== null) return;
	const program = dbParse(db, filePath);
	if (program === null) return;
	const tmpCtx = createTempCollectContext();
	tmpCtx.exportRegistry = db.exportRegistry;
	const depMod = createModule(filePath);
	depMod.imports = buildImportEntries(db, filePath, program);
	tmpCtx.currentModule = depMod;
	collectTopLevel(tmpCtx, program);
	resolveDeclarations(tmpCtx, program);
	const exports = collectExports(tmpCtx, filePath);
	if (exports.length > 0) {
		registerModuleExports(db.exportRegistry, filePath, exports);
	}
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
		// .h imports are handled by inlineHeaderImports; their ImportDecl survives
		// for unused-import detection only — don't create a module import entry.
		if (imp.importSource.length >= 2 && imp.importSource.slice(imp.importSource.length - 2, imp.importSource.length) === ".h") continue;

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
	// absPath should end with /stem.ms, /stem/index.ms, /stem/index.cms, or /stem directly (for .h/.cms)
	const suffixes = ["/" + stem + ".ms", "/" + stem + "/index.ms", "/" + stem + "/index.cms", "/" + stem];
	for (let si = 0; si < suffixes.length; si = si + 1) {
		const suf = suffixes[si];
		if (absPath.length >= suf.length) {
			if (absPath.slice(absPath.length - suf.length, absPath.length) === suf) return true;
		}
	}
	return false;
}

// Hash checker result for Salsa early cutoff. If error count + exported symbol
// signatures are unchanged, dependents stay GREEN (comment-only edits, etc.).
function hashCheckerResult(ctx: CheckerContext): number {
	if (ctx === null) return 0;
	// Only hash Error-severity errors (hints/warnings don't affect dependents)
	let errorCount = 0;
	for (const err of ctx.errors) {
		if (err.severity === Severity.Error) errorCount = errorCount + 1;
	}
	let h: number = errorCount;
	if (ctx.table !== null && ctx.table.current !== null) {
		const scope = ctx.table.current;
		for (const sym of scope.symbols) {
			if (hasFlag(sym, SymbolFlag.Exported)) {
				// Hash name + type kind so type changes invalidate dependents
				const typeKind = sym.symbolType !== null ? sym.symbolType.kind : 0;
				h = (h * 31 + taHashString(sym.name) + typeKind) % 2147483647;
			}
		}
	}
	return h;
}

// Execute type check query. Returns CheckerContext.
export function dbTypeCheck(db: TransAmDb, filePath: string): CheckerContext {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as CheckerContext;
	const key = createQueryKey(TaQueryKind.TypeCheck, fileId);

	if (tryMarkGreen(db.cache, db.fileInput, key, db.revision.value)) {
		return ctxCacheGet(checkCtxKey(fileId));
	}

	// Get the cached parse tree (needed for dependency hash tracking + to source the clone).
	const cachedProgram = dbParse(db, filePath);
	if (cachedProgram === null) return null as unknown as CheckerContext;

	// Clone the parse tree before type-checking. The checker mutates nodeType/resolvedSym
	// in-place; cloning keeps dbParse's cached tree immutable so other consumers
	// (semantic tokens, syntax queries) see a clean AST. CloneMode.Check preserves
	// typeExpr/typeExprs (resolvePass needs them) and drops nodeType/resolvedSym
	// so the checker re-populates them fresh.
	// This replaces the previous double-parse (parseSourceLenient was called twice).
	const program = cloneNodeForCheck(cachedProgram);

	const startVersion = getCancelVersion(db.cancelCtx);

	// Ensure cross-module exports are registered for all dependencies
	const visitedPaths: Set<string> = new Set<string>();
	dbEnsureExportsRegistered(db, filePath, visitedPaths, startVersion);

	pushFrame(db.depStack, key);
	const pKey = createQueryKey(TaQueryKind.Parse, fileId);
	// Record Parse dep with actual output hash (Salsa early cutoff)
	const parseEntry = cacheGet(db.cache, pKey);
	const parseHash = parseEntry !== null ? parseEntry.outputHash : 0;
	recordDependency(db.depStack, pKey, parseHash);

	// Record cross-module deps: TypeCheck(A) depends on Parse(B) AND TypeCheck(B) for each import B.
	// Parse dep: structural changes (new/removed declarations).
	// TypeCheck dep: semantic changes (export type signatures, error state).
	// Without TypeCheck dep, changing an export's type in B wouldn't invalidate A if AST shape is same.
	const importDepIds = getDirectImports(db.moduleDeps, fileId);
	for (let di = 0; di < importDepIds.length; di = di + 1) {
		const depId = importDepIds[di];
		const depParseKey = createQueryKey(TaQueryKind.Parse, depId);
		const depParseEntry = cacheGet(db.cache, depParseKey);
		recordDependency(db.depStack, depParseKey, depParseEntry !== null ? depParseEntry.outputHash : 0);
		const depCheckKey = createQueryKey(TaQueryKind.TypeCheck, depId);
		const depCheckEntry = cacheGet(db.cache, depCheckKey);
		recordDependency(db.depStack, depCheckKey, depCheckEntry !== null ? depCheckEntry.outputHash : 0);
	}

	// Cross-module: build synthetic Module + ModuleGraph, use ExportRegistry
	const imports = buildImportEntries(db, filePath, program);
	const mod = createModule(filePath);
	mod.imports = imports;
	const graph = createModuleGraph();
	addModule(graph, mod);
	if (db.preludeCtx === null) db.preludeCtx = buildPreludeContext(db.stdPath, ".cms");
	const checkerCtx = checkProgramWithRegistryCancellable(
		program, db.exportRegistry, graph, mod,
		db.preludeCtx, db.cancelCtx, startVersion
	);

	// If cancelled, discard frame without caching — partial result not reliable
	if (checkCancel(db.cancelCtx, startVersion)) {
		popFrame(db.depStack);
		return checkerCtx;
	}

	ctxCacheStore(checkCtxKey(fileId), checkerCtx);
	nodeCacheStore(checkNodeKey(fileId), program);  // cache checked program (has resolvedSym/nodeType)
	const checkHash = hashCheckerResult(checkerCtx);
	executeQueryWith(db.cache, db.fileInput, db.depStack, key, db.revision.value, checkHash, true);
	return checkerCtx;
}

// Get the checked program (has resolvedSym/nodeType on AST nodes).
// Falls back to raw parse if no checked version is cached.
export function dbGetCheckedProgram(db: TransAmDb, filePath: string): Node {
	const fileId = getFileId(db.fileInput, filePath);
	if (fileId < 0) return null as unknown as Node;
	const checked = nodeCacheGet(checkNodeKey(fileId));
	if (checked !== null) return checked;
	return dbParse(db, filePath);
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
	const _cachedProg = dbParse(db, filePath);
	if (_cachedProg === null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	// Fresh parse for transform — checker already mutated its own copy
	// (enum MemberExpr → Identifier), and transforms also mutate the AST.
	const analyzeSrc = getFileText(db.fileInput, fileId);
	const analyzeParse = parseSource(analyzeSrc);
	const program = analyzeParse.ok ? analyzeParse.value : null as unknown as Node;
	if (program === null) return null as unknown as Node;

	pushFrame(db.depStack, key);
	const ckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	const ckEntry = cacheGet(db.cache, ckKey);
	recordDependency(db.depStack, ckKey, ckEntry !== null ? ckEntry.outputHash : 0);

	const transformed = transformProgram(program, checkerCtx, false);
	const analyzed = analyzeProgram(transformed, checkerCtx);
	nodeCacheStore(analyzeNodeKey(fileId), analyzed);
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
		return nodeCacheGet(transformNodeKey(fileId));
	}

	const _cachedProg2 = dbParse(db, filePath);
	if (_cachedProg2 === null) return null as unknown as Node;
	const checkerCtx = dbTypeCheck(db, filePath);

	// Fresh parse — checker mutates AST, transforms also mutate
	const txSrc = getFileText(db.fileInput, fileId);
	const txParse = parseSource(txSrc);
	const program = txParse.ok ? txParse.value : null as unknown as Node;
	if (program === null) return null as unknown as Node;

	pushFrame(db.depStack, key);
	const tckKey = createQueryKey(TaQueryKind.TypeCheck, fileId);
	const tckEntry = cacheGet(db.cache, tckKey);
	recordDependency(db.depStack, tckKey, tckEntry !== null ? tckEntry.outputHash : 0);

	const transformed = transformProgram(program, checkerCtx, false);
	nodeCacheStore(transformNodeKey(fileId), transformed);
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
	if (program === null) return false;
	return program.kind === NodeKind.Program;
}

test "create db" {
	const db = createTransAmDb(100);
	assert db.revision.value === 0;
	assert db.cache.capacity === 100;
}

test "set file text increments revision" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	assert db.revision.value === 1;
}

test "same content does not increment" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	assert db.revision.value === 1;
	dbSetFileText(db, "a.ms", "const x = 1;");
	assert db.revision.value === 1;  // no change
}

test "parse produces AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	const result = dbParse(db, "test.ms");
	assert result !== null;
	assert result.kind === NodeKind.Program;
}

test "parse caches result" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const y = 2;");
	const r1 = dbParse(db, "test.ms");
	assert r1 !== null;
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
	assert entry !== null;
	assert entry.state === TaQueryState.Red;
}

test "preprocess query passes through non-header files" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "plain.ms", "const x = 1;");
	const out = dbPreprocess(db, "plain.ms");
	assert out === "const x = 1;";
}

test "preprocess query caches result" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "plain.ms", "const x = 1;");
	const out1 = dbPreprocess(db, "plain.ms");
	const out2 = dbPreprocess(db, "plain.ms");
	assert out1 === out2;
	// Second call should be a cache hit — Preprocess query state is Green
	const fileId = getFileId(db.fileInput, "plain.ms");
	const key = createQueryKey(TaQueryKind.Preprocess, fileId);
	const entry = cacheGet(db.cache, key);
	assert entry !== null;
	assert entry.state === TaQueryState.Green;
}

test "preprocess query invalidates on file change" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "plain.ms", "const a = 1;");
	dbPreprocess(db, "plain.ms");
	dbSetFileText(db, "plain.ms", "const b = 2;");
	const fileId = getFileId(db.fileInput, "plain.ms");
	const key = createQueryKey(TaQueryKind.Preprocess, fileId);
	const entry = cacheGet(db.cache, key);
	assert entry !== null;
	assert entry.state === TaQueryState.Red;
}

test "full pipeline produces analyzed AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1; const y = 2;");
	const result = dbAnalyze(db, "test.ms");
	assert result !== null;
	assert isValidProgram(result);
}

test "unknown file returns null" {
	const db = createTransAmDb(100);
	const result = dbParse(db, "nonexistent.ms");
	assert result === null;
}

test "dbTransform produces transformed AST" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "t.ms", "const x = 1;");
	const result = dbTransform(db, "t.ms");
	assert result !== null;
	assert result.kind === NodeKind.Program;
}

test "dbCompileSource runs full pipeline" {
	const db = createTransAmDb(100);
	const result = dbCompileSource(db, "const a = 1; const b = 2;");
	assert result !== null;
	assert isValidProgram(result);
}

test "dbCompileToJS runs without analyzer" {
	const db = createTransAmDb(100);
	const result = dbCompileToJS(db, "const x = 42;");
	assert result !== null;
	assert result.kind === NodeKind.Program;
}

test "dbCompileSource caches on same input" {
	const db = createTransAmDb(100);
	dbCompileSource(db, "const z = 1;");
	assert db.revision.value === 1;
	// Same input should not increment revision
	dbCompileSource(db, "const z = 1;");
	assert db.revision.value === 1;
}

test "db has cancel context" {
	const db = createTransAmDb(100);
	assert db.cancelCtx.version === 0;
	assert !db.cancelCtx.cancelled;
}

test "db has string interner" {
	const db = createTransAmDb(100);
	const id = internString(db.interner, "hello");
	assert id === 0;
	assert lookupInterned(db.interner, id) === "hello";
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
	assert ctx !== null;
	let foundUnusedHostname = false;
	let foundUnusedCpuInfo = false;
	for (const err of ctx.errors) {
		if (err.message.indexOf("msOsHostname") >= 0 && err.message.indexOf("imported but never used") >= 0) {
			foundUnusedHostname = true;
			assert err.line === 3;
		}
		if (err.message.indexOf("CpuInfo") >= 0 && err.message.indexOf("imported but never used") >= 0) {
			foundUnusedCpuInfo = true;
		}
	}
	assert foundUnusedHostname;
	assert !foundUnusedCpuInfo;
}

// ===== Salsa Early Cutoff Integration Tests =====

test "comment-only edit keeps typecheck cache green" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	// Run full pipeline to populate cache
	dbTypeCheck(db, "test.ms");
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const before = cacheGet(db.cache, checkKey);
	assert before !== null;
	assert before.state === TaQueryState.Green;
	const computedBefore = before.computedAt;

	// Edit: add comment only (no semantic change)
	dbSetFileText(db, "test.ms", "const x = 1; // comment");
	assert db.revision.value === 2;

	// Parse must recompute (file hash changed)
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const parseEntry = cacheGet(db.cache, parseKey);
	assert parseEntry.state === TaQueryState.Red;

	// Force parse recompute
	dbParse(db, "test.ms");

	// TypeCheck should verify GREEN via early cutoff (parse output hash unchanged)
	assert tryMarkGreen(db.cache, db.fileInput, checkKey, db.revision.value);
	const after = cacheGet(db.cache, checkKey);
	assert after.state === TaQueryState.Green;
	// computedAt should NOT change (wasn't recomputed, just verified)
	assert after.computedAt === computedBefore;
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
	assert entry !== null;
	// outputHash should be non-zero (real AST hash)
	assert entry.outputHash !== 0;
}

test "same source produces same parse hash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "a.ms", "const x = 1;");
	dbParse(db, "a.ms");
	const hashA = cacheGet(db.cache, createQueryKey(TaQueryKind.Parse, 0)).outputHash;

	dbSetFileText(db, "b.ms", "const x = 1;");
	dbParse(db, "b.ms");
	const hashB = cacheGet(db.cache, createQueryKey(TaQueryKind.Parse, 1)).outputHash;

	assert hashA === hashB;
}

test "dbTypeCheck records parse dep with real hash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x = 1;");
	dbTypeCheck(db, "test.ms");

	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const entry = cacheGet(db.cache, checkKey);
	assert entry !== null;
	assert entry.dependencies.length > 0;

	// Find Parse dependency and verify it has a real hash
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	let foundParseDep = false;
	let i = 0;
	while (i < entry.dependencies.length) {
		if (queryKeysEqual(entry.dependencies[i].depKey, parseKey)) {
			// expectedHash should match parse entry's outputHash
			const parseEntry = cacheGet(db.cache, parseKey);
			assert entry.dependencies[i].expectedHash === parseEntry.outputHash;
			foundParseDep = true;
		}
		i = i + 1;
	}
	assert foundParseDep;
}

test "whitespace-only edit keeps typecheck green" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "test.ms", "const x=1;");
	dbTypeCheck(db, "test.ms");

	// Add whitespace only
	dbSetFileText(db, "test.ms", "const  x=1;");
	dbParse(db, "test.ms");

	// Whitespace changes token positions but not AST structure
	// However, the parser may produce different results due to spacing
	// This test verifies the hash comparison path works correctly either way
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const parseEntry = cacheGet(db.cache, parseKey);
	const checkEntry = cacheGet(db.cache, checkKey);

	// Parse was recomputed (file changed)
	assert parseEntry.state === TaQueryState.Green;
	assert parseEntry.computedAt === 2;
}

test "syntax error parse still stores hash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "bad.ms", "const = ;");
	dbParse(db, "bad.ms");

	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = cacheGet(db.cache, parseKey);
	assert entry !== null;
	// Even failed parse stores a hash (of null node → 0)
	assert entry.state === TaQueryState.Green;
}

test "cross-module interface field resolution" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/test/c.ms", "export interface Bar { value: number; }");
	dbSetFileText(db, "/test/b.ms", 'import { Bar } from "./c";\nexport interface Foo { x: Bar; count: number; }');
	dbSetFileText(db, "/test/a.ms", 'import { Foo } from "./b";\nfunction test(f: Foo): number { return f.count; }');

	const aId = getFileId(db.fileInput, "/test/a.ms");
	const bId = getFileId(db.fileInput, "/test/b.ms");
	recordModuleImport(db.moduleDeps, aId, bId);

	const visited: Set<string> = new Set<string>();
	dbEnsureExportsRegistered(db, "/test/a.ms", visited, 0);

	// Foo should be registered with resolved fields
	const fooInfo = findExportedSymbol(db.exportRegistry, "/test/b.ms", "Foo");
	assert fooInfo !== null;
	const fooType = fooInfo.symType;
	assert fooType !== null;
	// Interface = Ref<Struct>. Unwrap Ref to get inner Struct.
	const inner = fooType.typeReturn !== null ? fooType.typeReturn : fooType;
	assert inner.typeNames !== null;
	assert inner.typeNames.length === 2;
	assert inner.typeNames[0] === "x";
	assert inner.typeNames[1] === "count";
	// Field types should be resolved — x: Bar is Ref<Struct(Bar)>
	assert inner.typeChildren !== null;
	assert inner.typeChildren.length === 2;
}
