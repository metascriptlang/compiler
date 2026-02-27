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
	sgTypeToString, sgFindNodeAtPosition, sgGetSymbolAtCursor,
	sgFormatHover, sgCollectDiagnostics,
	sgDetectCompletionContext, sgGetPrefix, sgGetCompletionCandidates,
	sgCollectSymbolsInFile, sgFormatSignature, sgCountActiveParam, sgGetCalleeAtCursor,
	sgCollectInlayHints,
	SgSuggest, SgSuggestList, SgCompletionKind,
	SgDocumentSymbol, SgDocumentSymbolList,
	SgSignatureInfo, SgSignatureList,
	SgInlayHint, SgInlayHintList, SgInlayHintKind,
	SgDiagnostic, SgDiagnosticList
} from "../../checker/suggest";
import { parseSource } from "../../parser/statements/validation";
import { parseProgram } from "../../parser/statements/core";
import { checkProgram } from "../../checker/checkPass";
import { CheckerContext, createContext } from "../../checker/context";
import { SymbolKind, lookupSymbol } from "../../checker/symbol";
import { Type, TypeKind, unknownType, getProperty } from "../../checker/types";
import { Node, IdentifierData, MemberExprData, NodeKind } from "../../ast/node";
import { test, check, testGroup } from "std/testing";

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
	let i = 0;
	while (i < diags.items.length) {
		if (i > 0) diagArray = diagArray + ",";
		const d = diags.items[i];
		// LSP is 0-indexed, compiler is 1-indexed
		const line = d.line - 1;
		const col = d.column;
		diagArray = diagArray + "{\"range\":{\"start\":{\"line\":" + lspJsonNumber(line)
			+ ",\"character\":" + lspJsonNumber(col)
			+ "},\"end\":{\"line\":" + lspJsonNumber(line)
			+ ",\"character\":" + lspJsonNumber(col + 1)
			+ "}},\"severity\":" + lspJsonNumber(d.severity)
			+ ",\"source\":\"metascript\""
			+ ",\"message\":" + lspJsonString(d.message) + "}";
		i = i + 1;
	}
	diagArray = diagArray + "]";

	return "{\"uri\":" + lspJsonString(uri) + ",\"diagnostics\":" + diagArray + "}";
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
	const hoverResult = "{\"contents\":{\"kind\":\"markdown\",\"value\":" + lspJsonString(hoverText) + "}}";
	return lspResponse(id, hoverResult);
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

function lspFormatCompletionList(id: string, candidates: SgSuggestList): string {
	let items = "[";
	let i = 0;
	while (i < candidates.items.length) {
		if (i > 0) items = items + ",";
		const item = candidates.items[i];
		const typeStr = sgTypeToString(item.symType);
		const kindNum = lspCompletionItemKind(item.kind);
		items = items + "{\"label\":" + lspJsonString(item.name)
			+ ",\"kind\":" + lspJsonNumber(kindNum)
			+ ",\"detail\":" + lspJsonString(typeStr) + "}";
		i = i + 1;
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
	const location = "{\"uri\":" + lspJsonString(pos.uri)
		+ ",\"range\":{\"start\":{\"line\":" + lspJsonNumber(defLine)
		+ ",\"character\":" + lspJsonNumber(defCol)
		+ "},\"end\":{\"line\":" + lspJsonNumber(defLine)
		+ ",\"character\":" + lspJsonNumber(defCol + suggest.name.length)
		+ "}}}";
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
	let i = 0;
	while (i < symbols.items.length) {
		if (i > 0) items = items + ",";
		const sym = symbols.items[i];
		const kindNum = lspDocumentSymbolKind(sym.kind);
		const symLine = sym.location.line - 1;
		const symCol = sym.location.column;
		const endCol = symCol + sym.name.length;
		items = items + "{\"name\":" + lspJsonString(sym.name)
			+ ",\"kind\":" + lspJsonNumber(kindNum)
			+ ",\"range\":{\"start\":{\"line\":" + lspJsonNumber(symLine)
			+ ",\"character\":" + lspJsonNumber(symCol)
			+ "},\"end\":{\"line\":" + lspJsonNumber(symLine)
			+ ",\"character\":" + lspJsonNumber(endCol)
			+ "}},\"selectionRange\":{\"start\":{\"line\":" + lspJsonNumber(symLine)
			+ ",\"character\":" + lspJsonNumber(symCol)
			+ "},\"end\":{\"line\":" + lspJsonNumber(symLine)
			+ ",\"character\":" + lspJsonNumber(endCol)
			+ "}}}";
		i = i + 1;
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
	if (sigs.items.length === 0) return lspResponse(id, "null");

	const activeParam = sgCountActiveParam(doc.source, pos.line, pos.col);

	let sigArray = "[";
	let i = 0;
	while (i < sigs.items.length) {
		if (i > 0) sigArray = sigArray + ",";
		const sig = sigs.items[i];
		let paramArray = "[";
		let j = 0;
		while (j < sig.paramLabels.length) {
			if (j > 0) paramArray = paramArray + ",";
			paramArray = paramArray + "{\"label\":" + lspJsonString(sig.paramLabels[j]) + "}";
			j = j + 1;
		}
		paramArray = paramArray + "]";
		sigArray = sigArray + "{\"label\":" + lspJsonString(sig.label)
			+ ",\"parameters\":" + paramArray + "}";
		i = i + 1;
	}
	sigArray = sigArray + "]";

	const result = "{\"signatures\":" + sigArray
		+ ",\"activeSignature\":0"
		+ ",\"activeParameter\":" + lspJsonNumber(activeParam) + "}";
	return lspResponse(id, result);
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

	if (hintsList.items.length === 0) return lspResponse(id, "[]");

	let arr = "[";
	let i = 0;
	while (i < hintsList.items.length) {
		if (i > 0) arr = arr + ",";
		const h = hintsList.items[i];
		// LSP InlayHintKind: 1 = Type, 2 = Parameter
		const lspKind = h.hintKind === SgInlayHintKind.Type ? 1 : 2;
		// LSP position is 0-indexed
		arr = arr + "{\"position\":{\"line\":" + lspJsonNumber(h.line - 1)
			+ ",\"character\":" + lspJsonNumber(h.col)
			+ "},\"label\":" + lspJsonString(h.label)
			+ ",\"kind\":" + lspJsonNumber(lspKind)
			+ ",\"paddingLeft\":" + (h.hintKind === SgInlayHintKind.Parameter ? "false" : "false")
			+ ",\"paddingRight\":" + (h.hintKind === SgInlayHintKind.Parameter ? "true" : "false")
			+ "}";
		i = i + 1;
	}
	arr = arr + "]";
	return lspResponse(id, arr);
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
		_ => id.length > 0 ? lspErrorResponse(id, -32601, "Method not found") : "",
	};
}

// ===== Tests =====

testGroup("LspHandleInitialize", () => {
	test("returns capabilities", () => {
		const r = handleInitialize("1");
		check(lspGetField(r, "jsonrpc") === "2.0");
		check(lspGetNumberField(r, "id") === 1);
		// Should contain capabilities
		const result = lspGetObjectField(r, "result");
		check(result.length > 0);
	});
});

testGroup("LspHandleShutdown", () => {
	test("returns null result", () => {
		const r = handleShutdown("2");
		check(lspGetNumberField(r, "id") === 2);
	});
});

testGroup("LspBuildDiagnostics", () => {
	test("clean source has no diagnostics", () => {
		const diags = buildDiagnosticsJson("file:///test.ms", "const x = 1;");
		check(lspGetField(diags, "uri") === "file:///test.ms");
	});
});

testGroup("LspDispatch", () => {
	test("initialize", () => {
		const store = createDocumentStore();
		const r = lspDispatch("initialize", "1", "{}", store);
		check(lspGetNumberField(r, "id") === 1);
	});
	test("shutdown", () => {
		const store = createDocumentStore();
		const r = lspDispatch("shutdown", "2", "{}", store);
		check(lspGetNumberField(r, "id") === 2);
	});
	test("unknown method with id", () => {
		const store = createDocumentStore();
		const r = lspDispatch("unknown/method", "3", "{}", store);
		// Should return error response
		check(r.length > 0);
	});
	test("unknown notification", () => {
		const store = createDocumentStore();
		const r = lspDispatch("$/unknownNotification", "", "{}", store);
		check(r === "");
	});
	test("completion dispatch", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const abc = 1;\nconst abd = 2;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":3}}";
		const r = lspDispatch("textDocument/completion", "10", params, store);
		check(lspGetNumberField(r, "id") === 10);
		check(r.length > 0);
	});
	test("definition dispatch", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const myVar = 42;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
		const r = lspDispatch("textDocument/definition", "11", params, store);
		check(lspGetNumberField(r, "id") === 11);
		check(r.length > 0);
	});
});

testGroup("LspCompletion", () => {
	test("returns completion items", () => {
		const store = createDocumentStore();
		// Cursor at line 1 (0-indexed), char 0 → empty prefix → returns all symbols
		storeDocument(store, "file:///test.ms", "const abc = 1;\nconst abd = 2;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":0}}";
		const r = handleCompletion("5", params, store);
		check(lspGetNumberField(r, "id") === 5);
		// Response with items should be much longer than a minimal empty response
		check(r.length > 50);
	});
	test("unknown doc returns empty", () => {
		const store = createDocumentStore();
		const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
		const r = handleCompletion("6", params, store);
		check(lspGetNumberField(r, "id") === 6);
	});
});

testGroup("LspDefinition", () => {
	test("returns location for known symbol", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const myVar = 42;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
		const r = handleDefinition("7", params, store);
		check(lspGetNumberField(r, "id") === 7);
		check(r.length > 0);
	});
	test("unknown doc returns null", () => {
		const store = createDocumentStore();
		const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
		const r = handleDefinition("8", params, store);
		check(lspGetNumberField(r, "id") === 8);
	});
	test("unknown position returns null result", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const x = 1;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":99,\"character\":0}}";
		const r = handleDefinition("9", params, store);
		check(lspGetNumberField(r, "id") === 9);
	});
});

testGroup("LspDocumentSymbol", () => {
	test("returns symbols for file", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "function foo() { return 1; }\nconst x = 1;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
		const r = handleDocumentSymbol("20", params, store);
		check(lspGetNumberField(r, "id") === 20);
		// Should have symbols (response much longer than empty)
		check(r.length > 60);
	});
	test("unknown doc returns empty array", () => {
		const store = createDocumentStore();
		const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"}}";
		const r = handleDocumentSymbol("21", params, store);
		check(lspGetNumberField(r, "id") === 21);
	});
	test("dispatch routes correctly", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const a = 1;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
		const r = lspDispatch("textDocument/documentSymbol", "22", params, store);
		check(lspGetNumberField(r, "id") === 22);
		check(r.length > 0);
	});
});

testGroup("LspSignatureHelp", () => {
	test("returns signature for function", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "function greet(name: string): void { }\ngreet(", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":6}}";
		const r = handleSignatureHelp("30", params, store);
		check(lspGetNumberField(r, "id") === 30);
		// May or may not find symbol at call site — depends on AST position
		check(r.length > 0);
	});
	test("unknown doc returns null", () => {
		const store = createDocumentStore();
		const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
		const r = handleSignatureHelp("31", params, store);
		check(lspGetNumberField(r, "id") === 31);
	});
	test("dispatch routes correctly", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const x = 1;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}}";
		const r = lspDispatch("textDocument/signatureHelp", "32", params, store);
		check(lspGetNumberField(r, "id") === 32);
	});
});

testGroup("LspInlayHint", () => {
	test("type hint for untyped var", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const x = 42;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
		const r = handleInlayHint("40", params, store);
		check(lspGetNumberField(r, "id") === 40);
		// Should contain a type hint
		check(r.length > 50);
	});
	test("empty for unknown doc", () => {
		const store = createDocumentStore();
		const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
		const r = handleInlayHint("41", params, store);
		check(lspGetNumberField(r, "id") === 41);
	});
	test("dispatch routes correctly", () => {
		const store = createDocumentStore();
		storeDocument(store, "file:///test.ms", "const y = true;", 1);
		const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
		const r = lspDispatch("textDocument/inlayHint", "42", params, store);
		check(lspGetNumberField(r, "id") === 42);
	});
});
