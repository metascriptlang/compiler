// LSP Format Helpers — Unified JSON formatting for all LSP responses
//
// All functions take only primitives (string, number, boolean) and return JSON strings.
// No Node/Type/Symbol — purely JSON serialization. Keeps handlers.ms clean.
//
// Follows TypeScript-Go LSP patterns for a familiar developer experience.

import { lspJsonString, lspJsonNumber, lspJsonBool } from "./protocol";
import { sliceStr, charAt } from "../../utils/string";


// ===== Position + Range =====

export function lspFmtPosition(line: number, col: number): string {
	return "{\"line\":" + lspJsonNumber(line) + ",\"character\":" + lspJsonNumber(col) + "}";
}

export function lspFmtRange(line: number, col: number, endLine: number, endCol: number): string {
	return "{\"start\":" + lspFmtPosition(line, col) + ",\"end\":" + lspFmtPosition(endLine, endCol) + "}";
}

export function lspFmtLineRange(line: number, col: number, endCol: number): string {
	return lspFmtRange(line, col, line, endCol);
}

// ===== Location + TextEdit =====

export function lspFmtLocation(uri: string, line: number, col: number, endLine: number, endCol: number): string {
	return "{\"uri\":" + lspJsonString(uri) + ",\"range\":" + lspFmtRange(line, col, endLine, endCol) + "}";
}

export function lspFmtTextEdit(line: number, col: number, endCol: number, newText: string): string {
	return "{\"range\":" + lspFmtLineRange(line, col, endCol) + ",\"newText\":" + lspJsonString(newText) + "}";
}

// ===== Completion Item =====

// commitChars: single string like ".,;" — each char becomes a JSON array element.
// Empty string = no commitCharacters field.
function lspBuildCommitCharsArray(chars: string): string {
	if (chars.length === 0) return "";
	let arr = "[";
	for (let i = 0; i < chars.length; i = i + 1) {
		if (i > 0) arr = arr + ",";
		arr = arr + lspJsonString(sliceStr(chars, i, i + 1));
	}
	arr = arr + "]";
	return arr;
}

export function lspFmtCompletionItem(
	label: string, kind: number, detail: string,
	sortText: string, isDeprecated: boolean, commitChars: string,
	documentation: string
): string {
	let result = "{\"label\":" + lspJsonString(label)
		+ ",\"kind\":" + lspJsonNumber(kind)
		+ ",\"detail\":" + lspJsonString(detail);
	if (sortText.length > 0) {
		result = result + ",\"sortText\":" + lspJsonString(sortText);
	}
	if (isDeprecated) {
		result = result + ",\"tags\":[1]";
	}
	const commitArr = lspBuildCommitCharsArray(commitChars);
	if (commitArr.length > 0) {
		result = result + ",\"commitCharacters\":" + commitArr;
	}
	if (documentation.length > 0) {
		result = result + ",\"documentation\":{\"kind\":\"markdown\",\"value\":" + lspJsonString(documentation) + "}";
	}
	result = result + "}";
	return result;
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
	let result = "{\"contents\":{\"kind\":\"markdown\",\"value\":" + lspJsonString(content) + "}";
	if (line >= 0) {
		result = result + ",\"range\":" + lspFmtLineRange(line, col, endCol);
	}
	result = result + "}";
	return result;
}

// ===== Diagnostics =====

export function lspFmtDiagnostic(
	line: number, col: number, endCol: number,
	severity: number, message: string, source: string, code: number
): string {
	let result = "{\"range\":" + lspFmtLineRange(line, col, endCol)
		+ ",\"severity\":" + lspJsonNumber(severity)
		+ ",\"source\":" + lspJsonString(source)
		+ ",\"message\":" + lspJsonString(message);
	if (code > 0) {
		result = result + ",\"code\":" + lspJsonNumber(code);
	}
	result = result + "}";
	return result;
}

export function lspFmtPublishDiagnostics(uri: string, diagnosticsArray: string): string {
	return "{\"uri\":" + lspJsonString(uri) + ",\"diagnostics\":" + diagnosticsArray + "}";
}

// ===== Document Symbol =====

export function lspFmtDocumentSymbol(
	name: string, kind: number, detail: string,
	line: number, col: number, endCol: number,
	childrenJson: string
): string {
	const range = lspFmtLineRange(line, col, endCol);
	let result = "{\"name\":" + lspJsonString(name)
		+ ",\"kind\":" + lspJsonNumber(kind);
	if (detail.length > 0) {
		result = result + ",\"detail\":" + lspJsonString(detail);
	}
	result = result + ",\"range\":" + range
		+ ",\"selectionRange\":" + range;
	if (childrenJson.length > 0) {
		result = result + ",\"children\":" + childrenJson;
	}
	result = result + "}";
	return result;
}

// ===== Inlay Hint =====

export function lspFmtInlayHint(
	line: number, col: number, label: string, kind: number,
	paddingLeft: boolean, paddingRight: boolean
): string {
	return "{\"position\":" + lspFmtPosition(line, col)
		+ ",\"label\":" + lspJsonString(label)
		+ ",\"kind\":" + lspJsonNumber(kind)
		+ ",\"paddingLeft\":" + lspJsonBool(paddingLeft)
		+ ",\"paddingRight\":" + lspJsonBool(paddingRight)
		+ "}";
}

// ===== Document Highlight =====

export function lspFmtDocumentHighlight(line: number, col: number, endCol: number, kind: number): string {
	return "{\"range\":" + lspFmtLineRange(line, col, endCol) + ",\"kind\":" + lspJsonNumber(kind) + "}";
}

// ===== Signature Help =====

export function lspFmtSignatureParam(label: string): string {
	return "{\"label\":" + lspJsonString(label) + "}";
}

export function lspFmtSignature(label: string, paramsJson: string): string {
	return "{\"label\":" + lspJsonString(label)
		+ ",\"parameters\":" + paramsJson + "}";
}

export function lspFmtSignatureHelp(signaturesJson: string, activeSig: number, activeParam: number): string {
	return "{\"signatures\":" + signaturesJson
		+ ",\"activeSignature\":" + lspJsonNumber(activeSig)
		+ ",\"activeParameter\":" + lspJsonNumber(activeParam) + "}";
}

// ===== Tests =====
test "basic" { assert lspFmtPosition(0, 5) === "{\"line\":0,\"character\":5}"; }

test "zero" { assert lspFmtPosition(0, 0) === "{\"line\":0,\"character\":0}"; }

test "single line" {
	const r = lspFmtLineRange(3, 5, 10);
	assert r === "{\"start\":{\"line\":3,\"character\":5},\"end\":{\"line\":3,\"character\":10}}";
}

test "multi line" {
	const r = lspFmtRange(1, 0, 5, 10);
	assert r === "{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":5,\"character\":10}}";
}

test "basic" {
	const loc = lspFmtLocation("file:///a.ms", 0, 5, 0, 10);
	assert loc.length > 30;
}

test "basic" {
	const e = lspFmtTextEdit(0, 5, 8, "newName");
	assert e.length > 30;
}

test "basic" {
	const item = lspFmtCompletionItem("foo", 6, "number", "11", false, "", "");
	assert item.length > 20;
}

test "with sortText" {
	const item = lspFmtCompletionItem("bar", 3, "()", "10", false, "", "");
	assert item.length > 20;
}

test "deprecated tag" {
	const item = lspFmtCompletionItem("old", 6, "string", "z11", true, "", "");
	assert item.length > 30;
}

test "commit chars" {
	const item = lspFmtCompletionItem("fn", 3, "()", "11", false, "(.", "");
	assert item.length > 40;
}

test "with documentation" {
	const item = lspFmtCompletionItem("log", 2, "(message: string) => void", "10", false, "(.", "Logs a message to the console.");
	assert item.length > 60;
}

test "code only" {
	const h = lspFmtHoverResult("```ms\n(variable) x: number\n```", "", 0, 5, 6);
	assert h.length > 30;
}

test "with documentation" {
	const h = lspFmtHoverResult("```ms\n(variable) x: number\n```", "(exported)", 3, 0, 4);
	assert h.length > 50;
}

test "without code" {
	const d = lspFmtDiagnostic(0, 5, 8, 1, "type error", "metascript", 0);
	assert d.length > 30;
}

test "with code" {
	const d = lspFmtDiagnostic(0, 5, 8, 1, "type error", "metascript", 2304);
	assert d.length > 40;
}

test "without detail" {
	const s = lspFmtDocumentSymbol("foo", 12, "", 0, 5, 8, "");
	assert s.length > 20;
}

test "with detail" {
	const s = lspFmtDocumentSymbol("foo", 12, "(a: number) => void", 0, 5, 8, "");
	assert s.length > 40;
}

test "with children" {
	const child = lspFmtDocumentSymbol("bar", 6, "() => void", 1, 2, 5, "");
	const s = lspFmtDocumentSymbol("MyClass", 5, "", 0, 0, 7, "[" + child + "]");
	assert s.length > 60;
}

test "type hint" {
	const h = lspFmtInlayHint(0, 5, ": number", 1, true, false);
	assert h.length > 30;
}

test "param hint" {
	const h = lspFmtInlayHint(0, 3, "name:", 2, false, true);
	assert h.length > 30;
}

test "basic" {
	const p = lspFmtSignatureParam("a: number");
	const sig = lspFmtSignature("foo(a: number)", "[" + p + "]");
	const help = lspFmtSignatureHelp("[" + sig + "]", 0, 0);
	assert help.length > 40;
}
