// LSP Format Helpers — safe JSON string building for LSP responses.
//
// All functions use JsonBuilder (string concatenation). No JSON.stringify.
// Safe from circular references. Fast (no object graph walking).

import { jsonObj, jsonArr, jStr, jNum, jBool, jRaw, jStrIf, jRawIf, jStrItem, jEnd } from "./responseBuilder";

// ===== Position + Range =====

export function lspFmtPosition(line: number, col: number): string {
	const b = jsonObj();
	jNum(b, "line", line);
	jNum(b, "character", col);
	return jEnd(b);
}

export function lspFmtRange(line: number, col: number, endLine: number, endCol: number): string {
	const b = jsonObj();
	jRaw(b, "start", lspFmtPosition(line, col));
	jRaw(b, "end", lspFmtPosition(endLine, endCol));
	return jEnd(b);
}

export function lspFmtLineRange(line: number, col: number, endCol: number): string {
	return lspFmtRange(line, col, line, endCol);
}

// ===== Location + TextEdit =====

export function lspFmtLocation(uri: string, line: number, col: number, endLine: number, endCol: number): string {
	const b = jsonObj();
	jStr(b, "uri", uri);
	jRaw(b, "range", lspFmtRange(line, col, endLine, endCol));
	return jEnd(b);
}

export function lspFmtTextEdit(line: number, col: number, endCol: number, newText: string): string {
	const b = jsonObj();
	jRaw(b, "range", lspFmtRange(line, col, line, endCol));
	jStr(b, "newText", newText);
	return jEnd(b);
}

export function lspFmtMultiLineTextEdit(line: number, col: number, endLine: number, endCol: number, newText: string): string {
	const b = jsonObj();
	jRaw(b, "range", lspFmtRange(line, col, endLine, endCol));
	jStr(b, "newText", newText);
	return jEnd(b);
}

// ===== Completion Item =====

export function lspFmtCompletionItem(
	label: string, kind: number, detail: string,
	sortText: string, isDeprecated: boolean, commitChars: string,
	documentation: string, additionalEdits: string
): string {
	const b = jsonObj();
	jStr(b, "label", label);
	jNum(b, "kind", kind);
	jStr(b, "detail", detail);
	jStr(b, "insertText", label);
	jNum(b, "insertTextFormat", 1);
	jStrIf(b, "sortText", sortText);
	if (isDeprecated) jRaw(b, "tags", "[1]");
	if (commitChars.length > 0) {
		const ca = jsonArr();
		let i = 0;
		while (i < commitChars.length) {
			jStrItem(ca, commitChars.slice(i, i + 1));
			i = i + 1;
		}
		jRaw(b, "commitCharacters", jEnd(ca));
	}
	if (documentation.length > 0) {
		const doc = jsonObj();
		jStr(doc, "kind", "markdown");
		jStr(doc, "value", documentation);
		jRaw(b, "documentation", jEnd(doc));
	}
	jRawIf(b, "additionalTextEdits", additionalEdits);
	return jEnd(b);
}

// ===== Hover =====

export function lspFmtHoverResult(
	codeBlock: string, documentation: string,
	line: number, col: number, endCol: number
): string {
	let content = codeBlock;
	if (documentation.length > 0) {
		content = content + "\n\n---\n\n" + documentation;
	}
	const contentObj = jsonObj();
	jStr(contentObj, "kind", "markdown");
	jStr(contentObj, "value", content);
	const b = jsonObj();
	jRaw(b, "contents", jEnd(contentObj));
	if (line >= 0) {
		jRaw(b, "range", lspFmtRange(line, col, line, endCol));
	}
	return jEnd(b);
}

// ===== Diagnostics =====

export function lspFmtDiagnostic(
	line: number, col: number, endCol: number,
	severity: number, message: string, source: string, code: number, tags: number
): string {
	const b = jsonObj();
	jRaw(b, "range", lspFmtRange(line, col, line, endCol));
	jNum(b, "severity", severity);
	if (tags > 0) jRaw(b, "tags", `[${tags}]`);
	jStr(b, "source", source);
	jStr(b, "message", message);
	if (code > 0) jNum(b, "code", code);
	return jEnd(b);
}

export function lspFmtPublishDiagnostics(uri: string, diagnosticsArray: string): string {
	const b = jsonObj();
	jStr(b, "uri", uri);
	jRaw(b, "diagnostics", diagnosticsArray);
	return jEnd(b);
}

// ===== Document Symbol =====

export function lspFmtDocumentSymbol(
	name: string, kind: number, detail: string,
	line: number, col: number, endCol: number,
	childrenJson: string
): string {
	const b = jsonObj();
	jStr(b, "name", name);
	jNum(b, "kind", kind);
	jStrIf(b, "detail", detail);
	const rangeStr = lspFmtRange(line, col, line, endCol);
	jRaw(b, "range", rangeStr);
	jRaw(b, "selectionRange", rangeStr);
	jRawIf(b, "children", childrenJson);
	return jEnd(b);
}

// ===== Inlay Hint =====

export function lspFmtInlayHint(
	line: number, col: number, label: string, kind: number,
	paddingLeft: boolean, paddingRight: boolean
): string {
	const b = jsonObj();
	jRaw(b, "position", lspFmtPosition(line, col));
	jStr(b, "label", label);
	jNum(b, "kind", kind);
	jBool(b, "paddingLeft", paddingLeft);
	jBool(b, "paddingRight", paddingRight);
	return jEnd(b);
}

// ===== Document Highlight =====

export function lspFmtDocumentHighlight(line: number, col: number, endCol: number, kind: number): string {
	const b = jsonObj();
	jRaw(b, "range", lspFmtRange(line, col, line, endCol));
	jNum(b, "kind", kind);
	return jEnd(b);
}

// ===== Signature Help =====

export function lspFmtSignatureParam(label: string): string {
	const b = jsonObj();
	jStr(b, "label", label);
	return jEnd(b);
}

export function lspFmtSignature(label: string, paramsJson: string): string {
	const b = jsonObj();
	jStr(b, "label", label);
	jRaw(b, "parameters", paramsJson);
	return jEnd(b);
}

export function lspFmtSignatureHelp(signaturesJson: string, activeSig: number, activeParam: number): string {
	const b = jsonObj();
	jRaw(b, "signatures", signaturesJson);
	jNum(b, "activeSignature", activeSig);
	jNum(b, "activeParameter", activeParam);
	return jEnd(b);
}

// ===== Tests =====
test "position" { assert lspFmtPosition(0, 5) === "{\"line\":0,\"character\":5}"; }

test "zero position" { assert lspFmtPosition(0, 0) === "{\"line\":0,\"character\":0}"; }

test "single line range" {
	const r = lspFmtLineRange(3, 5, 10);
	assert r === "{\"start\":{\"line\":3,\"character\":5},\"end\":{\"line\":3,\"character\":10}}";
}

test "multi line range" {
	const r = lspFmtRange(1, 0, 5, 10);
	assert r === "{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":5,\"character\":10}}";
}

test "location" {
	const loc = lspFmtLocation("file:///a.ms", 0, 5, 0, 10);
	assert loc.length > 30;
}

test "text edit" {
	const e = lspFmtTextEdit(0, 5, 8, "newName");
	assert e.length > 30;
}

test "completion item" {
	const item = lspFmtCompletionItem("foo", 6, "number", "11", false, "", "", "");
	assert item.length > 20;
}

test "completion with sortText" {
	const item = lspFmtCompletionItem("bar", 3, "()", "10", false, "", "", "");
	assert item.length > 20;
}

test "completion deprecated" {
	const item = lspFmtCompletionItem("old", 6, "string", "z11", true, "", "", "");
	assert item.length > 30;
}

test "completion commit chars" {
	const item = lspFmtCompletionItem("fn", 3, "()", "11", false, "(.", "", "");
	assert item.length > 40;
}

test "completion with docs" {
	const item = lspFmtCompletionItem("log", 2, "(message: string) => void", "10", false, "(.", "Logs a message to the console.", "");
	assert item.length > 60;
}

test "hover code only" {
	const h = lspFmtHoverResult("```ms\n(variable) x: number\n```", "", 0, 5, 6);
	assert h.length > 30;
}

test "hover with docs" {
	const h = lspFmtHoverResult("```ms\n(variable) x: number\n```", "(exported)", 3, 0, 4);
	assert h.length > 50;
}

test "diagnostic no code" {
	const d = lspFmtDiagnostic(0, 5, 8, 1, "type error", "metascript", 0, 0);
	assert d.length > 30;
}

test "diagnostic with code" {
	const d = lspFmtDiagnostic(0, 5, 8, 1, "type error", "metascript", 2304, 0);
	assert d.length > 40;
}

test "diagnostic with unnecessary tag" {
	const d = lspFmtDiagnostic(0, 5, 8, 4, "unused import", "metascript", 0, 1);
	assert d.indexOf("tags") >= 0;
	assert d.indexOf("[1]") >= 0;
}

test "document symbol no detail" {
	const s = lspFmtDocumentSymbol("foo", 12, "", 0, 5, 8, "");
	assert s.length > 20;
}

test "document symbol with detail" {
	const s = lspFmtDocumentSymbol("foo", 12, "(a: number) => void", 0, 5, 8, "");
	assert s.length > 40;
}

test "document symbol with children" {
	const child = lspFmtDocumentSymbol("bar", 6, "() => void", 1, 2, 5, "");
	const s = lspFmtDocumentSymbol("MyClass", 5, "", 0, 0, 7, "[" + child + "]");
	assert s.length > 60;
}

test "inlay type hint" {
	const h = lspFmtInlayHint(0, 5, ": number", 1, true, false);
	assert h.length > 30;
}

test "inlay param hint" {
	const h = lspFmtInlayHint(0, 3, "name:", 2, false, true);
	assert h.length > 30;
}

test "signature help" {
	const p = lspFmtSignatureParam("a: number");
	const sig = lspFmtSignature("foo(a: number)", "[" + p + "]");
	const help = lspFmtSignatureHelp("[" + sig + "]", 0, 0);
	assert help.length > 40;
}
