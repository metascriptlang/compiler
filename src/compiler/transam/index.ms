// Trans-Am Hub — incremental query engine entry point
//
// Pipeline: parse → check → transform → analyze → (codegen)
//           \_______________\________________\_______________/
//                    Trans-Am (incremental query cache)
//
// TransAmDb aggregates all stores. dbSetFileText triggers invalidation.
// dbExecute runs the full pipeline through the red-green engine.

import { Node, NodeKind, nodeCacheStore, nodeCacheGet } from "../../ast/node";
import { CheckerContext, ctxCacheStore, ctxCacheGet } from "../../checker/context";
import {
	TaQueryKey, TaQueryKind, TaQueryState, TaDurability,
	TaRevision, createRevision, incrementRevision,
	createQueryKey, queryKeysEqual
} from "./revision";
import { taHashString } from "./hash";
import {
	TaCacheEntry, createCacheEntry,
	TaDependencyStack, TaDependencyList,
	createDependencyStack, pushFrame, popFrame,
	recordDependency, hasActiveFrame
} from "./query";
import {
	TaCacheStore, createCacheStore, cacheGet, cachePut,
	cacheContains, markQueriesRedForFile
} from "./cache";
import {
	TaFileInputStore, createFileInputStore,
	setFileText, getFileText, getFileHash, getFileId, hasFile
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
import { test, check, testGroup } from "std/testing";
import { parseSource } from "../../parser/statements/validation";
import { checkProgram } from "../../checker/index";
import { transformProgram } from "../../transform/index";
import { analyzeProgram } from "../../analyzer/index";

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
	return true;
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

	pushFrame(db.depStack, key);
	const pKey = createQueryKey(TaQueryKind.Parse, fileId);
	recordDependency(db.depStack, pKey, 0);

	const checkerCtx = checkProgram(program);
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
	setFileText, getFileText, getFileHash, getFileId, hasFile
} from "./fileInput";
export {
	TaModuleDepGraph, createModuleDepGraph,
	recordModuleImport, getTransitiveDependents
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

testGroup("TransAmDb Basics", () => {
	test("create db", () => {
		const db = createTransAmDb(100);
		check(db.revision.value === 0);
		check(db.cache.capacity === 100);
	});
	test("set file text increments revision", () => {
		const db = createTransAmDb(100);
		dbSetFileText(db, "a.ms", "const x = 1;");
		check(db.revision.value === 1);
	});
	test("same content does not increment", () => {
		const db = createTransAmDb(100);
		dbSetFileText(db, "a.ms", "const x = 1;");
		check(db.revision.value === 1);
		dbSetFileText(db, "a.ms", "const x = 1;");
		check(db.revision.value === 1);  // no change
	});
});

testGroup("TransAmDb Parse", () => {
	test("parse produces AST", () => {
		const db = createTransAmDb(100);
		dbSetFileText(db, "test.ms", "const x = 1;");
		const result = dbParse(db, "test.ms");
		check(result !== null);
		check(result.kind === NodeKind.Program);
	});
	test("parse caches result", () => {
		const db = createTransAmDb(100);
		dbSetFileText(db, "test.ms", "const y = 2;");
		const r1 = dbParse(db, "test.ms");
		check(r1 !== null);
		// Second call should hit cache
		const key = createQueryKey(TaQueryKind.Parse, 0);
		check(cacheContains(db.cache, key));
	});
	test("file change invalidates parse", () => {
		const db = createTransAmDb(100);
		dbSetFileText(db, "test.ms", "const a = 1;");
		dbParse(db, "test.ms");
		// Change file
		dbSetFileText(db, "test.ms", "const b = 2;");
		// Cache entry should be RED
		const key = createQueryKey(TaQueryKind.Parse, 0);
		const entry = cacheGet(db.cache, key);
		check(entry !== null);
		check(entry.state === TaQueryState.Red);
	});
});

testGroup("TransAmDb Pipeline", () => {
	test("full pipeline produces analyzed AST", () => {
		const db = createTransAmDb(100);
		dbSetFileText(db, "test.ms", "const x = 1; const y = 2;");
		const result = dbAnalyze(db, "test.ms");
		check(result !== null);
		check(isValidProgram(result));
	});
	test("unknown file returns null", () => {
		const db = createTransAmDb(100);
		const result = dbParse(db, "nonexistent.ms");
		check(result === null);
	});
	test("dbTransform produces transformed AST", () => {
		const db = createTransAmDb(100);
		dbSetFileText(db, "t.ms", "const x = 1;");
		const result = dbTransform(db, "t.ms");
		check(result !== null);
		check(result.kind === NodeKind.Program);
	});
	test("dbCompileSource runs full pipeline", () => {
		const db = createTransAmDb(100);
		const result = dbCompileSource(db, "const a = 1; const b = 2;");
		check(result !== null);
		check(isValidProgram(result));
	});
	test("dbCompileToJS runs without analyzer", () => {
		const db = createTransAmDb(100);
		const result = dbCompileToJS(db, "const x = 42;");
		check(result !== null);
		check(result.kind === NodeKind.Program);
	});
	test("dbCompileSource caches on same input", () => {
		const db = createTransAmDb(100);
		dbCompileSource(db, "const z = 1;");
		check(db.revision.value === 1);
		// Same input should not increment revision
		dbCompileSource(db, "const z = 1;");
		check(db.revision.value === 1);
	});
});

testGroup("TransAmDb Cancel+Intern", () => {
	test("db has cancel context", () => {
		const db = createTransAmDb(100);
		check(db.cancelCtx.version === 0);
		check(!db.cancelCtx.cancelled);
	});
	test("db has string interner", () => {
		const db = createTransAmDb(100);
		const id = internString(db.interner, "hello");
		check(id === 0);
		check(lookupInterned(db.interner, id) === "hello");
	});
});
