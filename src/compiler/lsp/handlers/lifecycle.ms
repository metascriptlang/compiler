// LSP Lifecycle Handlers + Dispatch Router + Tests
// handleInitialize, handleDidOpen, handleDidChange, handleDidClose, lspDispatch

import {
	TransAmDb, createTransAmDb, dbSetFileText, dbParse, dbTypeCheck, dbCheckIsCurrent,
	dbForgetAllTypeChecks, getFileId, getFilePath, invalidateFile, recordModuleImport,
	cacheGet, createQueryKey, TaQueryKind, getTransitiveDependents,
} from "../../transam/index";
import { lookupLocal } from "../../../checker/symbol";
import { lookupModuleCtx } from "../../../checker/instantiate";
import { typeDisplayName } from "../../../checker/types";
import { requestCancel, resetCancel } from "../../transam/cancel";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, asString, asInt32 } from "std/serialize/json/accessors";
import { writeStderr } from "std/io";
import { readFile, writeFile, mkdir, remove } from "std/fs";
import { env } from "std/process";
import { normalize } from "std/fs/path";
import {
	lspJsonString, lspGetField, lspGetNumberField, lspGetObjectField,
	lspResponse, lspNotification, lspFormatMessage, lspUriToPath,
	lspPathToUri, lspGetArrayItems, lspGetBoolField, lspRequest, lspParseContentLength,
} from "../protocol";
import { lspFmtPublishDiagnostics } from "../format";
import { lineOffset } from "../../fmt/edit";
import {
	CompletionCache, ChangedFile, createCompletionCache, markFileChanged, drainChangedFiles,
	markDocumentOpen, markDocumentClosed, isDocumentOpen, openDocuments,
	markDependentsStale, drainStaleDependents, lspReloadFromDisk, dbGetSource, lspDocumentUri,
} from "./shared";
import {
	buildDiagnosticsJson, buildTransitiveDiagnosticsWire, recordImportsForFile,
	resetFormatOptions, resetLspTargetCache, forgetPublishedDiagnostics, recordPublishedDiagnostics,
} from "./diagnostics";
import { prebuildCompletionCache, handleCompletion, handleCompletionResolve } from "./completion";
import { handleDefinition } from "./definition";
import {
	handleHover,
	handleDocumentSymbol,
	handleSignatureHelp,
	handleInlayHint,
	handleReferences,
	handleDocumentHighlight,
	handleRename,
} from "./queries";
import { handleSemanticTokensFull } from "./semanticTokens";
import { handleCodeAction, handleFormatting, handleRangeFormatting } from "./formatting";


// ===== Deferred Diagnostics (post-drain) =====

export function checkDependentsUnlessStopped(db: TransAmDb, path: string): boolean {
	const fileId = getFileId(db.fileInput, path);
	if (fileId < 0) return true;
	for (const dep of getTransitiveDependents(db.moduleDeps, fileId)) {
		const depPath = getFilePath(db.fileInput, dep);
		if (depPath == "") continue;
		dbTypeCheck(db, depPath);
		if (db.cancelCtx.stoppedForInput) return false;
	}
	return true;
}

export function publishPendingDiagnostics(db: TransAmDb): string {
	const changed = drainChangedFiles();
	const stale = drainStaleDependents();
	let result = "";
	for (let i = 0; i < changed.length; i++) {
		const path = changed[i].path;
		const uri = changed[i].uri;
		try {
			const t0 = performance.now();
			dbTypeCheck(db, path);
			const t1 = performance.now();
			if (db.cancelCtx.stoppedForInput) {
				requeueDiagnostics(changed, i, stale, 0);
				return result;
			}
			prebuildCompletionCache(db, path, uri);
			const t2 = performance.now();
			const diagParams = recordPublishedDiagnostics(path, buildDiagnosticsJson(uri, db, path));
			result = result + lspFormatMessage(lspNotification("textDocument/publishDiagnostics", diagParams));
			const t3 = performance.now();
			if (!checkDependentsUnlessStopped(db, path)) {
				markDependentsStale(path);
				requeueDiagnostics(changed, i + 1, stale, 0);
				return result;
			}
			result = result + buildTransitiveDiagnosticsWire(db, path);
			const t4 = performance.now();
			writeStderr(`[LSP-CHANGE] ${path} check=${t1 - t0}ms cache=${t2 - t1}ms`
				+ ` diag=${t3 - t2}ms dependents=${t4 - t3}ms total=${t4 - t0}ms\n`);
		} catch (e) {
			const fileId = getFileId(db.fileInput, path);
			if (fileId >= 0) invalidateFile(db.cache, db.moduleDeps, fileId);
			writeStderr("[LSP] type check failed for " + path + ": " + e + "\n");
			const emptyParams = recordPublishedDiagnostics(path, lspFmtPublishDiagnostics(uri, "[]"));
			result = result + lspFormatMessage(lspNotification("textDocument/publishDiagnostics", emptyParams));
		}
	}
	for (let i = 0; i < stale.length; i++) {
		try {
			if (!checkDependentsUnlessStopped(db, stale[i])) {
				requeueDiagnostics(changed, changed.length, stale, i);
				return result;
			}
			result = result + buildTransitiveDiagnosticsWire(db, stale[i]);
		} catch (e) {
			writeStderr("[LSP] dependents check failed for " + stale[i] + ": " + e + "\n");
		}
	}
	return result;
}

function requeueDiagnostics(changed: ChangedFile[], fromChanged: int32, stale: string[], fromStale: int32): void {
	for (let i = fromChanged; i < changed.length; i++) markFileChanged(changed[i].path, changed[i].uri);
	for (let i = fromStale; i < stale.length; i++) markDependentsStale(stale[i]);
}

// ===== Initialize =====

export function handleInitialize(id: string): string {
	const caps = "{\"capabilities\":{"
		+ "\"textDocumentSync\":1"
		+ ",\"hoverProvider\":true"
		+ ",\"completionProvider\":{\"triggerCharacters\":[\".\",\"/\"],\"resolveProvider\":true}"
		+ ",\"definitionProvider\":true"
		+ ",\"documentSymbolProvider\":true"
		+ ",\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}"
		+ ",\"inlayHintProvider\":true"
		+ ",\"referencesProvider\":true"
		+ ",\"documentHighlightProvider\":true"
		+ ",\"renameProvider\":true"
		+ ",\"documentFormattingProvider\":true"
		+ ",\"documentRangeFormattingProvider\":true"
		+ ",\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\",\"source.fixAll\"]}"
		+ ",\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":"
		+ "[\"namespace\",\"type\",\"class\",\"enum\",\"interface\",\"struct\","
		+ "\"typeParameter\",\"parameter\",\"variable\",\"property\","
		+ "\"enumMember\",\"event\",\"function\",\"method\",\"macro\","
		+ "\"keyword\",\"modifier\",\"comment\",\"string\",\"number\","
		+ "\"regexp\",\"operator\",\"decorator\"],"
		+ "\"tokenModifiers\":[\"declaration\",\"definition\",\"readonly\",\"static\",\"defaultLibrary\"]}"
		+ ",\"full\":true}"
		+ "}}";
	return lspResponse(id, caps);
}

// ===== Shutdown =====

export function handleShutdown(id: string): string {
	return lspResponse(id, "null");
}

// ===== Did Open =====

export function handleDidOpen(params: string, db: TransAmDb): string {
	const t0 = performance.now();
	const uri = lspDocumentUri(params);
	const text = lspGetField(lspGetObjectField(params, "textDocument"), "text");
	const path = lspUriToPath(uri);
	markDocumentOpen(path);

	dbSetFileText(db, path, text);
	const t1 = performance.now();
	const program = dbParse(db, path);
	const t2 = performance.now();
	recordImportsForFile(db, path, program);
	const t3 = performance.now();
	dbTypeCheck(db, path);
	if (db.cancelCtx.stoppedForInput) {
		markFileChanged(path, uri);
		return "";
	}
	const t4 = performance.now();
	prebuildCompletionCache(db, path, uri);
	const t5 = performance.now();
	const diagParams = recordPublishedDiagnostics(path, buildDiagnosticsJson(uri, db, path));
	const t6 = performance.now();
	writeStderr(`[LSP-OPEN] ${path} parse=${t2 - t1}ms imports=${t3 - t2}ms check=${t4 - t3}ms cache=${t5 - t4}ms diag=${t6 - t5}ms total=${t6 - t0}ms\n`);
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Did Change =====

export function handleDidChange(params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
	// Two-step extraction: scope search to contentChanges array (avoids matching "text" elsewhere)
	const contentChanges = lspGetObjectField(params, "contentChanges");
	const changes = lspGetField(contentChanges, "text");
	const path = lspUriToPath(uri);
	// Lightweight: update text + parse only. No type check on keystrokes.
	// Diagnostics publish post-drain via publishPendingDiagnostics().
	dbSetFileText(db, path, changes);
	const program = dbParse(db, path);
	recordImportsForFile(db, path, program);
	markFileChanged(path, uri);
	return "";
}

// ===== Did Close =====

export function handleDidClose(params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
	const path = lspUriToPath(uri);
	markDocumentClosed(path);
	forgetPublishedDiagnostics(path);
	refreshFromDisk(db, path);
	const diagParams = "{\"uri\":" + lspJsonString(uri) + ",\"diagnostics\":[]}";
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

const FILE_CREATED: number = 1;

export function handleDidChangeWatchedFiles(params: string, db: TransAmDb): string {
	let created = false;
	for (const change of lspGetArrayItems(lspGetObjectField(params, "changes"))) {
		const path = knownPathFor(db, lspUriToPath(lspGetField(change, "uri")));
		if (path == "" || isDocumentOpen(path)) continue;
		if (getFileId(db.fileInput, path) >= 0) {
			refreshFromDisk(db, path);
		} else if (lspGetNumberField(change, "type") == FILE_CREATED) {
			created = true;
		}
	}
	if (created) {
		reresolveOpenDocuments(db);
	}
	return "";
}

function knownPathFor(db: TransAmDb, path: string): string {
	if (path == "" || getFileId(db.fileInput, path) >= 0) return path;
	const normalized = normalize(path);
	return getFileId(db.fileInput, normalized) >= 0 ? normalized : path;
}

function refreshFromDisk(db: TransAmDb, path: string): void {
	if (!lspReloadFromDisk(db, path)) return;
	recordImportsForFile(db, path, dbParse(db, path));
	markDependentsStale(path);
}

function reresolveOpenDocuments(db: TransAmDb): void {
	dbForgetAllTypeChecks(db);
	for (const path of openDocuments()) {
		if (getFileId(db.fileInput, path) < 0) continue;
		recordImportsForFile(db, path, dbParse(db, path));
		markFileChanged(path, lspPathToUri(path));
	}
}

export function clientSupportsWatchedFileRegistration(initializeParams: string): boolean {
	const capabilities = lspGetObjectField(initializeParams, "capabilities");
	const workspace = lspGetObjectField(capabilities, "workspace");
	const watchedFiles = lspGetObjectField(workspace, "didChangeWatchedFiles");
	return lspGetBoolField(watchedFiles, "dynamicRegistration");
}

export function watchedFilesRegistration(): string {
	let watchers = "";
	for (const glob of ["**/*.ms", "**/*.cms", "**/*.jms", "**/*.h"]) {
		if (watchers != "") {
			watchers = watchers + ",";
		}
		watchers = watchers + "{\"globPattern\":" + lspJsonString(glob) + "}";
	}
	const registration = "{\"id\":\"msc-watched-files\""
		+ ",\"method\":\"workspace/didChangeWatchedFiles\""
		+ ",\"registerOptions\":{\"watchers\":[" + watchers + "]}}";
	const params = "{\"registrations\":[" + registration + "]}";
	return lspRequest("\"msc/registerWatchedFiles\"", "client/registerCapability", params);
}

// ===== Did Save =====

export function handleDidSave(params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
	const path = lspUriToPath(uri);
	// Reload format config when build.ms or msc.json is saved
	if (path.endsWith("/build.ms") || path.endsWith("/msc.json")) {
		resetFormatOptions();
		resetLspTargetCache();
	}
	return "";
}

// ===== Dispatch =====

export function lspDispatch(method: string, id: string, params: string, db: TransAmDb, cache: CompletionCache): string {
	return match (method) {
		"initialize" => handleInitialize(id),
		"shutdown" => handleShutdown(id),
		"textDocument/didOpen" => handleDidOpen(params, db),
		"textDocument/didChange" => handleDidChange(params, db),
		"textDocument/didClose" => handleDidClose(params, db),
		"textDocument/didSave" => handleDidSave(params, db),
		"workspace/didChangeWatchedFiles" => handleDidChangeWatchedFiles(params, db),
		"textDocument/hover" => handleHover(id, params, db),
		"textDocument/completion" => handleCompletion(id, params, db, cache),
		"completionItem/resolve" => handleCompletionResolve(id, params),
		"textDocument/definition" => handleDefinition(id, params, db),
		"textDocument/documentSymbol" => handleDocumentSymbol(id, params, db),
		"textDocument/signatureHelp" => handleSignatureHelp(id, params, db),
		"textDocument/inlayHint" => handleInlayHint(id, params, db),
		"textDocument/references" => handleReferences(id, params, db),
		"textDocument/documentHighlight" => handleDocumentHighlight(id, params, db),
		"textDocument/rename" => handleRename(id, params, db),
		"textDocument/semanticTokens/full" => handleSemanticTokensFull(id, params, db),
		"textDocument/formatting" => handleFormatting(id, params, db),
		"textDocument/rangeFormatting" => handleRangeFormatting(id, params, db),
		"textDocument/codeAction" => handleCodeAction(id, params, db),
		"$/cancelRequest" => {
			return "";
		},
		_ => {
			return "";
		},
	};
}

// ===== Tests =====

function testDb(uri: string, source: string): TransAmDb {
	const db = createTransAmDb(100);
	const path = lspUriToPath(uri);
	dbSetFileText(db, path, source);
	return db;
}

function testCache(): CompletionCache {
	return createCompletionCache();
}

test "returns capabilities" {
	const r = handleInitialize("1");
	assert lspGetField(r, "jsonrpc") == "2.0";
	assert lspGetNumberField(r, "id") == 1;
	const result = lspGetObjectField(r, "result");
	assert result.length > 0;
}

test "returns null result" {
	const r = handleShutdown("2");
	assert lspGetNumberField(r, "id") == 2;
}

test "clean source has no diagnostics" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const diags = buildDiagnosticsJson("file:///test.ms", db, lspUriToPath("file:///test.ms"));
	assert lspGetField(diags, "uri") == "file:///test.ms";
}

test "actor static without readonly is reported" {
	const db = testDb("file:///test.ms", "actor A {\n\tstatic n: int32 = 0;\n\tping(): int32 { return 1; }\n}\n");
	const diags = buildDiagnosticsJson("file:///test.ms", db, lspUriToPath("file:///test.ms"));
	assert diags.indexOf("must be 'static readonly'") >= 0;
}

test "initialize" {
	const db = createTransAmDb(100);
	const r = lspDispatch("initialize", "1", "{}", db, testCache());
	assert lspGetNumberField(r, "id") == 1;
}

test "shutdown" {
	const db = createTransAmDb(100);
	const r = lspDispatch("shutdown", "2", "{}", db, testCache());
	assert lspGetNumberField(r, "id") == 2;
}

test "unknown method with id" {
	const db = createTransAmDb(100);
	const r = lspDispatch("unknown/method", "3", "{}", db, testCache());
	assert r == "";
}

test "unknown notification" {
	const db = createTransAmDb(100);
	const r = lspDispatch("$/unknownNotification", "", "{}", db, testCache());
	assert r == "";
}

test "completion dispatch" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":3}}";
	const r = lspDispatch("textDocument/completion", "10", params, db, testCache());
	assert lspGetNumberField(r, "id") == 10;
	assert r.length > 0;
}

test "definition dispatch" {
	const db = testDb("file:///test.ms", "const myVar = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/definition", "11", params, db, testCache());
	assert lspGetNumberField(r, "id") == 11;
	assert r.length > 0;
}

test "returns completion items" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":0}}";
	const r = handleCompletion("5", params, db, testCache());
	assert lspGetNumberField(r, "id") == 5;
	assert r.length > 50;
}

test "unknown doc returns empty" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleCompletion("6", params, db, testCache());
	assert lspGetNumberField(r, "id") == 6;
}

test "completion cache hit on prefix extend" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const cache = testCache();
	const params1 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":2}}";
	const r1 = handleCompletion("10", params1, db, cache);
	assert cache.items.length > 0;
	assert cache.uri == "file:///test.ms";
	const params2 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":3}}";
	const r2 = handleCompletion("11", params2, db, cache);
	assert r2.length > 0;
}

test "completion cache miss on different line" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;\nconst xyz = 3;");
	const cache = testCache();
	const params1 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":2}}";
	handleCompletion("10", params1, db, cache);
	const cachedLine = cache.line;
	const params2 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":2,\"character\":2}}";
	handleCompletion("11", params2, db, cache);
	assert cache.line != cachedLine;
}

test "member access completion returns struct fields" {
	const src = "interface Foo {\n\tx: number;\n\ty: string;\n}\nconst f: Foo = { x: 1, y: \"hi\" };\nf.";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":5,\"character\":2}}";
	const r = handleCompletion("20", params, db, testCache());
	assert lspGetNumberField(r, "id") == 20;
	assert r.indexOf("\"label\":\"x\"") >= 0;
	assert r.indexOf("\"label\":\"y\"") >= 0;
	assert r.indexOf("\"detail\":\"number\"") >= 0;
	assert r.indexOf("\"detail\":\"string\"") >= 0;
}

test "returns location for known symbol" {
	const db = testDb("file:///test.ms", "const myVar = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleDefinition("7", params, db);
	assert lspGetNumberField(r, "id") == 7;
	assert r.length > 0;
}

test "unknown doc returns null" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleDefinition("8", params, db);
	assert lspGetNumberField(r, "id") == 8;
}

test "unknown position returns null result" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":99,\"character\":0}}";
	const r = handleDefinition("9", params, db);
	assert lspGetNumberField(r, "id") == 9;
}

test "definition inside template literal" {
	const src = "const myName = \"world\";\nconst msg = `hello ${myName}`;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":21}}";
	const r = handleDefinition("50", params, db);
	assert r.indexOf("\"line\":0") >= 0;
	assert r.indexOf("\"character\":6") >= 0;
}

test "definition on param inside template literal" {
	const src = "function fmt(expected: string): string {\n\treturn `Expected ${expected}!`;\n}";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":22}}";
	const r = handleDefinition("51", params, db);
	assert r.indexOf("\"line\":0") >= 0;
	assert r.indexOf("\"character\":13") >= 0;
}

test "definition on JSX component tag jumps to its function" {
	const src = "function Counter(): number { return 0; }\nconst v = <Counter/>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":12}}";
	const r = handleDefinition("60", params, db);
	assert r.indexOf("\"line\":0") >= 0;
}

test "definition on nested JSX component tag resolves" {
	// line2: const v = <Outer><Inner/></Outer>;  Inner at chars 18-22
	const src = "function Outer(): number { return 0; }\nfunction Inner(): number { return 1; }\nconst v = <Outer><Inner/></Outer>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":2,\"character\":19}}";
	const r = handleDefinition("61", params, db);
	assert r.indexOf("\"line\":1") >= 0;
}

test "definition on member JSX tag <Foo.Bar/> resolves base" {
	// line1: const v = <Foo.Bar/>;  Foo at chars 11-13
	const src = "function Foo(): number { return 0; }\nconst v = <Foo.Bar/>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":12}}";
	const r = handleDefinition("62", params, db);
	assert r.indexOf("\"line\":0") >= 0;
}

test "definition on lowercase JSX tag does not resolve (platform string)" {
	// `function div` exists, but a lowercase tag is a platform string, NOT a component.
	const src = "function div(): number { return 0; }\nconst v = <div/>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":12}}";
	const r = handleDefinition("63", params, db);
	assert r.indexOf("\"line\":0") < 0;
}

test "definition on undefined JSX component does not crash" {
	const src = "const v = <Missing/>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":12}}";
	const r = handleDefinition("64", params, db);
	assert lspGetNumberField(r, "id") == 64;
}

test "definition on JSX tag with attributes resolves" {
	// line1: const v = <Btn id="x" disabled/>;  Btn at chars 11-13
	const src = "function Btn(): number { return 0; }\nconst v = <Btn id=\"x\" disabled/>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":12}}";
	const r = handleDefinition("65", params, db);
	assert r.indexOf("\"line\":0") >= 0;
}

test "find references from a JSX tag finds the other usages" {
	const src = "function Counter(): number { return 0; }\nconst a = <Counter/>;\nconst b = <Counter/>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":12}}";
	const r = handleReferences("66", params, db);
	assert r.indexOf("\"line\":2") >= 0;
	assert r.indexOf("\"line\":0") >= 0;
}

test "rename a component updates its JSX tag occurrence" {
	const src = "function Counter(): number { return 0; }\nconst v = <Counter/>;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":12},\"newName\":\"Tally\"}";
	const r = handleRename("67", params, db);
	assert r.indexOf("\"line\":0") >= 0;
	assert r.indexOf("\"line\":1") >= 0;
}

test "returns symbols for file" {
	const db = testDb("file:///test.ms", "function foo() { return 1; }\nconst x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = handleDocumentSymbol("20", params, db);
	assert lspGetNumberField(r, "id") == 20;
	assert r.length > 60;
}

test "outline carries struct, macro and test blocks" {
	const src = "struct P { x: int32; }\nmacro twice(a: int32): int32 { return a; }\ntest \"it works\" { assert 1 === 1; }";
	const db = testDb("file:///outline.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///outline.ms\"}}";
	const r = handleDocumentSymbol("23", params, db);
	assert r.indexOf("\"kind\":23") >= 0;
	assert r.indexOf("\"name\":\"twice\"") >= 0;
	assert r.indexOf("\"name\":\"it works\"") >= 0;
}

test "unknown doc returns empty array" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"}}";
	const r = handleDocumentSymbol("21", params, db);
	assert lspGetNumberField(r, "id") == 21;
}

test "dispatch routes correctly" {
	const db = testDb("file:///test.ms", "const a = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = lspDispatch("textDocument/documentSymbol", "22", params, db, testCache());
	assert lspGetNumberField(r, "id") == 22;
	assert r.length > 0;
}

test "returns signature for function" {
	const db = testDb("file:///test.ms", "function greet(name: string): void { }\ngreet(");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":6}}";
	const r = handleSignatureHelp("30", params, db);
	assert lspGetNumberField(r, "id") == 30;
	assert r.length > 0;
}

test "unknown doc returns null sig" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleSignatureHelp("31", params, db);
	assert lspGetNumberField(r, "id") == 31;
}

test "dispatch routes sig help" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = lspDispatch("textDocument/signatureHelp", "32", params, db, testCache());
	assert lspGetNumberField(r, "id") == 32;
}

test "signature help picks matching enum-literal overload" {
	// Three signatures: K.A, K.B, and the wide impl. Calling f(K.B) should
	// pick the K.B signature (activeSignature=1 — primary is K.A at index 0).
	const src = "enum K { A, B }\n"
		+ "function f(k: K.A): string;\n"
		+ "function f(k: K.B): string;\n"
		+ "function f(k: K): string { return \"\"; }\n"
		+ "const x = f(K.B);\n";
	const db = testDb("file:///ovlsig.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///ovlsig.ms\"},\"position\":{\"line\":4,\"character\":16}}";
	const r = handleSignatureHelp("40", params, db);
	assert lspGetNumberField(r, "id") == 40;
	assert r.indexOf("\"activeSignature\":1", 0) >= 0;
}

test "phase 5: sig help narrows on object literal arg via Pass-2 commit" {
	// Two-pass overload resolution: arg[0] = K.B EnumLiteral discriminates
	// between the two specific overloads, and Pass 2 re-checks the context-
	// sensitive object literal against the winner's struct param. Sig help
	// should report activeSignature=1 (the K.B overload) while the cursor
	// is inside the {} literal.
	const src = "enum K { A, B }\n"
		+ "function g(k: K.A, d: { x: number }): number;\n"
		+ "function g(k: K.B, d: { y: string }): number;\n"
		+ "function g(k: K, d: { x: number } | { y: string }): number { return 0; }\n"
		+ "const r = g(K.B, { y: \"hi\" });\n";
	const db = testDb("file:///phase5sig.ms", src);
	// Cursor inside the `{` object literal at line 4 (0-indexed), after "{ "
	const params = "{\"textDocument\":{\"uri\":\"file:///phase5sig.ms\"},\"position\":{\"line\":4,\"character\":20}}";
	const r = handleSignatureHelp("41", params, db);
	assert lspGetNumberField(r, "id") == 41;
	assert r.indexOf("\"activeSignature\":1", 0) >= 0;
}

// ===== Phase 5/6 end-to-end on real example files =====

function loadExample(relPath: string): string {
	const r = readFile(relPath);
	return r.ok ? r.value : "";
}

// An example file is "clean" if its diagnostics contain no error-severity
// entries (severity 1). Format-violation hints (severity 4) are emitted
// because testDb doesn't load the project's build.ms which sets useTabs=true,
// so the default useTabs=false flags our tab-indented examples. Those are
// cosmetic and unrelated to Phase 5/6 narrowing correctness.
function hasNoErrors(diags: string): boolean {
	return diags.indexOf("\"severity\":1", 0) < 0;
}

test "phase 5: src/test/fixtures/lsp/phase5Overloads.ms type-checks cleanly" {
	const src = loadExample("src/test/fixtures/lsp/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5ovl.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "phase 6: src/test/fixtures/lsp/phase6AliasedCond.ms type-checks cleanly" {
	const src = loadExample("src/test/fixtures/lsp/phase6AliasedCond.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase6alias.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "phase 6: src/test/fixtures/lsp/phase6Assignment.ms type-checks cleanly" {
	const src = loadExample("src/test/fixtures/lsp/phase6Assignment.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase6assign.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "phase 6: src/test/fixtures/lsp/phase6TypePredicate.ms type-checks cleanly" {
	const src = loadExample("src/test/fixtures/lsp/phase6TypePredicate.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase6pred.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "outline: src/test/fixtures/lsp/outlineKinds.ms type-checks cleanly" {
	const src = loadExample("src/test/fixtures/lsp/outlineKinds.ms");
	assert src.length > 0;
	const uri = "file:///ex-outline.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "outline: src/test/fixtures/lsp/outlineKinds.ms reports every decl kind" {
	const src = loadExample("src/test/fixtures/lsp/outlineKinds.ms");
	assert src.length > 0;
	const uri = "file:///ex-outline2.ms";
	const db = testDb(uri, src);
	const params = "{\"textDocument\":{\"uri\":\"" + uri + "\"}}";
	const r = handleDocumentSymbol("24", params, db);
	assert r.indexOf("\"name\":\"Vec2\"") >= 0;
	assert r.indexOf("\"name\":\"puts\"") >= 0;
	assert r.indexOf("\"name\":\"twice\"") >= 0;
	assert r.indexOf("\"name\":\"x\"") >= 0;
	assert r.indexOf("\"name\":\"scale doubles both axes\"") >= 0;
}

test "phase 5: sig help on src/test/fixtures/lsp/phase5Overloads.ms narrows to Square" {
	// Inside `area(Kind.Square, { side: 5 })` the cursor inside the object
	// literal should report activeSignature = 1 (Square is the 2nd specific
	// overload; Circle is 0). Line 30 (0-indexed) col 32 — just after `{ `.
	const src = loadExample("src/test/fixtures/lsp/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5ovlsig.ms";
	const db = testDb(uri, src);
	const params = "{\"textDocument\":{\"uri\":\"file:///ex-phase5ovlsig.ms\"},\"position\":{\"line\":30,\"character\":32}}";
	const r = handleSignatureHelp("100", params, db);
	assert lspGetNumberField(r, "id") == 100;
	assert r.indexOf("\"activeSignature\":1", 0) >= 0;
}

// ===== Phase 5 hover: overload-aware callee signature =====
//
// Regression guard for the "hover on `area(Kind.Square, ...)` shows Circle"
// bug. Root cause: the symRecord for the callee identifier points at the
// PRIMARY sym (so find-references sees every call site). Hover for an
// overloaded call needs the RESOLVED overload's sig, which is stored on
// the CallExpr's `resolvedOverloadIdx`. handleHover walks the AST to find
// the enclosing CallExpr and substitutes the winning overload's type.
//
// Position coordinates are 0-indexed LSP — the phase5Overloads.ms source
// uses tabs so `area` starts at column 11 (tab + "const s = " = 11 chars).

test "phase 5 hover: Kind.Circle call shows Circle overload" {
	const src = loadExample("src/test/fixtures/lsp/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5hovC.ms";
	const db = testDb(uri, src);
	// Line 26 col 11: `\tconst c = area(Kind.Circle, { radius: 4 });`
	const params = "{\"textDocument\":{\"uri\":\"file:///ex-phase5hovC.ms\"},\"position\":{\"line\":26,\"character\":11}}";
	const r = handleHover("200", params, db);
	assert lspGetNumberField(r, "id") == 200;
	assert r.indexOf("Kind.Circle", 0) >= 0;
	assert r.indexOf("radius", 0) >= 0;
}

test "phase 5 hover: Kind.Square call shows Square overload" {
	const src = loadExample("src/test/fixtures/lsp/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5hovS.ms";
	const db = testDb(uri, src);
	// Line 30 col 11: `\tconst s = area(Kind.Square, { side: 5 });`
	const params = "{\"textDocument\":{\"uri\":\"file:///ex-phase5hovS.ms\"},\"position\":{\"line\":30,\"character\":11}}";
	const r = handleHover("201", params, db);
	assert lspGetNumberField(r, "id") == 201;
	assert r.indexOf("Kind.Square", 0) >= 0;
	assert r.indexOf("side", 0) >= 0;
	// Negative assertion: must NOT surface the Circle variant any more.
	assert r.indexOf("Kind.Circle", 0) < 0;
}

test "phase 5 hover: Kind.Line call shows Line overload" {
	const src = loadExample("src/test/fixtures/lsp/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5hovL.ms";
	const db = testDb(uri, src);
	// Line 34 col 11: `\tconst l = area(Kind.Line, { length: 10 });`
	const params = "{\"textDocument\":{\"uri\":\"file:///ex-phase5hovL.ms\"},\"position\":{\"line\":34,\"character\":11}}";
	const r = handleHover("202", params, db);
	assert lspGetNumberField(r, "id") == 202;
	assert r.indexOf("Kind.Line", 0) >= 0;
	assert r.indexOf("length", 0) >= 0;
}

test "phase 5 hover: runtime kind shows wide impl" {
	// Opposite direction: when overload resolution picks the wide impl
	// (runtime Kind value, not an EnumLiteral), hover must show the wide
	// signature — NOT a specific variant.
	const src = loadExample("src/test/fixtures/lsp/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5hovR.ms";
	const db = testDb(uri, src);
	// Line 40 col 11: `\tconst r = area(runtime, runtimeData);`
	const params = "{\"textDocument\":{\"uri\":\"file:///ex-phase5hovR.ms\"},\"position\":{\"line\":40,\"character\":11}}";
	const r = handleHover("203", params, db);
	assert lspGetNumberField(r, "id") == 203;
	// Wide impl: `area(k: Kind, ...)` — Kind without a member-access dot.
	// Must NOT show `Kind.Circle` / `Kind.Square` / `Kind.Line`.
	assert r.indexOf("Kind.Circle", 0) < 0;
	assert r.indexOf("Kind.Square", 0) < 0;
	assert r.indexOf("Kind.Line", 0) < 0;
	// Should mention `k: Kind` (with a param label before it).
	assert r.indexOf("Kind", 0) >= 0;
}

test "phase 5 hover: identifier-as-value falls back to primary" {
	// `const f = area;` — hovering on `area` here has no enclosing CallExpr
	// whose callee is this position. Hover must fall back to the primary
	// (first-declared overload — Circle here), matching goto-def semantics
	// for the declaration target. This is the degenerate case that the
	// CallExpr walk is designed to skip cleanly via returning null.
	const src = "enum K { A, B }\n"
		+ "function g(k: K.A): number;\n"
		+ "function g(k: K.B): number;\n"
		+ "function g(k: K): number { return 0; }\n"
		+ "const f = g;\n";
	const uri = "file:///ex-ovlvalue.ms";
	const db = testDb(uri, src);
	// Line 4 col 10: position of `g` in `const f = g;` (0-indexed: tab=0, c=0 nope — no tab here).
	// `const f = g;` — c=0 o=1 n=2 s=3 t=4 space=5 f=6 space=7 ==8 space=9 g=10.
	const params = "{\"textDocument\":{\"uri\":\"file:///ex-ovlvalue.ms\"},\"position\":{\"line\":4,\"character\":10}}";
	const r = handleHover("204", params, db);
	assert lspGetNumberField(r, "id") == 204;
	// Falls back to the primary sig (K.A, declared first).
	assert r.indexOf("K.A", 0) >= 0;
}

test "type hint for untyped var" {
	const db = testDb("file:///test.ms", "const x = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("40", params, db);
	assert lspGetNumberField(r, "id") == 40;
	assert r.length > 50;
}

test "empty for unknown doc" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("41", params, db);
	assert lspGetNumberField(r, "id") == 41;
}

test "dispatch inlay hint" {
	const db = testDb("file:///test.ms", "const y = true;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = lspDispatch("textDocument/inlayHint", "42", params, db, testCache());
	assert lspGetNumberField(r, "id") == 42;
}

test "array size hint: inferred type shows string[4]" {
	const db = testDb("file:///test.ms", "const a = new Array<string>(4);");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("43", params, db);
	assert r.indexOf("string[4]") >= 0;
}

test "array size hint: annotated type shows string[8] trailing" {
	const db = testDb("file:///test.ms", "const e: string[] = new Array(8);");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("44", params, db);
	assert r.indexOf("string[8]") >= 0;
}

test "no array size hint for empty new Array<T>()" {
	const db = testDb("file:///test.ms", "const a = new Array<string>();");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("45", params, db);
	assert r.indexOf("string[]") >= 0;
}

// Padding rules: Type hints have NO paddingLeft (label `: T` follows the
// identifier whose source already ends with a separator). Exception hints DO
// have paddingLeft (separate `throws E` from preceding `try` keyword or name).
// Parameter hints have paddingRight (separate `name:` from following arg).
test "type hint has no paddingLeft, no paddingRight" {
	const db = testDb("file:///test.ms", "const x = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("46", params, db);
	// JSON should contain `"paddingLeft":false` and `"paddingRight":false`
	assert r.indexOf("\"paddingLeft\":false") >= 0;
	assert r.indexOf("\"paddingRight\":false") >= 0;
}

test "parameter hint has paddingRight, no paddingLeft" {
	const db = testDb("file:///test.ms", "function foo(name: number): void {}\nfoo(42);");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("47", params, db);
	// At least one hint with kind=2 (Parameter) should have paddingRight=true
	assert r.indexOf("\"label\":\"name:\"") >= 0;
	assert r.indexOf("\"paddingRight\":true") >= 0;
}

test "exception hint has paddingLeft" {
	const db = testDb("file:///test.ms", "function f(s: string) { return Result.ok(1) as Result<number, string>; }");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("48", params, db);
	// Exception hint label starts with "throws " — verify it's present and padded
	assert r.indexOf("\"label\":\"throws ") >= 0;
	assert r.indexOf("\"paddingLeft\":true") >= 0;
}

test "try-expr in var-decl produces no duplicate hints (real pipeline)" {
	// Real-pipeline regression guard for VSCode duplicate-hint reports.
	// Source mirrors std/fs/index.cms readLines shape.
	const src = "import { Result } from \"std/core/system\";\n"
		+ "interface IoError { msg: string; }\n"
		+ "function readFile(p: string): Result<string, IoError> { return Result.ok(\"\"); }\n"
		+ "export function readLines(path: string): Result<string[], IoError> {\n"
		+ "\tconst content = try readFile(path);\n"
		+ "\treturn Result.ok([]);\n"
		+ "}";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":20,\"character\":0}}}";
	const r = handleInlayHint("60", params, db);
	let stringHintCount = 0;
	let throwsHintCount = 0;
	let i = 0;
	while (i < r.length) {
		const idx = r.indexOf("\"label\":\": string\"", i);
		if (idx < 0) break;
		stringHintCount = stringHintCount + 1;
		i = idx + 1;
	}
	i = 0;
	while (i < r.length) {
		const idx = r.indexOf("\"label\":\"throws IoError\"", i);
		if (idx < 0) break;
		throwsHintCount = throwsHintCount + 1;
		i = idx + 1;
	}
	assert stringHintCount == 1;
	assert throwsHintCount == 1;
}

test "finds all references to a variable" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst def = abc + 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleReferences("50", params, db);
	assert lspGetNumberField(r, "id") == 50;
	assert r.length > 60;
}

test "unknown doc returns empty refs" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleReferences("51", params, db);
	assert lspGetNumberField(r, "id") == 51;
}

test "dispatch routes refs" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/references", "52", params, db, testCache());
	assert lspGetNumberField(r, "id") == 52;
}

test "renames variable occurrences" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst def = abc + 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"xyz\"}";
	const r = handleRename("60", params, db);
	assert lspGetNumberField(r, "id") == 60;
	assert r.length > 60;
}

test "unknown doc returns null rename" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0},\"newName\":\"xyz\"}";
	const r = handleRename("61", params, db);
	assert lspGetNumberField(r, "id") == 61;
}

test "empty newName returns null" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleRename("62", params, db);
	assert lspGetNumberField(r, "id") == 62;
}

test "dispatch routes rename" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"y\"}";
	const r = lspDispatch("textDocument/rename", "63", params, db, testCache());
	assert lspGetNumberField(r, "id") == 63;
}

test "Trans-Am cache hit on comment-only change" {
	const db = createTransAmDb(100);
	const path = "/test.ms";
	dbSetFileText(db, path, "const x = 1;");
	const ctx1 = dbTypeCheck(db, path);
	assert ctx1 != null;
	assert db.revision.value == 1;
	dbSetFileText(db, path, "const x = 1; // comment");
	assert db.revision.value == 2;
	const ctx2 = dbTypeCheck(db, path);
	assert ctx2 != null;
}

// ===== Phase 5 Integration Tests =====

function didOpenParams(uri: string, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"languageId":"metascript","version":1,"text":${lspJsonString(text)}}}`;
}

function didChangeParams(uri: string, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"version":2},"contentChanges":[{"text":${lspJsonString(text)}}]}`;
}

test "didChange publishes diagnostics post-drain" {
	const uri = "file:///test.ms";
	const db = createTransAmDb(100);
	handleDidOpen(didOpenParams(uri, "const x = 1;"), db);
	handleDidChange(didChangeParams(uri, "const x = 1;\nconst y = 2;"), db);
	const diag = publishPendingDiagnostics(db);
	assert diag.indexOf("publishDiagnostics") >= 0;
	assert diag.indexOf(uri) >= 0;
}

function testDiagnosticItems(json: string, uri: string): JsonValue[] {
	const parsed = parseJson(json);
	if (!parsed.ok) throw new Error(parsed.error);
	const message = parsed.value;
	if (message.getDynamicField("jsonrpc").asString() != "2.0"
		|| message.getDynamicField("method").asString() != "textDocument/publishDiagnostics") {
		throw new Error("Expected publishDiagnostics: " + json);
	}
	const params = message.getDynamicField("params");
	if (params.getDynamicField("uri").asString() != uri) throw new Error("Wrong diagnostics URI: " + json);
	const diagnostics = params.getDynamicField("diagnostics");
	if (diagnostics.kind != JsonKind.Array) throw new Error("Expected diagnostics array: " + json);
	return diagnostics.items;
}

function testPublishedItems(wire: string, uri: string): JsonValue[] {
	let remaining = wire;
	let found = false;
	let items: JsonValue[] = [];
	while (remaining.byteLength > 0) {
		const headerEnd = remaining.indexOf("\r\n\r\n");
		if (headerEnd < 0) throw new Error("Missing diagnostics frame header");
		const size = lspParseContentLength(remaining.byteSlice(0, headerEnd));
		const bodyStart = headerEnd + 4;
		if (size < 0 || bodyStart + size > remaining.byteLength) throw new Error("Invalid diagnostics frame length");
		const json = remaining.byteSlice(bodyStart, bodyStart + size);
		if (lspGetField(json, "uri") == uri) {
			if (found) throw new Error("Duplicate diagnostics notification: " + uri);
			items = testDiagnosticItems(json, uri);
			found = true;
		}
		remaining = remaining.byteSlice(bodyStart + size, remaining.byteLength);
	}
	if (!found) throw new Error("Missing diagnostics notification: " + uri);
	return items;
}

test "didChange with error then fix clears diagnostics" {
	const uri = "file:///lsp-clear.ms";
	const db = createTransAmDb(100);
	const before = testDiagnosticItems(handleDidOpen(didOpenParams(uri, "export const value: int32 = \"wrong\";"), db), uri);
	assert before.length == 1;
	assert before[0].getDynamicField("message").asString() == "Type 'string' is not assignable to type 'int32'";
	assert before[0].getDynamicField("severity").asInt32(-1) == 1;
	assert before[0].getDynamicField("source").asString() == "metascript";
	handleDidChange(didChangeParams(uri, "export const value: int32 = 42;"), db);
	assert testPublishedItems(publishPendingDiagnostics(db), uri).length == 0;
	assert publishPendingDiagnostics(db) == "";
}

test "didChange publishes a new error after clearing the previous one" {
	const uri = "file:///lsp-clear-again.ms";
	const db = createTransAmDb(100);
	assert testDiagnosticItems(handleDidOpen(didOpenParams(uri, "export const value: int32 = true;"), db), uri).length == 1;
	handleDidChange(didChangeParams(uri, "export const value: int32 = 42;"), db);
	assert testPublishedItems(publishPendingDiagnostics(db), uri).length == 0;
	handleDidChange(didChangeParams(uri, "export const value: int32 = \"wrong\";"), db);
	const after = testPublishedItems(publishPendingDiagnostics(db), uri);
	assert after.length == 1;
	assert after[0].getDynamicField("message").asString() == "Type 'string' is not assignable to type 'int32'";
}

test "multi-file: edit B updates A diagnostics" {
	const db = createTransAmDb(100);
	const depUri = "file:///lsp-import/b.ms";
	const uri = "file:///lsp-import/a.ms";
	const good = "export function foo(): int32 { return 1; }";
	handleDidOpen(didOpenParams(depUri, good), db);
	assert testDiagnosticItems(handleDidOpen(didOpenParams(uri, "import { foo } from \"./b\";\nexport const x: int32 = foo();"), db), uri).length == 0;
	handleDidChange(didChangeParams(depUri, "export function foo(): string { return \"wrong\"; }"), db);
	const after = testPublishedItems(publishPendingDiagnostics(db), uri);
	assert after.length == 1;
	assert after[0].getDynamicField("message").asString() == "Type 'string' is not assignable to type 'int32'";
	assert after[0].getDynamicField("severity").asInt32(-1) == 1;
	handleDidChange(didChangeParams(depUri, good), db);
	assert testPublishedItems(publishPendingDiagnostics(db), uri).length == 0;
}

test "cancelled type check is not cached and retry checks the same text" {
	const db = createTransAmDb(100);
	const path = "/lsp-cancel.ms";
	const uri = "file:///lsp-cancel.ms";
	dbSetFileText(db, path, "export const value: int32 = \"wrong\";");
	requestCancel(db.cancelCtx);
	dbTypeCheck(db, path);
	assert !dbCheckIsCurrent(db, path);
	assert db.depStack.frames.length == 0;
	assert !db.checkInProgress.has(path);
	resetCancel(db.cancelCtx);
	const diagnostics = testDiagnosticItems(lspNotification("textDocument/publishDiagnostics", buildDiagnosticsJson(uri, db, path)), uri);
	assert diagnostics.length == 1;
	assert diagnostics[0].getDynamicField("message").asString() == "Type 'string' is not assignable to type 'int32'";
	assert dbCheckIsCurrent(db, path);
}

function stopAtProbe(db: TransAmDb, probe: int32): int32[] {
	const probes: int32[] = [0];
	db.cancelCtx.inputPending = () => {
		probes[0] += 1;
		return probes[0] == probe;
	};
	return probes;
}

const STOP_SOURCE = "const a = 1;\nconst b = a;\nexport const value: int32 = \"wrong\";";
const STOP_HOVER = "{\"textDocument\":{\"uri\":\"file:///lsp-stop.ms\"},\"position\":{\"line\":2,\"character\":14}}";

test "a check stopped for input at a top-level statement is not cached and the re-run matches an uninterrupted check" {
	const uri = "file:///lsp-stop.ms";
	const path = "/lsp-stop.ms";
	const fresh = createTransAmDb(100);
	dbSetFileText(fresh, path, STOP_SOURCE);
	const wanted = buildDiagnosticsJson(uri, fresh, path);
	const wantedHover = handleHover("1", STOP_HOVER, fresh);
	const db = createTransAmDb(100);
	dbSetFileText(db, path, STOP_SOURCE);
	const probes = stopAtProbe(db, 3);
	dbTypeCheck(db, path);
	assert probes[0] == 3;
	assert db.cancelCtx.stoppedForInput;
	assert !dbCheckIsCurrent(db, path);
	assert db.depStack.frames.length == 0;
	assert !db.checkInProgress.has(path);
	resetCancel(db.cancelCtx);
	db.cancelCtx.inputPending = null;
	assert buildDiagnosticsJson(uri, db, path) == wanted;
	assert handleHover("1", STOP_HOVER, db) == wantedHover;
	assert dbCheckIsCurrent(db, path);
}

test "a check stopped for input leaves the module context of the last finished check registered" {
	const path = "/lsp-stop-ctx.ms";
	const db = createTransAmDb(100);
	dbSetFileText(db, path, STOP_SOURCE);
	dbTypeCheck(db, path);
	const finished = lookupModuleCtx(path);
	assert finished != null;
	dbSetFileText(db, path, STOP_SOURCE + "\nexport const more = 1;");
	stopAtProbe(db, 2);
	dbTypeCheck(db, path);
	assert db.cancelCtx.stoppedForInput;
	assert lookupModuleCtx(path) == finished;
}

test "a check stopped for input registers no module context for a module never checked before" {
	const path = "/lsp-stop-first.ms";
	const db = createTransAmDb(100);
	dbSetFileText(db, path, STOP_SOURCE);
	stopAtProbe(db, 2);
	dbTypeCheck(db, path);
	assert db.cancelCtx.stoppedForInput;
	assert lookupModuleCtx(path) == null;
}

test "diagnostics stopped for input stay pending and publish the same once input is read" {
	const uri = "file:///lsp-stop-pending.ms";
	const db = createTransAmDb(100);
	handleDidOpen(didOpenParams(uri, "export const value: int32 = 1;"), db);
	handleDidChange(didChangeParams(uri, STOP_SOURCE), db);
	stopAtProbe(db, 2);
	assert publishPendingDiagnostics(db) == "";
	assert db.cancelCtx.stoppedForInput;
	resetCancel(db.cancelCtx);
	db.cancelCtx.inputPending = null;
	const items = testPublishedItems(publishPendingDiagnostics(db), uri);
	assert items.length == 1;
	assert items[0].getDynamicField("message").asString() == "Type 'string' is not assignable to type 'int32'";
	assert publishPendingDiagnostics(db) == "";
}

test "position-only edits preserve UTF-16 diagnostic spans through undo" {
	const db = createTransAmDb(100);
	const uri = "file:///lsp-position.ms";
	const source = "export const value: int32 = \"wrong\";";
	assert testDiagnosticItems(handleDidOpen(didOpenParams(uri, source), db), uri).length == 1;
	const prefixes = [
		"\n", "\r\n\r\n", "\n// moved\n", "", "/*a*/ ", "/*é*/ ",
		"/*😀*/ ", "\n/*é*/ ", "\r\n\r\n/*😀*/ ", "",
	];
	const lines = [1, 2, 2, 0, 0, 0, 0, 1, 2, 0];
	const characters = [28, 28, 28, 28, 34, 34, 35, 34, 35, 28];
	for (let i = 0; i < prefixes.length; i += 1) {
		const text = prefixes[i] + source;
		handleDidChange(didChangeParams(uri, text), db);
		const warm = testPublishedItems(publishPendingDiagnostics(db), uri);
		assert warm.length == 1;
		const cold = testDiagnosticItems(handleDidOpen(didOpenParams(uri, text), createTransAmDb(100)), uri);
		assert cold.length == 1;
		for (const diagnostic of [warm[0], cold[0]]) {
			assert diagnostic.getDynamicField("message").asString()
				== "Type 'string' is not assignable to type 'int32'";
			assert diagnostic.getDynamicField("severity").asInt32(-1) == 1;
			assert diagnostic.getDynamicField("source").asString() == "metascript";
			const range = diagnostic.getDynamicField("range");
			const start = range.getDynamicField("start");
			const end = range.getDynamicField("end");
			assert start.getDynamicField("line").asInt32(-1) == lines[i];
			assert start.getDynamicField("character").asInt32(-1) == characters[i];
			assert end.getDynamicField("line").asInt32(-1) == lines[i];
			assert end.getDynamicField("character").asInt32(-1) == characters[i] + 1;
		}
	}
}

function utf16Span(item: string): string {
	const range = lspGetObjectField(item, "range");
	const start = lspGetObjectField(range, "start");
	const end = lspGetObjectField(range, "end");
	if (lspGetNumberField(start, "line") != lspGetNumberField(end, "line")) return "multiline:" + range;
	return (lspGetNumberField(start, "line") as int32) + ":" + (lspGetNumberField(start, "character") as int32)
		+ "-" + (lspGetNumberField(end, "character") as int32);
}

function utf16SpansMatch(label: string, items: string[], expected: string[]): boolean {
	const spans: string[] = [];
	for (const item of items) spans.push(utf16Span(item));
	let matched = spans.length == expected.length;
	for (const span of expected) {
		if (spans.indexOf(span) < 0) matched = false;
	}
	if (!matched) writeStderr(label + ": expected " + expected.join(",") + " got " + spans.join(",") + "\n");
	return matched;
}

test "queries read and answer UTF-16 positions after non-ASCII text" {
	const prefixes = ["", "/*é*/ ", "/*😀*/ ", "/*é*/\n/*😀*/ ", "/*é*/\r\n/*😀*/ ", ""];
	const gaps = ["", "", "", "", "", "/*é😀*/ "];
	const lines = [0, 0, 0, 1, 1, 0];
	const declarations = [6, 12, 13, 13, 13, 6];
	const uses = [23, 29, 30, 30, 30, 31];
	const uri = "file:///query-utf16.ms";
	for (let i = 0; i < prefixes.length; i++) {
		const db = testDb(uri, prefixes[i] + "const s = 1; " + gaps[i] + "const t = s;");
		const decl = lines[i] + ":" + declarations[i] + "-" + (declarations[i] + 1);
		const use = lines[i] + ":" + uses[i] + "-" + (uses[i] + 1);
		const params = "{\"textDocument\":{\"uri\":" + lspJsonString(uri) + "},\"position\":{\"line\":"
			+ lines[i] + ",\"character\":" + uses[i] + "}";
		const label = "utf16 case " + i;
		assert utf16SpansMatch(label + " definition", lspGetArrayItems(lspGetObjectField(handleDefinition("80", params + "}", db), "result")), [decl]);
		assert utf16SpansMatch(label + " hover", [lspGetObjectField(handleHover("81", params + "}", db), "result")], [use]);
		assert utf16SpansMatch(label + " references", lspGetArrayItems(lspGetObjectField(handleReferences("82", params + "}", db), "result")), [decl, use]);
		assert utf16SpansMatch(label + " highlight", lspGetArrayItems(lspGetObjectField(handleDocumentHighlight("83", params + "}", db), "result")), [decl, use]);
		const rename = handleRename("84", params + ",\"newName\":\"v\"}", db);
		const edits = lspGetArrayItems(lspGetObjectField(lspGetObjectField(lspGetObjectField(rename, "result"), "changes"), uri));
		assert utf16SpansMatch(label + " rename", edits, [decl, use]);
		for (const edit of edits) assert lspGetField(edit, "newText") == "v";
	}
}

test "semantic UTF-16 deltas survive prefix and gap edits and undo" {
	const initialized = parseJson(handleInitialize("71"));
	assert initialized.ok;
	if (initialized.ok) {
		const legend = initialized.value.getDynamicField("result")
			.getDynamicField("capabilities").getDynamicField("semanticTokensProvider")
			.getDynamicField("legend");
		const types = legend.getDynamicField("tokenTypes");
		const modifiers = legend.getDynamicField("tokenModifiers");
		if (types.kind != JsonKind.Array) throw new Error("Expected semantic token types");
		if (modifiers.kind != JsonKind.Array) throw new Error("Expected semantic token modifiers");
		assert types.items.length > 8;
		assert modifiers.items.length > 2;
		assert types.items[8].asString() == "variable";
		assert modifiers.items[0].asString() == "declaration";
		assert modifiers.items[2].asString() == "readonly";
	}
	const db = createTransAmDb(100);
	const path = "/semantic-token-utf16.ms";
	const uri = "file:///semantic-token-utf16.ms";
	const params = "{\"textDocument\":{\"uri\":" + lspJsonString(uri) + "}}";
	const prefixes = [
		"", "/*a*/ ", "/*é*/ ", "/*😀*/ ", "\n/*é*/ ", "\r\n\r\n/*😀*/ ", "", "", "",
	];
	const gaps = ["", "", "", "", "", "", "/*é*/ ", "/*😀*/ ", ""];
	const lines = [0, 0, 0, 0, 1, 2, 0, 0, 0];
	const characters = [6, 12, 12, 13, 12, 13, 6, 6, 6];
	const deltas = [17, 17, 17, 17, 17, 17, 23, 24, 17];
	for (let i = 0; i < prefixes.length; i++) {
		const source = prefixes[i] + "const first = 1; " + gaps[i] + "const second = first;";
		assert dbSetFileText(db, path, source);
		const response = handleSemanticTokensFull("71", params, db);
		assert dbTypeCheck(db, path).errors.length == 0;
		const parsed = parseJson(response);
		assert parsed.ok;
		if (parsed.ok) {
			assert parsed.value.getDynamicField("jsonrpc").asString() == "2.0";
			assert parsed.value.getDynamicField("id").asInt32(-1) == 71;
			const data = parsed.value.getDynamicField("result").getDynamicField("data");
			if (data.kind != JsonKind.Array) throw new Error("Expected semantic token data");
			const expected = [
				lines[i], characters[i], 5, 8, 5,
				0, deltas[i], 6, 8, 5,
				0, 9, 5, 8, 4,
			];
			assert data.items.length == expected.length;
			for (let j = 0; j < expected.length; j++) {
				assert data.items[j].asInt32(-1) == expected[j];
			}
		}
		assert handleSemanticTokensFull("71", params, db) == response;
		const revision = db.revision.value;
		assert !dbSetFileText(db, path, source);
		assert db.revision.value == revision;
		assert handleSemanticTokensFull("71", params, db) == response;
	}
}

const RECHECK_SOURCE = "import { Result } from \"std/core/system\";\n"
	+ "import { bump } from \"./dep\";\n"
	+ "function foo(x: number): number { return bump(x) + 1; }\nconst y = foo(42);";

function recheckDb(dir: string): TransAmDb {
	const db = testDb(`file://${dir}/test.ms`, RECHECK_SOURCE);
	dbSetFileText(db, `${dir}/dep.ms`, "export function bump(x: number): number { return x + 1; }");
	const user = getFileId(db.fileInput, `${dir}/test.ms`);
	recordModuleImport(db.moduleDeps, user, getFileId(db.fileInput, `${dir}/dep.ms`));
	return db;
}

function bindWork(db: TransAmDb): string {
	return `bound=${db.cache.bound} collected=${db.cache.collected}`;
}

function recomputedSince(db: TransAmDb, revision: int32): string[] {
	const keys: string[] = [];
	for (const entry of db.cache.entries) {
		if (entry.computedAt < revision) continue;
		const path = getFilePath(db.fileInput, entry.key.fileId);
		keys.push(`${entry.key.queryKind.toString()} ${path}`);
	}
	return keys;
}

function recomputeCount(db: TransAmDb): int32 {
	let total = 0;
	for (const count of db.cache.recomputed) total += count;
	return total;
}

function checkedType(db: TransAmDb, path: string, name: string): string {
	const ctx = dbTypeCheck(db, path);
	if (ctx.errors.length > 0) return `${ctx.errors.length} errors`;
	const sym = lookupLocal(ctx.table, name);
	return sym != null ? typeDisplayName(sym.symbolType) : "";
}

test "a fresh check computes each query of the file and its import once" {
	const db = recheckDb("/fresh");
	assert checkedType(db, "/fresh/test.ms", "y") == "number";
	const recomputed = recomputedSince(db, 0).join(",");
	const expected = "Preprocess /fresh/test.ms,Parse /fresh/test.ms,Preprocess /fresh/dep.ms,Parse /fresh/dep.ms"
		+ ",TypeCheck /fresh/test.ms";
	assert recomputed == expected, recomputed;
	assert recomputeCount(db) == 5;
	assert bindWork(db) == "bound=2 collected=1", bindWork(db);
}

test "re-checking a body edit recomputes only the edited file's parse and check" {
	const path = "/body/test.ms";
	const db = recheckDb("/body");
	assert checkedType(db, path, "y") == "number";
	const entries = db.cache.entries.length;
	const bound = db.cache.bound;
	const collected = db.cache.collected;
	assert dbSetFileText(db, path, RECHECK_SOURCE.replace("bump(x) + 1", "bump(x) + 2"));
	const revision = db.revision.value;
	const before = recomputeCount(db);
	assert checkedType(db, path, "y") == "number";
	const recomputed = recomputedSince(db, revision);
	const expected = `Preprocess ${path},Parse ${path},TypeCheck ${path}`;
	assert recomputed.join(",") == expected, recomputed.join(",");
	assert recomputeCount(db) - before == 3;
	assert db.cache.entries.length == entries;
	assert db.cache.bound - bound == 1 && db.cache.collected - collected == 0, bindWork(db);
	const hits = db.cache.hits;
	const ctx = dbTypeCheck(db, path);
	assert dbTypeCheck(db, path) == ctx;
	assert db.cache.hits - hits == 2;
	assert recomputeCount(db) - before == 3;
	assert db.cache.bound - bound == 1 && db.cache.collected - collected == 0, bindWork(db);
}

// util.ms is checked by another db, as the prelude db checks a build.ms global import;
// mid.ms imports it, and an edit elsewhere must leave mid.ms and its importer verified.
function heldImportDb(): TransAmDb {
	const util = "export function ut(x: number): number { return x; }";
	const other = createTransAmDb(100);
	dbSetFileText(other, "/held/util.ms", util);
	dbTypeCheck(other, "/held/util.ms");
	const db = testDb("file:///held/main.ms", "const z = 1;");
	dbSetFileText(db, "/held/util.ms", util);
	dbSetFileText(db, "/held/mid.ms", "import { ut } from \"./util\";\nexport const y = ut(1);");
	dbSetFileText(db, "/held/top.ms", "import { y } from \"./mid\";\nconst w = y;");
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/held/mid.ms"), getFileId(db.fileInput, "/held/util.ms"));
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, "/held/top.ms"), getFileId(db.fileInput, "/held/mid.ms"));
	return db;
}

test "an edit elsewhere leaves verified a module whose import another db checked" {
	const db = heldImportDb();
	assert checkedType(db, "/held/mid.ms", "y") == "number";
	assert dbSetFileText(db, "/held/main.ms", "const z = 2;");
	const before = recomputeCount(db);
	assert dbCheckIsCurrent(db, "/held/mid.ms");
	assert recomputeCount(db) == before;
}

test "an edit elsewhere leaves verified the importer of a module whose import another db checked" {
	const db = heldImportDb();
	assert checkedType(db, "/held/mid.ms", "y") == "number";
	assert checkedType(db, "/held/top.ms", "w") == "number";
	assert dbSetFileText(db, "/held/main.ms", "const z = 2;");
	assert dbCheckIsCurrent(db, "/held/top.ms");
}

// mid.ms imports dep.ms, which this db only binds, and dep.ms imports leaf.ms.
function boundImportDb(root: string): TransAmDb {
	const db = testDb(`file://${root}/main.ms`, "const z = 1;");
	dbSetFileText(db, `${root}/leaf.ms`, "export function base(x: number): number { return x; }");
	dbSetFileText(db, `${root}/dep.ms`, "import { base } from \"./leaf\";\nexport function bump(x: number) { return base(x); }");
	dbSetFileText(db, `${root}/mid.ms`, "import { bump } from \"./dep\";\nexport const y = bump(1);");
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, `${root}/mid.ms`), getFileId(db.fileInput, `${root}/dep.ms`));
	return db;
}

test "an edit elsewhere leaves verified a module whose import this db only binds" {
	const root = "/boundElsewhere";
	const db = boundImportDb(root);
	assert checkedType(db, `${root}/mid.ms`, "y") == "number";
	assert dbSetFileText(db, `${root}/main.ms`, "const z = 2;");
	const before = recomputeCount(db);
	assert dbCheckIsCurrent(db, `${root}/mid.ms`);
	assert recomputeCount(db) == before;
}

test "an edit below a bound import re-checks the module that reads it" {
	const root = "/boundBelow";
	const db = boundImportDb(root);
	assert checkedType(db, `${root}/mid.ms`, "y") == "number";
	assert dbSetFileText(db, `${root}/leaf.ms`, "export function base(x: number): string { return \"s\"; }");
	assert !dbCheckIsCurrent(db, `${root}/mid.ms`);
	assert checkedType(db, `${root}/mid.ms`, "y") == "string", checkedType(db, `${root}/mid.ms`, "y");
}

test "re-checking after an edit two imports down rebinds the unchanged import between" {
	const path = "/chain/test.ms";
	const db = testDb(`file://${path}`, "import { bump } from \"./dep\";\nconst y = bump(1);");
	dbSetFileText(db, "/chain/dep.ms", "import { base } from \"./leaf\";\nexport function bump(x: number) { return base(x); }");
	dbSetFileText(db, "/chain/leaf.ms", "export function base(x: number): number { return x; }");
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, path), getFileId(db.fileInput, "/chain/dep.ms"));
	assert checkedType(db, path, "y") == "number";
	assert dbSetFileText(db, path, "import { bump } from \"./dep\";\nconst y = bump(2);");
	assert checkedType(db, path, "y") == "number";
	assert dbSetFileText(db, "/chain/leaf.ms", "export function base(x: number): string { return \"s\"; }");
	assert checkedType(db, path, "y") == "string", checkedType(db, path, "y");
}

test "re-checking an importer after a dependency body edit reuses the importer's parse" {
	const dep = "/recheck/dep.ms";
	const user = "/recheck/user.ms";
	const db = createTransAmDb(100);
	dbSetFileText(db, dep, "export function one(): int32 { return 1; }");
	dbSetFileText(db, user, "import { one } from \"./dep\";\nexport const n = one();");
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, user), getFileId(db.fileInput, dep));
	dbParse(db, dep);
	assert checkedType(db, user, "n") == "int32";
	assert bindWork(db) == "bound=2 collected=1", bindWork(db);
	const marked = db.cache.marked;
	assert dbSetFileText(db, dep, "export function one(): int32 { return 2; }");
	assert db.cache.marked - marked == 5;
	const revision = db.revision.value;
	const before = recomputeCount(db);
	dbParse(db, dep);
	assert checkedType(db, user, "n") == "int32";
	const recomputed = recomputedSince(db, revision);
	const expected = `Preprocess ${dep},Parse ${dep},TypeCheck ${user}`;
	assert recomputed.join(",") == expected, recomputed.join(",");
	assert recomputeCount(db) - before == 3;
	const parseKey = createQueryKey(TaQueryKind.Parse, getFileId(db.fileInput, user));
	const userParse = cacheGet(db.cache, parseKey);
	assert userParse.computedAt < revision && userParse.verifiedAt == db.revision.value;
	assert bindWork(db) == "bound=4 collected=2", bindWork(db);
}

const DEP_WITH_PCT = "export struct Dice { seed: int32; }\nexport function pct(this dice: Dice, k: int32): int32 { return dice.seed + k; }\n";
const DEP_WITH_PERCENT = "export struct Dice { seed: int32; }\nexport function percent(this dice: Dice, k: int32): int32 { return dice.seed + k; }\n";
const USE_PERCENT = "import { Dice } from \"./dep\";\nexport function rollOnce(dice: Dice): int32 { return dice.percent(1); }\n";

const syncRunTag = String(Math.floor(Math.random() * 1000000000));

function syncTmpDir(name: string): string {
	const tmp = env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp";
	const dir = normalize(tmp + "/msc-lspsync-" + name + "-" + syncRunTag);
	mkdir(dir);
	return dir;
}

function syncOpenParams(path: string, text: string): string {
	return "{\"textDocument\":{\"uri\":" + lspJsonString(lspPathToUri(path))
		+ ",\"languageId\":\"metascript\",\"version\":1,\"text\":" + lspJsonString(text) + "}}";
}

function syncDocumentParams(path: string): string {
	return "{\"textDocument\":{\"uri\":" + lspJsonString(lspPathToUri(path)) + "}}";
}

function syncWatchedParams(path: string, changeType: int32): string {
	return "{\"changes\":[{\"uri\":" + lspJsonString(lspPathToUri(path)) + ",\"type\":" + changeType + "}]}";
}

function syncReportsMissingPercent(db: TransAmDb, path: string): boolean {
	return buildDiagnosticsJson(lspPathToUri(path), db, path).indexOf("'percent'") >= 0;
}

function syncReportsAnything(db: TransAmDb, path: string): boolean {
	return buildDiagnosticsJson(lspPathToUri(path), db, path).indexOf("\"message\"") >= 0;
}

test "a dependency changed on disk re-checks an open importer" {
	const dir = syncTmpDir("changed");
	const depPath = dir + "/dep.ms";
	const usePath = dir + "/use.ms";
	writeFile(depPath, DEP_WITH_PCT);
	writeFile(usePath, USE_PERCENT);
	const db = createTransAmDb(100);
	handleDidOpen(syncOpenParams(usePath, USE_PERCENT), db);
	assert syncReportsMissingPercent(db, usePath);
	writeFile(depPath, DEP_WITH_PERCENT);
	handleDidChangeWatchedFiles(syncWatchedParams(depPath, 2), db);
	publishPendingDiagnostics(db);
	assert !syncReportsMissingPercent(db, usePath);
	markDocumentClosed(usePath);
}

test "an importer published on open is not republished while its diagnostics stay the same" {
	const dir = syncTmpDir("opened");
	const depPath = dir + "/dep.ms";
	const usePath = dir + "/use.ms";
	writeFile(depPath, DEP_WITH_PERCENT);
	writeFile(usePath, USE_PERCENT);
	const db = createTransAmDb(100);
	handleDidOpen(syncOpenParams(depPath, DEP_WITH_PERCENT), db);
	handleDidOpen(syncOpenParams(usePath, USE_PERCENT), db);
	assert !syncReportsMissingPercent(db, usePath);
	assert buildTransitiveDiagnosticsWire(db, depPath) == "";
	markDocumentClosed(depPath);
	markDocumentClosed(usePath);
}

test "an open document ignores disk events for itself" {
	const dir = syncTmpDir("open");
	const depPath = dir + "/dep.ms";
	writeFile(depPath, DEP_WITH_PCT);
	const db = createTransAmDb(100);
	handleDidOpen(syncOpenParams(depPath, DEP_WITH_PERCENT), db);
	handleDidChangeWatchedFiles(syncWatchedParams(depPath, 2), db);
	assert dbGetSource(db, depPath) == DEP_WITH_PERCENT;
	markDocumentClosed(depPath);
}

test "closing a document falls back to disk and re-checks its importers" {
	const dir = syncTmpDir("closed");
	const depPath = dir + "/dep.ms";
	const usePath = dir + "/use.ms";
	writeFile(depPath, DEP_WITH_PCT);
	writeFile(usePath, USE_PERCENT);
	const db = createTransAmDb(100);
	handleDidOpen(syncOpenParams(depPath, DEP_WITH_PERCENT), db);
	handleDidOpen(syncOpenParams(usePath, USE_PERCENT), db);
	assert !syncReportsMissingPercent(db, usePath);
	handleDidClose(syncDocumentParams(depPath), db);
	assert dbGetSource(db, depPath) == DEP_WITH_PCT;
	assert publishPendingDiagnostics(db).indexOf("'percent'") >= 0;
	assert syncReportsMissingPercent(db, usePath);
	markDocumentClosed(usePath);
}

test "a deleted dependency is emptied and its importer reports it" {
	const dir = syncTmpDir("deleted");
	const depPath = dir + "/dep.ms";
	const usePath = dir + "/use.ms";
	writeFile(depPath, DEP_WITH_PERCENT);
	writeFile(usePath, USE_PERCENT);
	const db = createTransAmDb(100);
	handleDidOpen(syncOpenParams(usePath, USE_PERCENT), db);
	assert !syncReportsAnything(db, usePath);
	remove(depPath);
	handleDidChangeWatchedFiles(syncWatchedParams(depPath, 3), db);
	publishPendingDiagnostics(db);
	assert dbGetSource(db, depPath) == "";
	assert syncReportsAnything(db, usePath);
	markDocumentClosed(usePath);
}

test "a created file resolves an open importer's missing import" {
	const dir = syncTmpDir("created");
	const depPath = dir + "/dep.ms";
	const usePath = dir + "/use.ms";
	remove(depPath);
	writeFile(usePath, USE_PERCENT);
	const db = createTransAmDb(100);
	handleDidOpen(syncOpenParams(usePath, USE_PERCENT), db);
	assert syncReportsAnything(db, usePath);
	writeFile(depPath, DEP_WITH_PERCENT);
	handleDidChangeWatchedFiles(syncWatchedParams(depPath, 1), db);
	publishPendingDiagnostics(db);
	assert !syncReportsAnything(db, usePath);
	markDocumentClosed(usePath);
}

test "a created file resolves a closed importer when it is reopened" {
	const dir = syncTmpDir("reopened");
	const depPath = dir + "/dep.ms";
	const usePath = dir + "/use.ms";
	remove(depPath);
	writeFile(usePath, USE_PERCENT);
	const db = createTransAmDb(100);
	handleDidOpen(syncOpenParams(usePath, USE_PERCENT), db);
	assert syncReportsAnything(db, usePath);
	handleDidClose(syncDocumentParams(usePath), db);
	writeFile(depPath, DEP_WITH_PERCENT);
	handleDidChangeWatchedFiles(syncWatchedParams(depPath, 1), db);
	publishPendingDiagnostics(db);
	handleDidOpen(syncOpenParams(usePath, USE_PERCENT), db);
	assert !syncReportsAnything(db, usePath);
	markDocumentClosed(usePath);
}

test "watched files are registered only for clients that support it" {
	const supported = "{\"capabilities\":{\"workspace\":{\"didChangeWatchedFiles\":{\"dynamicRegistration\":true}}}}";
	assert clientSupportsWatchedFileRegistration(supported);
	assert !clientSupportsWatchedFileRegistration("{\"capabilities\":{\"workspace\":{}}}");
	const request = watchedFilesRegistration();
	assert lspGetField(request, "method") == "client/registerCapability";
	assert request.indexOf("**/*.ms") >= 0;
	assert request.indexOf("workspace/didChangeWatchedFiles") >= 0;
}

function applyRangeFormatting(source: string, line: number, character: number): string {
	const db = testDb("file:///rangefmt.ms", source);
	const pos = `{"line":${line},"character":${character}}`;
	const params = `{"textDocument":{"uri":"file:///rangefmt.ms"},"range":{"start":${pos},"end":${pos}},"options":{"tabSize":2,"insertSpaces":true}}`;
	const r = lspDispatch("textDocument/rangeFormatting", "20", params, db, testCache());
	const at = r.indexOf("\"result\":", 0);
	if (at < 0) return "NO RESULT: " + r;
	const items = lspGetArrayItems(r.byteSlice(at + 9, r.byteLength - 1));
	let out = source;
	let i = items.length - 1;
	while (i >= 0) {
		const range = lspGetObjectField(items[i], "range");
		const s = lspGetObjectField(range, "start");
		const e = lspGetObjectField(range, "end");
		const from = lineOffset(out, (lspGetNumberField(s, "line") as int32) + 1) + (lspGetNumberField(s, "character") as int32);
		const to = lineOffset(out, (lspGetNumberField(e, "line") as int32) + 1) + (lspGetNumberField(e, "character") as int32);
		out = out.byteSlice(0, from) + lspGetField(items[i], "newText") + out.byteSlice(to, out.byteLength);
		i = i - 1;
	}
	return out;
}

const RANGE_FMT_SOURCE = "const xs = [\n\t1,\n\t2,\n];\nfunction f(): Node {\n\tlet   x=1;\n\treturn <panel title=\"a fairly long title value\" subtitle=\"another long value\" onClose={handleClose}>body</panel>;\n}\n";

test "rangeFormatting is advertised" {
	assert handleInitialize("1").indexOf("\"documentRangeFormattingProvider\":true") >= 0;
}

test "rangeFormatting rewrites only the statement under the range" {
	assert applyRangeFormatting(RANGE_FMT_SOURCE, 5, 3) == "const xs = [\n\t1,\n\t2,\n];\nfunction f(): Node {\n\tlet x = 1;\n\treturn <panel title=\"a fairly long title value\" subtitle=\"another long value\" onClose={handleClose}>body</panel>;\n}\n";
}

test "rangeFormatting breaks a long JSX statement under its own tab indentation" {
	assert applyRangeFormatting(RANGE_FMT_SOURCE, 6, 3) == "const xs = [\n\t1,\n\t2,\n];\nfunction f(): Node {\n\tlet   x=1;\n\treturn <panel\n\t  title=\"a fairly long title value\"\n\t  subtitle=\"another long value\"\n\t  onClose={handleClose}\n\t>body</panel>;\n}\n";
}

test "rangeFormatting on an already formatted statement returns no edit" {
	assert applyRangeFormatting("const a = 1;\n", 0, 2) == "const a = 1;\n";
}
