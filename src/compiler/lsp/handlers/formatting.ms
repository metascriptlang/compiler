// LSP Handlers — Code Actions (quick fixes) and Document Formatting.

import {
	TransAmDb, dbParse, createTransAmDb, dbSetFileText, dbTypeCheck
} from "../../transam/index";
import { writeStderr } from "std/io";
import { lspJsonString, lspGetObjectField, lspGetField, lspGetNumberField, lspGetArrayItems, lspUriToPath, lspResponse, lspErrorResponse } from "../protocol";
import { parseJson } from "std/serialize/json/parser";
import { lspFmtRange, lspFmtTextEdit } from "../format";
import { formatNode } from "../../fmt/printer";
import { FmtPos, formatStatementEdit, innermostStatement, lineOffset, applyEdit } from "../../fmt/edit";
import { checkLossless } from "../../fmt/lossless";
import { registerCoreParsers } from "../../../parser/statements/core";
import { parseSource } from "../../../parser/statements/validation";
import { dbGetSource, lspByteColumn, lspCharacter } from "./shared";
import { getFormatOptions, splitLines, detectLineIndent } from "./diagnostics";


// ===== Formatting =====

let _fmtParsersRegistered = false;

// ===== Code Actions =====
// Quick fixes for format violations — "Fix: Use tabs" etc.
// Cache formatted output to avoid re-formatting on every code action request.
let _codeActionFmtSource = "";
let _codeActionFmtResult = "";

export function handleCodeAction(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);
	const source = dbGetSource(db, path);
	if (source == "") return lspResponse(id, "[]");

	// Get requested range (cursor line)
	const rangeObj = lspGetObjectField(params, "range");
	const startObj = lspGetObjectField(rangeObj, "start");
	const startLine = lspGetNumberField(startObj, "line"); // 0-based

	const lines = splitLines(source);
	if (startLine < 0 || startLine >= lines.length) return lspResponse(id, "[]");

	const line = lines[startLine];
	const info = detectLineIndent(line);
	const actions: string[] = [];

	// Check if this line has a format violation
	const options = getFormatOptions(db, path);
	const isCommentCont = info.indentEnd > 0 && info.indentEnd < line.length && line.byteAt(info.indentEnd) == "*".code;
	const hasIndentIssue = info.indentEnd > 0 && info.indentEnd < line.length && !isCommentCont
		&& (info.isMixed || (options.useTabs && info.hasSpace && !info.hasTab) || (!options.useTabs && info.hasTab && !info.hasSpace));
	const hasTrailingWs = info.trailStart < line.length && info.trailStart > 0;

	if (hasIndentIssue || hasTrailingWs) {
		// Use the formatter as source of truth — get the correctly formatted version of this line.
		// This ensures the fix is identical to what "Format Document" would produce.
		// Cache: reuse formatted output if source unchanged
		if (_codeActionFmtSource != source) {
			if (!_fmtParsersRegistered) {
				registerCoreParsers();
				_fmtParsersRegistered = true;
			}
			const parseResult = parseSource(source);
			if (parseResult.ok) {
				const printed = formatNode(parseResult.value, options);
				_codeActionFmtResult = printed.ok && checkLossless(source, printed.value).ok ? printed.value : "";
			} else {
				_codeActionFmtResult = "";
			}
			_codeActionFmtSource = source;
		}
		if (_codeActionFmtResult.length > 0) {
			const fmtLines = splitLines(_codeActionFmtResult);

			if (startLine < fmtLines.length && fmtLines[startLine] != line) {
				const lineNo = (startLine + 1) as int32;
				const proposed = applyEdit(source, {
					start: { line: lineNo, column: 1 },
					end: { line: lineNo, column: line.byteLength + 1 },
					newText: fmtLines[startLine],
				});
				if (!checkLossless(source, proposed).ok) return lspResponse(id, "[]");
				const edit = lspFmtTextEdit(startLine, 0, line.length, fmtLines[startLine]);
				const changesJson = "{" + lspJsonString(uri) + ":[" + edit + "]}";
				const title = hasIndentIssue ? "Fix: Reformat this line" : "Fix: Remove trailing whitespace";
				actions.push("{\"title\":" + lspJsonString(title) + ",\"kind\":\"quickfix\",\"isPreferred\":true,\"edit\":{\"changes\":" + changesJson + "}}");
			}
		}
	}

	return lspResponse(id, "[" + actions.join(",") + "]");
}

export function handleFormatting(id: string, params: string, db: TransAmDb): string {
	const t0 = performance.now();
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);
	const source = dbGetSource(db, path);
	if (source == "") return lspResponse(id, "[]");

	const t1 = performance.now();
	const program = dbParse(db, path);
	if (program == null) return lspResponse(id, "[]");
	const t2 = performance.now();

	const options = getFormatOptions(db, path);
	options.source = source;
	const printed = formatNode(program, options);
	if (!printed.ok) return lspErrorResponse(id, -32603, printed.error);
	const formatted = printed.value;
	const kept = checkLossless(source, formatted);
	if (!kept.ok) return lspErrorResponse(id, -32603, "fmt refused: " + kept.error);
	const t4 = performance.now();

	writeStderr(`[LSP-FMT] ${path} parse=${t2 - t1}ms print=${t4 - t2}ms source=${source.byteLength}b\n`);

	if (formatted.byteLength == source.byteLength && formatted == source) return lspResponse(id, "[]");

	let lineCount = 0;
	let lastNl = -1;
	for (let i = 0; i < source.byteLength; i = i + 1) {
		if (source.byteAt(i) == "\n".code) { lineCount = lineCount + 1; lastNl = i; }
	}
	const lastLineLen = source.byteSlice(lastNl + 1, source.byteLength).length;
	const range = lspFmtRange(0, 0, lineCount, lastLineLen);
	const t5 = performance.now();
	const edit = "{\"range\":" + range + ",\"newText\":" + lspJsonString(formatted) + "}";
	const t6 = performance.now();
	writeStderr(`[LSP-FMT] json=${t6 - t5}ms total=${t6 - t0}ms lines=${lineCount} lastLineLen=${lastLineLen} responseLen=${edit.length}\n`);
	return lspResponse(id, "[" + edit + "]");
}

function formattingBytePosition(source: string, position: string): Result<FmtPos, string> {
	const line = (lspGetNumberField(position, "line") + 1) as int32;
	const character = lspGetNumberField(position, "character") as int32;
	if (line < 1 || character < 0) return Result.err("Formatting position requires non-negative line and character");
	return Result.ok({ line, column: lspByteColumn(source, line, character) });
}

export function handleRangeFormatting(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);
	const source = dbGetSource(db, path);
	if (source == "") return lspResponse(id, "[]");

	const range = lspGetObjectField(params, "range");
	const rs = lspGetObjectField(range, "start");
	const re = lspGetObjectField(range, "end");
	const from = formattingBytePosition(source, rs);
	if (!from.ok) return lspErrorResponse(id, -32602, from.error);
	const to = formattingBytePosition(source, re);
	if (!to.ok) return lspErrorResponse(id, -32602, to.error);

	if (!_fmtParsersRegistered) {
		registerCoreParsers();
		_fmtParsersRegistered = true;
	}
	const parsed = parseSource(source);
	if (!parsed.ok) return lspResponse(id, "[]");
	const stmt = innermostStatement(parsed.value, from.value, to.value);
	if (stmt == null) return lspResponse(id, "[]");

	const edit = formatStatementEdit(stmt, source, getFormatOptions(db, path));
	if (!edit.ok) return lspErrorResponse(id, -32603, edit.error);
	const e = edit.value;
	const kept = checkLossless(source, applyEdit(source, e));
	if (!kept.ok) return lspErrorResponse(id, -32603, "fmt refused: " + kept.error);
	const startOffset = lineOffset(source, e.start.line) + e.start.column - 1;
	const endOffset = lineOffset(source, e.end.line) + e.end.column - 1;
	if (source.byteSlice(startOffset, endOffset) == e.newText) return lspResponse(id, "[]");

	const startCharacter = lspCharacter(source, e.start.line, e.start.column);
	const endCharacter = lspCharacter(source, e.end.line, e.end.column);
	const lspRange = lspFmtRange(e.start.line - 1, startCharacter, e.end.line - 1, endCharacter);
	return lspResponse(id, "[{\"range\":" + lspRange + ",\"newText\":" + lspJsonString(e.newText) + "}]");
}

function formattingDb(source: string): TransAmDb {
	const db = createTransAmDb(8);
	dbSetFileText(db, lspUriToPath("file:///fmt/probe.ms"), source);
	return db;
}

const FORMAT_PARAMS = "{\"textDocument\":{\"uri\":\"file:///fmt/probe.ms\"}}";
const RANGE_PARAMS = "{\"textDocument\":{\"uri\":\"file:///fmt/probe.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":1,\"character\":5}}}";
const LOSSY = "const x = a // why a\n\t+ b;\n";

test "document formatting refuses an edit that changes a token" {
	assert handleFormatting("1", FORMAT_PARAMS, formattingDb(LOSSY)).contains("fmt refused");
}

test "range formatting refuses an edit that changes a token" {
	assert handleRangeFormatting("1", RANGE_PARAMS, formattingDb(LOSSY)).contains("fmt refused");
}

test "document formatting still edits a lossless source" {
	assert handleFormatting("1", FORMAT_PARAMS, formattingDb("const  a=1;\n")).contains("newText");
}

function formattingItems(response: string): string[] {
	const parsed = parseJson(response);
	if (!parsed.ok) throw new Error(parsed.error);
	const items = lspGetObjectField(response, "result");
	if (lspGetNumberField(response, "id") != 1 || !items.startsWith("[")) throw new Error("Expected formatting result: " + response);
	return lspGetArrayItems(items);
}

function quickfixItems(source: string): string[] {
	const params = "{\"textDocument\":{\"uri\":\"file:///fmt/probe.ms\"},\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}}}";
	return formattingItems(handleCodeAction("1", params, formattingDb(source)));
}

function quickfixEdit(action: string): string {
	const changes = lspGetObjectField(lspGetObjectField(action, "edit"), "changes");
	const edits = lspGetArrayItems(lspGetObjectField(changes, "file:///fmt/probe.ms"));
	if (edits.length != 1) throw new Error("Expected one quickfix edit: " + action);
	return edits[0];
}

test "indent quickfix refuses an edit that drops an adjacent statement" {
	const source = "export function f(): int32 {\n \tconst x = 1; const y = 2;\n\treturn x + y;\n}\n";
	assert quickfixItems(source).length == 0;
}

test "trailing-space quickfix refuses an edit that drops an adjacent statement" {
	const source = "export function f(): int32 {\n    const x = 1; const y = 2;   \n\treturn x + y;\n}\n";
	assert quickfixItems(source).length == 0;
}

test "safe quickfix edits preserve surrounding text and still parse and check" {
	const prefix = "export function f(): int32 {\n";
	const suffix = "\n\treturn x;\n}\n";
	for (const line of [" \tconst x = 1;", "    const x = 1;   "]) {
		const source = prefix + line + suffix;
		const actions = quickfixItems(source);
		assert actions.length == 1;
		const result = applyClientUtf16Edit(source, quickfixEdit(actions[0]));
		assert result != source;
		assert result.startsWith(prefix);
		assert result.endsWith(suffix);
		assert checkLossless(source, result).ok;
		assert parseSource(result).ok;
		assert dbTypeCheck(formattingDb(result), "/fmt/probe.ms").errors.length == 0;
	}
}

function clientUtf16Offset(source: string, line: int32, character: int32): int32 {
	const lines = source.split("\n");
	if (line < 0 || line >= lines.length || character < 0) throw new Error("Invalid client position");
	const text = lines[line];
	const length = text.endsWith("\r") ? text.length - 1 : text.length;
	let offset = character > length ? length : character;
	for (let i = 0; i < line; i += 1) offset += lines[i].length + 1;
	return offset;
}

function applyClientUtf16Edit(source: string, edit: string): string {
	const range = lspGetObjectField(edit, "range");
	const start = lspGetObjectField(range, "start");
	const end = lspGetObjectField(range, "end");
	const from = clientUtf16Offset(source, lspGetNumberField(start, "line") as int32, lspGetNumberField(start, "character") as int32);
	const to = clientUtf16Offset(source, lspGetNumberField(end, "line") as int32, lspGetNumberField(end, "character") as int32);
	if (to < from) throw new Error("Reversed client edit: " + edit);
	return source.slice(0, from) + lspGetField(edit, "newText") + source.slice(to, source.length);
}

function assertDocumentUtf16(text: string, endCharacter: int32): void {
	const source = "export const s=\"" + text + "\";";
	const edits = formattingItems(handleFormatting("1", FORMAT_PARAMS, formattingDb(source)));
	if (edits.length != 1) throw new Error("Expected one document edit");
	const range = lspGetObjectField(edits[0], "range");
	const start = lspGetObjectField(range, "start");
	const end = lspGetObjectField(range, "end");
	if (lspGetNumberField(start, "character") != 0 || lspGetNumberField(end, "character") != endCharacter) throw new Error("Wrong document UTF-16 range: " + edits[0]);
	const result = applyClientUtf16Edit(source, edits[0]);
	if (result != "export const s = \"" + text + "\";\n") throw new Error("Wrong formatted document: " + result);
	if (!parseSource(result).ok || dbTypeCheck(formattingDb(result), "/fmt/probe.ms").errors.length != 0) throw new Error("Formatted document must parse and check");
}

function assertRangeUtf16(text: string, startCharacter: int32, endCharacter: int32): void {
	const prefix = "export const s=\"" + text + "\"; ";
	const source = prefix + "export const   n=2;";
	const character = startCharacter + 1;
	const params = `{"textDocument":{"uri":"file:///fmt/probe.ms"},"range":{"start":{"line":0,"character":${character}},"end":{"line":0,"character":${character}}}}`;
	const edits = formattingItems(handleRangeFormatting("1", params, formattingDb(source)));
	if (edits.length != 1) throw new Error("Expected one range edit for " + text);
	const range = lspGetObjectField(edits[0], "range");
	const start = lspGetObjectField(range, "start");
	const end = lspGetObjectField(range, "end");
	if (lspGetNumberField(start, "character") != startCharacter || lspGetNumberField(end, "character") != endCharacter) throw new Error("Wrong selected statement or UTF-16 range: " + edits[0]);
	const result = applyClientUtf16Edit(source, edits[0]);
	if (result != prefix + "export const n = 2;") throw new Error("Range edit changed surrounding text: " + result);
	if (!checkLossless(source, result).ok || !parseSource(result).ok || dbTypeCheck(formattingDb(result), "/fmt/probe.ms").errors.length != 0) throw new Error("Range edit must preserve tokens, parse and check");
}

test "formatting position clamps inside an astral pair to its start" {
	const before = formattingBytePosition("é😀z", "{\"line\":0,\"character\":1}");
	const inside = formattingBytePosition("é😀z", "{\"line\":0,\"character\":2}");
	const after = formattingBytePosition("é😀z", "{\"line\":0,\"character\":3}");
	assert before.ok && inside.ok && after.ok;
	assert before.value.column == 3;
	assert inside.value.column == 3;
	assert after.value.column == 7;
}

test "range formatting reports invalid position parameters" {
	const db = formattingDb("export const x=1;");
	for (const position of ["{\"line\":0,\"character\":-1}", "{\"line\":-1,\"character\":0}", "{}"]) {
		const params = `{"textDocument":{"uri":"file:///fmt/probe.ms"},"range":{"start":${position},"end":${position}}}`;
		const response = handleRangeFormatting("1", params, db);
		assert parseJson(response).ok;
		assert lspGetNumberField(response, "id") == 1;
		assert lspGetNumberField(lspGetObjectField(response, "error"), "code") == -32602;
	}
}

test "formatting client fixture slices count UTF-16 units" {
	const text = "é😀日";
	assert text.length == 4;
	assert text.byteLength == 9;
	assert text.slice(0, 1) == "é";
	assert text.slice(0, 3) == "é😀";
	assert text.byteSlice(0, 6).length == 3;
}

test "document formatting ASCII coordinate control" {
	assertDocumentUtf16("x", 19);
}

test "document formatting ends at BMP UTF-16 position" {
	assertDocumentUtf16("ééé", 21);
}

test "document formatting ends at astral UTF-16 position" {
	assertDocumentUtf16("😀😀😀", 24);
}

test "range formatting ASCII coordinate control" {
	assertRangeUtf16("x", 20, 39);
}

test "range formatting selects and edits after BMP text" {
	assertRangeUtf16("ééé", 22, 41);
}

test "range formatting selects and edits after astral text" {
	assertRangeUtf16("😀😀😀", 25, 44);
}

function assertFormattedBuffer(source: string, result: string): void {
	if (!checkLossless(source, result).ok || !parseSource(result).ok || dbTypeCheck(formattingDb(result), "/fmt/probe.ms").errors.length != 0) throw new Error("Applied edit must preserve tokens, parse and check");
}

function assertMultilineDocument(eol: string): void {
	const source = "export const first=\"é😀\";" + eol + "export const last=\"日😀\";";
	const edits = formattingItems(handleFormatting("1", FORMAT_PARAMS, formattingDb(source)));
	if (edits.length != 1) throw new Error("Expected multiline document edit");
	const range = lspGetObjectField(edits[0], "range");
	const start = lspGetObjectField(range, "start");
	const end = lspGetObjectField(range, "end");
	if (lspGetNumberField(start, "line") != 0 || lspGetNumberField(start, "character") != 0 || lspGetNumberField(end, "line") != 1 || lspGetNumberField(end, "character") != 24) throw new Error("Wrong multiline document range: " + edits[0]);
	const result = applyClientUtf16Edit(source, edits[0]);
	if (!result.contains("export const first = \"é😀\";") || !result.contains("export const last = \"日😀\";")) throw new Error("Missing formatted declarations");
	assertFormattedBuffer(source, result);
	if (formattingItems(handleFormatting("1", FORMAT_PARAMS, formattingDb(result))).length != 0) throw new Error("Document formatting is not idempotent");
}

function assertMultilineRange(eol: string): void {
	const prefix = "export const first=\"é😀\";" + eol + "export const second=\"😀\"; ";
	const suffix = eol + "export const last=\"日\";" + eol;
	const source = prefix + "export const   n=2;" + suffix;
	const params = "{\"textDocument\":{\"uri\":\"file:///fmt/probe.ms\"},\"range\":{\"start\":{\"line\":1,\"character\":27},\"end\":{\"line\":1,\"character\":27}}}";
	const edits = formattingItems(handleRangeFormatting("1", params, formattingDb(source)));
	if (edits.length != 1) throw new Error("Expected multiline range edit");
	const range = lspGetObjectField(edits[0], "range");
	const start = lspGetObjectField(range, "start");
	const end = lspGetObjectField(range, "end");
	if (lspGetNumberField(start, "line") != 1 || lspGetNumberField(start, "character") != 26 || lspGetNumberField(end, "line") != 1 || lspGetNumberField(end, "character") != 45) throw new Error("Wrong multiline statement range: " + edits[0]);
	const result = applyClientUtf16Edit(source, edits[0]);
	if (result != prefix + "export const n = 2;" + suffix) throw new Error("Multiline range edit changed surrounding text");
	assertFormattedBuffer(source, result);
	if (formattingItems(handleRangeFormatting("1", params, formattingDb(result))).length != 0) throw new Error("Range formatting is not idempotent");
}

function assertUnicodeQuickfix(eol: string, line: string, endCharacter: int32): void {
	const prefix = "export function f(): string {" + eol;
	const suffix = eol + "\treturn x;" + eol + "}" + eol;
	const source = prefix + line + suffix;
	const actions = quickfixItems(source);
	if (actions.length != 1) throw new Error("Expected Unicode quickfix");
	const edit = quickfixEdit(actions[0]);
	const range = lspGetObjectField(edit, "range");
	const start = lspGetObjectField(range, "start");
	const end = lspGetObjectField(range, "end");
	if (lspGetNumberField(start, "line") != 1 || lspGetNumberField(start, "character") != 0 || lspGetNumberField(end, "line") != 1 || lspGetNumberField(end, "character") != endCharacter) throw new Error("Quickfix range must exclude the line ending: " + edit);
	const result = applyClientUtf16Edit(source, edit);
	if (!result.startsWith(prefix) || !result.endsWith(suffix) || lspGetField(edit, "newText").trim() != "const x = \"é😀\";") throw new Error("Quickfix changed surrounding text");
	assertFormattedBuffer(source, result);
	if (quickfixItems(result).length != 0) throw new Error("Quickfix is not idempotent");
}

test "client offsets count UTF-16 across LF and CRLF" {
	assert clientUtf16Offset("é😀\n日", 1, 1) == 5;
	assert clientUtf16Offset("é😀\r\n日", 1, 1) == 6;
	assert clientUtf16Offset("é😀\r\n日", 0, 100) == 3;
}

test "document edits apply and stabilize across Unicode LF lines" {
	assertMultilineDocument("\n");
}

test "document edits apply and stabilize across Unicode CRLF lines" {
	assertMultilineDocument("\r\n");
}

test "range edits preserve Unicode LF lines outside the statement" {
	assertMultilineRange("\n");
}

test "range edits preserve Unicode CRLF lines outside the statement" {
	assertMultilineRange("\r\n");
}

test "mixed-indent Unicode quickfix preserves LF surroundings" {
	assertUnicodeQuickfix("\n", " \tconst x = \"é😀\";", 18);
}

test "mixed-indent Unicode quickfix preserves CRLF surroundings" {
	assertUnicodeQuickfix("\r\n", " \tconst x = \"é😀\";", 18);
}

test "trailing-space Unicode quickfix preserves LF surroundings" {
	assertUnicodeQuickfix("\n", "const x = \"é😀\";   ", 19);
}

test "trailing-space Unicode quickfix preserves CRLF surroundings" {
	assertUnicodeQuickfix("\r\n", "const x = \"é😀\";   ", 19);
}
