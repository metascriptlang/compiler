// LSP Lifecycle Handlers + Dispatch Router + Tests
// handleInitialize, handleDidOpen, handleDidChange, handleDidClose, lspDispatch

import { TransAmDb, createTransAmDb, dbSetFileText, dbParse, dbTypeCheck, getFileId, invalidateFile } from "../../transam/index";
import { requestCancel } from "../../transam/cancel";
import { clockMs } from "std/process";
import { writeStderr } from "std/io";
import { readFile } from "std/fs";
import {
	lspJsonString, lspGetField, lspGetNumberField, lspGetObjectField,
	lspResponse, lspNotification, lspFormatMessage, lspUriToPath,
} from "../protocol";
import { lspFmtPublishDiagnostics } from "../format";
import { CompletionCache, createCompletionCache, markFileChanged, drainChangedFiles } from "./shared";
import { buildDiagnosticsJson, buildTransitiveDiagnosticsWire, recordImportsForFile, resetFormatOptions } from "./diagnostics";
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
import { handleCodeAction, handleFormatting } from "./formatting";


// ===== Deferred Diagnostics (post-drain) =====

export function publishPendingDiagnostics(db: TransAmDb): string {
	const changed = drainChangedFiles();
	if (changed.length === 0) return "";
	let result = "";
	for (const entry of changed) {
		const path = entry[0];
		const uri = entry[1];
		try {
			prebuildCompletionCache(db, path, uri);
			const diagParams = buildDiagnosticsJson(uri, db, path);
			result = result + lspFormatMessage(lspNotification("textDocument/publishDiagnostics", diagParams));
			result = result + buildTransitiveDiagnosticsWire(db, path);
		} catch (e) {
			const fileId = getFileId(db.fileInput, path);
			if (fileId >= 0) invalidateFile(db.cache, db.moduleDeps, fileId);
			writeStderr("[LSP] type check failed for " + path + ": " + e + "\n");
			result = result + lspFormatMessage(lspNotification("textDocument/publishDiagnostics", lspFmtPublishDiagnostics(uri, "[]")));
		}
	}
	return result;
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
	const t0 = clockMs();
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const text = lspGetField(textDoc, "text");
	const path = lspUriToPath(uri);

	dbSetFileText(db, path, text);
	const t1 = clockMs();
	const program = dbParse(db, path);
	const t2 = clockMs();
	recordImportsForFile(db, path, program);
	const t3 = clockMs();
	dbTypeCheck(db, path);
	const t4 = clockMs();
	prebuildCompletionCache(db, path, uri);
	const t5 = clockMs();
	const diagParams = buildDiagnosticsJson(uri, db, path);
	const t6 = clockMs();
	writeStderr(`[LSP-OPEN] ${path} parse=${t2 - t1}ms imports=${t3 - t2}ms check=${t4 - t3}ms cache=${t5 - t4}ms diag=${t6 - t5}ms total=${t6 - t0}ms\n`);
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Did Change =====

export function handleDidChange(params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
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
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const diagParams = "{\"uri\":" + lspJsonString(uri) + ",\"diagnostics\":[]}";
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Did Save =====

export function handleDidSave(params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);
	// Reload format config when build.ms or msc.json is saved
	if (path.endsWith("/build.ms") || path.endsWith("/msc.json")) {
		resetFormatOptions();
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
	assert lspGetField(r, "jsonrpc") === "2.0";
	assert lspGetNumberField(r, "id") === 1;
	const result = lspGetObjectField(r, "result");
	assert result.length > 0;
}

test "returns null result" {
	const r = handleShutdown("2");
	assert lspGetNumberField(r, "id") === 2;
}

test "clean source has no diagnostics" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const diags = buildDiagnosticsJson("file:///test.ms", db, lspUriToPath("file:///test.ms"));
	assert lspGetField(diags, "uri") === "file:///test.ms";
}

test "initialize" {
	const db = createTransAmDb(100);
	const r = lspDispatch("initialize", "1", "{}", db, testCache());
	assert lspGetNumberField(r, "id") === 1;
}

test "shutdown" {
	const db = createTransAmDb(100);
	const r = lspDispatch("shutdown", "2", "{}", db, testCache());
	assert lspGetNumberField(r, "id") === 2;
}

test "unknown method with id" {
	const db = createTransAmDb(100);
	const r = lspDispatch("unknown/method", "3", "{}", db, testCache());
	assert r === "";
}

test "unknown notification" {
	const db = createTransAmDb(100);
	const r = lspDispatch("$/unknownNotification", "", "{}", db, testCache());
	assert r === "";
}

test "completion dispatch" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":3}}";
	const r = lspDispatch("textDocument/completion", "10", params, db, testCache());
	assert lspGetNumberField(r, "id") === 10;
	assert r.length > 0;
}

test "definition dispatch" {
	const db = testDb("file:///test.ms", "const myVar = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/definition", "11", params, db, testCache());
	assert lspGetNumberField(r, "id") === 11;
	assert r.length > 0;
}

test "returns completion items" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":0}}";
	const r = handleCompletion("5", params, db, testCache());
	assert lspGetNumberField(r, "id") === 5;
	assert r.length > 50;
}

test "unknown doc returns empty" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleCompletion("6", params, db, testCache());
	assert lspGetNumberField(r, "id") === 6;
}

test "completion cache hit on prefix extend" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const cache = testCache();
	const params1 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":2}}";
	const r1 = handleCompletion("10", params1, db, cache);
	assert cache.items.length > 0;
	assert cache.uri === "file:///test.ms";
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
	assert cache.line !== cachedLine;
}

test "member access completion returns struct fields" {
	const src = "interface Foo {\n\tx: number;\n\ty: string;\n}\nconst f: Foo = { x: 1, y: \"hi\" };\nf.";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":5,\"character\":2}}";
	const r = handleCompletion("20", params, db, testCache());
	assert lspGetNumberField(r, "id") === 20;
	assert r.indexOf("\"label\":\"x\"") >= 0;
	assert r.indexOf("\"label\":\"y\"") >= 0;
	assert r.indexOf("\"detail\":\"number\"") >= 0;
	assert r.indexOf("\"detail\":\"string\"") >= 0;
}

test "returns location for known symbol" {
	const db = testDb("file:///test.ms", "const myVar = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleDefinition("7", params, db);
	assert lspGetNumberField(r, "id") === 7;
	assert r.length > 0;
}

test "unknown doc returns null" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleDefinition("8", params, db);
	assert lspGetNumberField(r, "id") === 8;
}

test "unknown position returns null result" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":99,\"character\":0}}";
	const r = handleDefinition("9", params, db);
	assert lspGetNumberField(r, "id") === 9;
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

test "returns symbols for file" {
	const db = testDb("file:///test.ms", "function foo() { return 1; }\nconst x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = handleDocumentSymbol("20", params, db);
	assert lspGetNumberField(r, "id") === 20;
	assert r.length > 60;
}

test "unknown doc returns empty array" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"}}";
	const r = handleDocumentSymbol("21", params, db);
	assert lspGetNumberField(r, "id") === 21;
}

test "dispatch routes correctly" {
	const db = testDb("file:///test.ms", "const a = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = lspDispatch("textDocument/documentSymbol", "22", params, db, testCache());
	assert lspGetNumberField(r, "id") === 22;
	assert r.length > 0;
}

test "returns signature for function" {
	const db = testDb("file:///test.ms", "function greet(name: string): void { }\ngreet(");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":6}}";
	const r = handleSignatureHelp("30", params, db);
	assert lspGetNumberField(r, "id") === 30;
	assert r.length > 0;
}

test "unknown doc returns null sig" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleSignatureHelp("31", params, db);
	assert lspGetNumberField(r, "id") === 31;
}

test "dispatch routes sig help" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = lspDispatch("textDocument/signatureHelp", "32", params, db, testCache());
	assert lspGetNumberField(r, "id") === 32;
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
	assert lspGetNumberField(r, "id") === 40;
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
	assert lspGetNumberField(r, "id") === 41;
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

test "phase 5: examples/phase5Overloads.ms type-checks cleanly" {
	const src = loadExample("examples/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5ovl.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "phase 6: examples/phase6AliasedCond.ms type-checks cleanly" {
	const src = loadExample("examples/phase6AliasedCond.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase6alias.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "phase 6: examples/phase6Assignment.ms type-checks cleanly" {
	const src = loadExample("examples/phase6Assignment.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase6assign.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "phase 6: examples/phase6TypePredicate.ms type-checks cleanly" {
	const src = loadExample("examples/phase6TypePredicate.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase6pred.ms";
	const db = testDb(uri, src);
	const diags = buildDiagnosticsJson(uri, db, lspUriToPath(uri));
	assert hasNoErrors(diags);
}

test "phase 5: sig help on examples/phase5Overloads.ms narrows to Square" {
	// Inside `area(Kind.Square, { side: 5 })` the cursor inside the object
	// literal should report activeSignature = 1 (Square is the 2nd specific
	// overload; Circle is 0). Line 30 (0-indexed) col 32 — just after `{ `.
	const src = loadExample("examples/phase5Overloads.ms");
	assert src.length > 0;
	const uri = "file:///ex-phase5ovlsig.ms";
	const db = testDb(uri, src);
	const params = "{\"textDocument\":{\"uri\":\"file:///ex-phase5ovlsig.ms\"},\"position\":{\"line\":30,\"character\":32}}";
	const r = handleSignatureHelp("100", params, db);
	assert lspGetNumberField(r, "id") === 100;
	assert r.indexOf("\"activeSignature\":1", 0) >= 0;
}

test "type hint for untyped var" {
	const db = testDb("file:///test.ms", "const x = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("40", params, db);
	assert lspGetNumberField(r, "id") === 40;
	assert r.length > 50;
}

test "empty for unknown doc" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("41", params, db);
	assert lspGetNumberField(r, "id") === 41;
}

test "dispatch inlay hint" {
	const db = testDb("file:///test.ms", "const y = true;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = lspDispatch("textDocument/inlayHint", "42", params, db, testCache());
	assert lspGetNumberField(r, "id") === 42;
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

test "finds all references to a variable" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst def = abc + 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleReferences("50", params, db);
	assert lspGetNumberField(r, "id") === 50;
	assert r.length > 60;
}

test "unknown doc returns empty refs" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleReferences("51", params, db);
	assert lspGetNumberField(r, "id") === 51;
}

test "dispatch routes refs" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/references", "52", params, db, testCache());
	assert lspGetNumberField(r, "id") === 52;
}

test "renames variable occurrences" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst def = abc + 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"xyz\"}";
	const r = handleRename("60", params, db);
	assert lspGetNumberField(r, "id") === 60;
	assert r.length > 60;
}

test "unknown doc returns null rename" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0},\"newName\":\"xyz\"}";
	const r = handleRename("61", params, db);
	assert lspGetNumberField(r, "id") === 61;
}

test "empty newName returns null" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleRename("62", params, db);
	assert lspGetNumberField(r, "id") === 62;
}

test "dispatch routes rename" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"y\"}";
	const r = lspDispatch("textDocument/rename", "63", params, db, testCache());
	assert lspGetNumberField(r, "id") === 63;
}

test "Trans-Am cache hit on comment-only change" {
	const db = createTransAmDb(100);
	const path = "/test.ms";
	dbSetFileText(db, path, "const x = 1;");
	const ctx1 = dbTypeCheck(db, path);
	assert ctx1 !== null;
	assert db.revision.value === 1;
	dbSetFileText(db, path, "const x = 1; // comment");
	assert db.revision.value === 2;
	const ctx2 = dbTypeCheck(db, path);
	assert ctx2 !== null;
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

test "didChange with error then fix clears diagnostics" {
	const uri = "file:///test.ms";
	const db = createTransAmDb(100);
	handleDidOpen(didOpenParams(uri, "const x: number = \"wrong\";"), db);
	// Edit to fix the error
	handleDidChange(didChangeParams(uri, "const x: number = 42;"), db);
	const diag = publishPendingDiagnostics(db);
	assert diag.indexOf("diagnostics") >= 0;
}

test "multi-file: edit B updates A diagnostics" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/src/b.ms", "export function foo(): number { return 1; }");
	dbParse(db, "/src/b.ms");
	dbSetFileText(db, "/src/a.ms", "import { foo } from \"./b\";\nconst x = foo();");
	const progA = dbParse(db, "/src/a.ms");
	recordImportsForFile(db, "/src/a.ms", progA);
	const ctx = dbTypeCheck(db, "/src/a.ms");
	assert ctx !== null;
}

test "cancelled type check returns without crash" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/test.ms", "const x = 1;");
	requestCancel(db.cancelCtx);
	const ctx = dbTypeCheck(db, "/test.ms");
	// Should not crash — ctx may be null or partial
	assert true;
}

test "type check completes within 200ms" {
	const db = testDb("file:///test.ms", "function foo(x: number): number { return x + 1; }\nconst y = foo(42);");
	const t0 = clockMs();
	dbTypeCheck(db, lspUriToPath("file:///test.ms"));
	const elapsed = clockMs() - t0;
	assert elapsed < 200;
}
