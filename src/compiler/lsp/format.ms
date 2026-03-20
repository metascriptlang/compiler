// LSP Format Helpers — JSON.stringify on anonymous structs
//
// All functions return JSON strings via JSON.stringify({ ... }).
// No manual string concatenation — single allocation per response.

// ===== Position + Range =====

export function lspFmtPosition(line: number, col: number): string {
	return JSON.stringify({ line, character: col });
}

export function lspFmtRange(line: number, col: number, endLine: number, endCol: number): string {
	return JSON.stringify({
		start: { line, character: col },
		end: { line: endLine, character: endCol },
	});
}

export function lspFmtLineRange(line: number, col: number, endCol: number): string {
	return lspFmtRange(line, col, line, endCol);
}

// ===== Location + TextEdit =====

export function lspFmtLocation(uri: string, line: number, col: number, endLine: number, endCol: number): string {
	return JSON.stringify({
		uri,
		range: { start: { line, character: col }, end: { line: endLine, character: endCol } },
	});
}

export function lspFmtTextEdit(line: number, col: number, endCol: number, newText: string): string {
	return JSON.stringify({
		range: { start: { line, character: col }, end: { line, character: endCol } },
		newText,
	});
}

export function lspFmtMultiLineTextEdit(line: number, col: number, endLine: number, endCol: number, newText: string): string {
	return JSON.stringify({
		range: { start: { line, character: col }, end: { line: endLine, character: endCol } },
		newText,
	});
}

// ===== Completion Item =====

export function lspFmtCompletionItem(
	label: string, kind: number, detail: string,
	sortText: string, isDeprecated: boolean, commitChars: string,
	documentation: string, additionalEdits: string,
	cursorLine: number, cursorCol: number, prefixLen: number
): string {
	const item: any = { label, kind, detail, filterText: label };
	if (sortText.length > 0) item.sortText = sortText;
	if (isDeprecated) item.tags = [1];
	if (commitChars.length > 0) {
		const chars: string[] = [];
		let i = 0;
		while (i < commitChars.length) {
			chars.push(commitChars.slice(i, i + 1));
			i = i + 1;
		}
		item.commitCharacters = chars;
	}
	if (documentation.length > 0) {
		item.documentation = { kind: "markdown", value: documentation };
	}
	// textEdit: replace typed prefix with label (enables empty-prefix completion in nvim-cmp)
	if (cursorLine >= 0) {
		item.textEdit = {
			range: { start: { line: cursorLine, character: cursorCol }, end: { line: cursorLine, character: cursorCol + prefixLen } },
			newText: label,
		};
	}
	if (additionalEdits.length > 0) {
		item.additionalTextEdits = JSON.parse(additionalEdits);
	}
	return JSON.stringify(item);
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
	if (line >= 0) {
		return JSON.stringify({
			contents: { kind: "markdown", value: content },
			range: { start: { line, character: col }, end: { line, character: endCol } },
		});
	}
	return JSON.stringify({ contents: { kind: "markdown", value: content } });
}

// ===== Diagnostics =====

export function lspFmtDiagnostic(
	line: number, col: number, endCol: number,
	severity: number, message: string, source: string, code: number
): string {
	if (code > 0) {
		return JSON.stringify({
			range: { start: { line, character: col }, end: { line, character: endCol } },
			severity, source, message, code,
		});
	}
	return JSON.stringify({
		range: { start: { line, character: col }, end: { line, character: endCol } },
		severity, source, message,
	});
}

export function lspFmtPublishDiagnostics(uri: string, diagnosticsArray: string): string {
	return "{\"uri\":" + JSON.stringify(uri) + ",\"diagnostics\":" + diagnosticsArray + "}";
}

// ===== Document Symbol =====

export function lspFmtDocumentSymbol(
	name: string, kind: number, detail: string,
	line: number, col: number, endCol: number,
	childrenJson: string
): string {
	const range = { start: { line, character: col }, end: { line, character: endCol } };
	let result = "{\"name\":" + JSON.stringify(name)
		+ ",\"kind\":" + kind;
	if (detail.length > 0) {
		result = result + ",\"detail\":" + JSON.stringify(detail);
	}
	const rangeStr = JSON.stringify(range);
	result = result + ",\"range\":" + rangeStr + ",\"selectionRange\":" + rangeStr;
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
	return JSON.stringify({
		position: { line, character: col },
		label, kind, paddingLeft, paddingRight,
	});
}

// ===== Document Highlight =====

export function lspFmtDocumentHighlight(line: number, col: number, endCol: number, kind: number): string {
	return JSON.stringify({
		range: { start: { line, character: col }, end: { line, character: endCol } },
		kind,
	});
}

// ===== Signature Help =====

export function lspFmtSignatureParam(label: string): string {
	return JSON.stringify({ label });
}

export function lspFmtSignature(label: string, paramsJson: string): string {
	return "{\"label\":" + JSON.stringify(label) + ",\"parameters\":" + paramsJson + "}";
}

export function lspFmtSignatureHelp(signaturesJson: string, activeSig: number, activeParam: number): string {
	return "{\"signatures\":" + signaturesJson
		+ ",\"activeSignature\":" + activeSig
		+ ",\"activeParameter\":" + activeParam + "}";
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
	const item = lspFmtCompletionItem("foo", 6, "number", "11", false, "", "", "", -1, 0, 0);
	assert item.length > 20;
}

test "completion with sortText" {
	const item = lspFmtCompletionItem("bar", 3, "()", "10", false, "", "", "", -1, 0, 0);
	assert item.length > 20;
}

test "completion deprecated" {
	const item = lspFmtCompletionItem("old", 6, "string", "z11", true, "", "", "", -1, 0, 0);
	assert item.length > 30;
}

test "completion commit chars" {
	const item = lspFmtCompletionItem("fn", 3, "()", "11", false, "(.", "", "", -1, 0, 0);
	assert item.length > 40;
}

test "completion with docs" {
	const item = lspFmtCompletionItem("log", 2, "(message: string) => void", "10", false, "(.", "Logs a message to the console.", "", -1, 0, 0);
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
	const d = lspFmtDiagnostic(0, 5, 8, 1, "type error", "metascript", 0);
	assert d.length > 30;
}

test "diagnostic with code" {
	const d = lspFmtDiagnostic(0, 5, 8, 1, "type error", "metascript", 2304);
	assert d.length > 40;
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
