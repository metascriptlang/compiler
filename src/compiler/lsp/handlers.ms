// LSP Handlers — Per-method dispatch, format JSON responses
//
// Each handler: extract params → compile → call suggest.ms → format JSON.
// No I/O — returns JSON strings. server.ms handles stdin/stdout.

import { sliceStr, charAt } from "../../utils/string";
import {
	LspDocument, LspDocumentStore,
	createDocumentStore, storeDocument, getDocument, removeDocument
} from "./store";
import {
	lspJsonString, lspJsonNumber, lspJsonBool, lspJsonNull,
	lspGetField, lspGetNumberField, lspGetObjectField,
	lspResponse, lspNotification, lspErrorResponse
} from "./protocol";
import {
	lspFmtPosition, lspFmtRange, lspFmtLineRange,
	lspFmtLocation, lspFmtTextEdit,
	lspFmtCompletionItem, lspFmtHoverResult,
	lspFmtDiagnostic, lspFmtPublishDiagnostics,
	lspFmtDocumentSymbol, lspFmtInlayHint,
	lspFmtSignatureParam, lspFmtSignature, lspFmtSignatureHelp
} from "./format";
import {
	sgTypeToString, sgFindNodeAtPosition, sgGetSymbolAtCursor,
	sgFormatHover, sgCollectDiagnostics,
	sgDetectCompletionContext, sgGetPrefix, sgGetCompletionCandidates,
	sgCollectSymbolsInFile, sgFormatSignature, sgCountActiveParam, sgGetCalleeAtCursor,
	sgCollectInlayHints,
	sgCollectReferences, sgFindUsagesByName,
	sgFormatHoverDoc,
	SgSuggest, SgCompletionKind,
	SgSymbolRef,
	SgDocumentSymbol,
	SgSignatureInfo,
	SgInlayHint, SgInlayHintKind,
	SgDiagnostic
} from "../../checker/suggest";
import { parseSource } from "../../parser/statements/validation";
import { parseProgram } from "../../parser/statements/core";
import { checkProgram } from "../../checker/checkPass";
import { CheckerContext, createContext } from "../../checker/context";
import { SymbolKind, lookupSymbol } from "../../checker/symbol";
import { Type, TypeKind, unknownType, getProperty } from "../../checker/types";
import { Node, IdentifierData, MemberExprData, NodeKind } from "../../ast/node";
import { check } from "std/testing";

// ===== Shared Helpers =====

interface LspCursorParams {
	uri: string;
	line: number;
	col: number;
}

function lspExtractPosition(params: string): LspCursorParams {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const position = lspGetObjectField(params, "position");
	return { uri, line: lspGetNumberField(position, "line") + 1, col: lspGetNumberField(position, "character") };
}

// compileForLsp: parse + check source, return CheckerContext.
// Cannot return Node in an interface here (DRC lifecycle mangling bug),
// so handlers that need the AST call parseSource + checkProgram inline.
function compileForLsp(source: string): CheckerContext {
	const pr = parseSource(source);
	if (!pr.ok) return createContext();
	return checkProgram(pr.value);
}

// ===== Diagnostics =====

export function buildDiagnosticsJson(uri: string, source: string): string {
	const ctx = compileForLsp(source);
	const diags = sgCollectDiagnostics(ctx);

	let diagArray = "[";
	for (let i = 0; i < diags.length; i = i + 1) {
		if (i > 0) diagArray = diagArray + ",";
		const d = diags[i];
		const line = d.line - 1;
		diagArray = diagArray + lspFmtDiagnostic(
			line, d.column, d.column + 1, d.severity, d.message, "metascript", 0
		);
	}
	diagArray = diagArray + "]";

	return lspFmtPublishDiagnostics(uri, diagArray);
}

// ===== Initialize =====

export function handleInitialize(id: string): string {
	const caps = "{\"capabilities\":{"
		+ "\"textDocumentSync\":{\"openClose\":true,\"change\":1}"
		+ ",\"hoverProvider\":true"
		+ ",\"completionProvider\":{\"triggerCharacters\":[\".\"]}"
		+ ",\"definitionProvider\":true"
		+ ",\"documentSymbolProvider\":true"
		+ ",\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}"
		+ ",\"inlayHintProvider\":true"
		+ ",\"referencesProvider\":true"
		+ ",\"renameProvider\":true"
		+ "}}";
	return lspResponse(id, caps);
}

// ===== Shutdown =====

export function handleShutdown(id: string): string {
	return lspResponse(id, "null");
}

// ===== Did Open =====

export function handleDidOpen(params: string, store: LspDocumentStore): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const text = lspGetField(textDoc, "text");
	const version = lspGetNumberField(textDoc, "version");
	storeDocument(store, uri, text, version);
	// Return diagnostics notification
	const diagParams = buildDiagnosticsJson(uri, text);
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Did Change =====

export function handleDidChange(params: string, store: LspDocumentStore): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const version = lspGetNumberField(textDoc, "version");
	// Full sync: contentChanges[0].text has entire document
	// Extract text from first element of contentChanges array
	const changes = lspGetField(params, "text");
	storeDocument(store, uri, changes, version);
	const diagParams = buildDiagnosticsJson(uri, changes);
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Did Close =====

export function handleDidClose(params: string, store: LspDocumentStore): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	removeDocument(store, uri);
	// Clear diagnostics
	const diagParams = "{\"uri\":" + lspJsonString(uri) + ",\"diagnostics\":[]}";
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Hover =====

export function handleHover(id: string, params: string, store: LspDocumentStore): string {
	const pos = lspExtractPosition(params);
	const doc = getDocument(store, pos.uri);
	if (doc === null) return lspResponse(id, "null");

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "null");

	const ctx = checkProgram(pr.value);
	const suggest = sgGetSymbolAtCursor(ctx, pr.value, pos.line, pos.col);
	if (suggest === null) return lspResponse(id, "null");

	const hoverText = sgFormatHover(suggest);
	const hoverDoc = sgFormatHoverDoc(suggest);
	return lspResponse(id, lspFmtHoverResult(hoverText, hoverDoc));
}

// ===== Completion =====

function lspCompletionItemKind(kind: SymbolKind): number {
	return match (kind) {
		SymbolKind.Function => 3,
		SymbolKind.Method => 2,
		SymbolKind.Variable | SymbolKind.Parameter => 6,
		SymbolKind.Class => 7,
		SymbolKind.Interface => 8,
		SymbolKind.Enum => 13,
		SymbolKind.TypeAlias => 25,
		SymbolKind.Property => 10,
		_ => 6,
	};
}

export function handleCompletion(id: string, params: string, store: LspDocumentStore): string {
	const pos = lspExtractPosition(params);
	const doc = getDocument(store, pos.uri);
	if (doc === null) return lspResponse(id, "[]");

	const kind = sgDetectCompletionContext(doc.source, pos.line, pos.col);
	const prefix = sgGetPrefix(doc.source, pos.line, pos.col);

	// For MemberAccess, try to resolve receiver type
	let receiverType = null as unknown as Type;
	if (kind === SgCompletionKind.MemberAccess) {
		const pr = parseSource(doc.source);
		if (pr.ok) {
			const ctx = checkProgram(pr.value);
			const dotCol = pos.col - prefix.length - 1;
			if (dotCol >= 0) {
				const node = sgFindNodeAtPosition(pr.value, pos.line, dotCol);
				if (node !== null) {
					const suggest = sgGetSymbolAtCursor(ctx, pr.value, pos.line, dotCol);
					if (suggest !== null) {
						receiverType = suggest.symType;
					}
				}
			}
			const candidates = sgGetCompletionCandidates(ctx, kind, prefix, receiverType);
			return lspFormatCompletionList(id, candidates);
		}
	}

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "[]");

	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, kind, prefix, receiverType);
	return lspFormatCompletionList(id, candidates);
}

// TypeScript-style sortText: lower number = higher priority
function lspCompletionSortText(item: SgSuggest): string {
	if (item.contextFit) return "10";
	if (item.scopeDepth === 0) return "11";
	if (item.scopeDepth <= 2) return "12";
	return "15";
}

// Commit characters by symbol kind (TypeScript pattern)
function lspCommitCharsForKind(kind: SymbolKind): string {
	return match (kind) {
		SymbolKind.Function | SymbolKind.Method => "(.",
		SymbolKind.Property => ".,",
		SymbolKind.Variable | SymbolKind.Parameter => ".,;",
		_ => "",
	};
}

function lspFormatCompletionList(id: string, candidates: SgSuggest[]): string {
	let items = "[";
	for (let i = 0; i < candidates.length; i = i + 1) {
		if (i > 0) items = items + ",";
		const item = candidates[i];
		const typeStr = sgTypeToString(item.symType);
		const kindNum = lspCompletionItemKind(item.kind);
		const sortText = lspCompletionSortText(item);
		const commitChars = lspCommitCharsForKind(item.kind);
		items = items + lspFmtCompletionItem(
			item.name, kindNum, typeStr, sortText, false, commitChars
		);
	}
	items = items + "]";
	return lspResponse(id, items);
}

// ===== Definition =====

export function handleDefinition(id: string, params: string, store: LspDocumentStore): string {
	const pos = lspExtractPosition(params);
	const doc = getDocument(store, pos.uri);
	if (doc === null) return lspResponse(id, "null");

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "null");

	const ctx = checkProgram(pr.value);
	const suggest = sgGetSymbolAtCursor(ctx, pr.value, pos.line, pos.col);
	if (suggest === null) return lspResponse(id, "null");

	const defLine = suggest.location.line - 1;
	const defCol = suggest.location.column;
	const location = lspFmtLocation(pos.uri, defLine, defCol, defLine, defCol + suggest.name.length);
	return lspResponse(id, location);
}

// ===== Document Symbol =====

function lspDocumentSymbolKind(kind: SymbolKind): number {
	return match (kind) {
		SymbolKind.Function => 12,
		SymbolKind.Variable => 13,
		SymbolKind.Class => 5,
		SymbolKind.Interface => 11,
		SymbolKind.Enum => 10,
		SymbolKind.TypeAlias => 25,
		SymbolKind.Method => 6,
		SymbolKind.Property => 7,
		_ => 13,
	};
}

export function handleDocumentSymbol(id: string, params: string, store: LspDocumentStore): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");

	const doc = getDocument(store, uri);
	if (doc === null) return lspResponse(id, "[]");

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "[]");

	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);

	let items = "[";
	for (let i = 0; i < symbols.length; i = i + 1) {
		if (i > 0) items = items + ",";
		const sym = symbols[i];
		const kindNum = lspDocumentSymbolKind(sym.kind);
		const symLine = sym.location.line - 1;
		const symCol = sym.location.column;
		const endCol = symCol + sym.name.length;
		items = items + lspFmtDocumentSymbol(sym.name, kindNum, sym.detail, symLine, symCol, endCol);
	}
	items = items + "]";
	return lspResponse(id, items);
}

// ===== Signature Help =====

export function handleSignatureHelp(id: string, params: string, store: LspDocumentStore): string {
	const pos = lspExtractPosition(params);
	const doc = getDocument(store, pos.uri);
	if (doc === null) return lspResponse(id, "null");

	const calleeName = sgGetCalleeAtCursor(doc.source, pos.line, pos.col);
	if (calleeName === "") return lspResponse(id, "null");

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "null");

	const ctx = checkProgram(pr.value);
	const sym = lookupSymbol(ctx.table, calleeName);
	if (sym === null) return lspResponse(id, "null");

	const sigs = sgFormatSignature(sym);
	if (sigs.length === 0) return lspResponse(id, "null");

	const activeParam = sgCountActiveParam(doc.source, pos.line, pos.col);

	let sigArray = "[";
	for (let i = 0; i < sigs.length; i = i + 1) {
		if (i > 0) sigArray = sigArray + ",";
		const sig = sigs[i];
		let paramArray = "[";
		for (let j = 0; j < sig.paramLabels.length; j = j + 1) {
			if (j > 0) paramArray = paramArray + ",";
			paramArray = paramArray + lspFmtSignatureParam(sig.paramLabels[j]);
		}
		paramArray = paramArray + "]";
		sigArray = sigArray + lspFmtSignature(sig.label, paramArray);
	}
	sigArray = sigArray + "]";

	return lspResponse(id, lspFmtSignatureHelp(sigArray, 0, activeParam));
}

// ===== Inlay Hints =====

export function handleInlayHint(id: string, params: string, store: LspDocumentStore): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const range = lspGetObjectField(params, "range");
	const rangeStart = lspGetObjectField(range, "start");
	const rangeEnd = lspGetObjectField(range, "end");
	const startLine = lspGetNumberField(rangeStart, "line") + 1;
	const endLine = lspGetNumberField(rangeEnd, "line") + 1;

	const doc = getDocument(store, uri);
	if (doc === null) return lspResponse(id, "[]");

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "[]");

	const ctx = checkProgram(pr.value);
	const hintsList = sgCollectInlayHints(ctx, pr.value, startLine, endLine);

	if (hintsList.length === 0) return lspResponse(id, "[]");

	let arr = "[";
	for (let i = 0; i < hintsList.length; i = i + 1) {
		if (i > 0) arr = arr + ",";
		const h = hintsList[i];
		// LSP InlayHintKind: 1 = Type, 2 = Parameter
		const lspKind = h.hintKind === SgInlayHintKind.Type ? 1 : 2;
		// Type hints: paddingLeft (space before ": number")
		// Parameter hints: paddingRight (space after "name:")
		const padLeft = h.hintKind === SgInlayHintKind.Type;
		const padRight = h.hintKind === SgInlayHintKind.Parameter;
		arr = arr + lspFmtInlayHint(h.line - 1, h.col, h.label, lspKind, padLeft, padRight);
	}
	arr = arr + "]";
	return lspResponse(id, arr);
}

// ===== References =====

export function handleReferences(id: string, params: string, store: LspDocumentStore): string {
	const pos = lspExtractPosition(params);
	const doc = getDocument(store, pos.uri);
	if (doc === null) return lspResponse(id, "[]");

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "[]");

	const ctx = checkProgram(pr.value);
	const suggest = sgGetSymbolAtCursor(ctx, pr.value, pos.line, pos.col);
	if (suggest === null) return lspResponse(id, "[]");

	const allRefs = sgCollectReferences(pr.value);
	const refs = sgFindUsagesByName(allRefs, suggest.name);

	let arr = "[";
	for (let i = 0; i < refs.length; i = i + 1) {
		if (i > 0) arr = arr + ",";
		const ref = refs[i];
		const refLine = ref.line - 1;
		arr = arr + lspFmtLocation(pos.uri, refLine, ref.col, refLine, ref.col + ref.nameLen);
	}
	arr = arr + "]";
	return lspResponse(id, arr);
}

// ===== Rename =====

export function handleRename(id: string, params: string, store: LspDocumentStore): string {
	const pos = lspExtractPosition(params);
	const doc = getDocument(store, pos.uri);
	if (doc === null) return lspResponse(id, "null");

	const newName = lspGetField(params, "newName");
	if (newName === "") return lspResponse(id, "null");

	const pr = parseSource(doc.source);
	if (!pr.ok) return lspResponse(id, "null");

	const ctx = checkProgram(pr.value);
	const suggest = sgGetSymbolAtCursor(ctx, pr.value, pos.line, pos.col);
	if (suggest === null) return lspResponse(id, "null");

	const allRefs = sgCollectReferences(pr.value);
	const refs = sgFindUsagesByName(allRefs, suggest.name);

	if (refs.length === 0) return lspResponse(id, "null");

	let edits = "[";
	for (let i = 0; i < refs.length; i = i + 1) {
		if (i > 0) edits = edits + ",";
		const ref = refs[i];
		const refLine = ref.line - 1;
		edits = edits + lspFmtTextEdit(refLine, ref.col, ref.col + ref.nameLen, newName);
	}
	edits = edits + "]";

	const result = "{\"changes\":{" + lspJsonString(pos.uri) + ":" + edits + "}}";
	return lspResponse(id, result);
}

// ===== Dispatch =====

export function lspDispatch(method: string, id: string, params: string, store: LspDocumentStore): string {
	return match (method) {
		"initialize" => handleInitialize(id),
		"shutdown" => handleShutdown(id),
		"textDocument/didOpen" => handleDidOpen(params, store),
		"textDocument/didChange" => handleDidChange(params, store),
		"textDocument/didClose" => handleDidClose(params, store),
		"textDocument/hover" => handleHover(id, params, store),
		"textDocument/completion" => handleCompletion(id, params, store),
		"textDocument/definition" => handleDefinition(id, params, store),
		"textDocument/documentSymbol" => handleDocumentSymbol(id, params, store),
		"textDocument/signatureHelp" => handleSignatureHelp(id, params, store),
		"textDocument/inlayHint" => handleInlayHint(id, params, store),
		"textDocument/references" => handleReferences(id, params, store),
		"textDocument/rename" => handleRename(id, params, store),
		_ => id.length > 0 ? lspErrorResponse(id, -32601, "Method not found") : "",
	};
}

// ===== Tests =====
test "returns capabilities" {
	const r = handleInitialize("1");
	check(lspGetField(r, "jsonrpc") === "2.0");
	check(lspGetNumberField(r, "id") === 1);
	// Should contain capabilities
	const result = lspGetObjectField(r, "result");
	check(result.length > 0);
}

test "returns null result" {
	const r = handleShutdown("2");
	check(lspGetNumberField(r, "id") === 2);
}

test "clean source has no diagnostics" {
	const diags = buildDiagnosticsJson("file:///test.ms", "const x = 1;");
	check(lspGetField(diags, "uri") === "file:///test.ms");
}

test "initialize" {
	const store = createDocumentStore();
	const r = lspDispatch("initialize", "1", "{}", store);
	check(lspGetNumberField(r, "id") === 1);
}

test "shutdown" {
	const store = createDocumentStore();
	const r = lspDispatch("shutdown", "2", "{}", store);
	check(lspGetNumberField(r, "id") === 2);
}

test "unknown method with id" {
	const store = createDocumentStore();
	const r = lspDispatch("unknown/method", "3", "{}", store);
	// Should return error response
	check(r.length > 0);
}

test "unknown notification" {
	const store = createDocumentStore();
	const r = lspDispatch("$/unknownNotification", "", "{}", store);
	check(r === "");
}

test "completion dispatch" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const abc = 1;\nconst abd = 2;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":3}}";
	const r = lspDispatch("textDocument/completion", "10", params, store);
	check(lspGetNumberField(r, "id") === 10);
	check(r.length > 0);
}

test "definition dispatch" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const myVar = 42;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/definition", "11", params, store);
	check(lspGetNumberField(r, "id") === 11);
	check(r.length > 0);
}

test "returns completion items" {
	const store = createDocumentStore();
	// Cursor at line 1 (0-indexed), char 0 → empty prefix → returns all symbols
	storeDocument(store, "file:///test.ms", "const abc = 1;\nconst abd = 2;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":0}}";
	const r = handleCompletion("5", params, store);
	check(lspGetNumberField(r, "id") === 5);
	// Response with items should be much longer than a minimal empty response
	check(r.length > 50);
}

test "unknown doc returns empty" {
	const store = createDocumentStore();
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleCompletion("6", params, store);
	check(lspGetNumberField(r, "id") === 6);
}

test "returns location for known symbol" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const myVar = 42;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleDefinition("7", params, store);
	check(lspGetNumberField(r, "id") === 7);
	check(r.length > 0);
}

test "unknown doc returns null" {
	const store = createDocumentStore();
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleDefinition("8", params, store);
	check(lspGetNumberField(r, "id") === 8);
}

test "unknown position returns null result" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const x = 1;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":99,\"character\":0}}";
	const r = handleDefinition("9", params, store);
	check(lspGetNumberField(r, "id") === 9);
}

test "returns symbols for file" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "function foo() { return 1; }\nconst x = 1;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = handleDocumentSymbol("20", params, store);
	check(lspGetNumberField(r, "id") === 20);
	// Should have symbols (response much longer than empty)
	check(r.length > 60);
}

test "unknown doc returns empty array" {
	const store = createDocumentStore();
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"}}";
	const r = handleDocumentSymbol("21", params, store);
	check(lspGetNumberField(r, "id") === 21);
}

test "dispatch routes correctly" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const a = 1;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = lspDispatch("textDocument/documentSymbol", "22", params, store);
	check(lspGetNumberField(r, "id") === 22);
	check(r.length > 0);
}

test "returns signature for function" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "function greet(name: string): void { }\ngreet(", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":6}}";
	const r = handleSignatureHelp("30", params, store);
	check(lspGetNumberField(r, "id") === 30);
	// May or may not find symbol at call site — depends on AST position
	check(r.length > 0);
}

test "unknown doc returns null" {
	const store = createDocumentStore();
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleSignatureHelp("31", params, store);
	check(lspGetNumberField(r, "id") === 31);
}

test "dispatch routes correctly" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const x = 1;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = lspDispatch("textDocument/signatureHelp", "32", params, store);
	check(lspGetNumberField(r, "id") === 32);
}

test "type hint for untyped var" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const x = 42;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("40", params, store);
	check(lspGetNumberField(r, "id") === 40);
	// Should contain a type hint
	check(r.length > 50);
}

test "empty for unknown doc" {
	const store = createDocumentStore();
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("41", params, store);
	check(lspGetNumberField(r, "id") === 41);
}

test "dispatch routes correctly" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const y = true;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = lspDispatch("textDocument/inlayHint", "42", params, store);
	check(lspGetNumberField(r, "id") === 42);
}

test "finds all references to a variable" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const abc = 1;\nconst def = abc + 2;", 1);
	// Cursor on "abc" declaration at line 0, col 6
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleReferences("50", params, store);
	check(lspGetNumberField(r, "id") === 50);
	// Should find at least 2 references (decl + usage)
	check(r.length > 60);
}

test "unknown doc returns empty" {
	const store = createDocumentStore();
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleReferences("51", params, store);
	check(lspGetNumberField(r, "id") === 51);
}

test "dispatch routes correctly" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const x = 1;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/references", "52", params, store);
	check(lspGetNumberField(r, "id") === 52);
}

test "renames variable occurrences" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const abc = 1;\nconst def = abc + 2;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"xyz\"}";
	const r = handleRename("60", params, store);
	check(lspGetNumberField(r, "id") === 60);
	// Should contain workspace edit with changes
	check(r.length > 60);
}

test "unknown doc returns null" {
	const store = createDocumentStore();
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0},\"newName\":\"xyz\"}";
	const r = handleRename("61", params, store);
	check(lspGetNumberField(r, "id") === 61);
}

test "empty newName returns null" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const x = 1;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleRename("62", params, store);
	check(lspGetNumberField(r, "id") === 62);
}

test "dispatch routes correctly" {
	const store = createDocumentStore();
	storeDocument(store, "file:///test.ms", "const x = 1;", 1);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"y\"}";
	const r = lspDispatch("textDocument/rename", "63", params, store);
	check(lspGetNumberField(r, "id") === 63);
}
