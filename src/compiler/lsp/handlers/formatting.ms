// LSP Handlers — Code Actions (quick fixes) and Document Formatting.

import {
	TransAmDb, dbParse, createTransAmDb, dbSetFileText, dbTypeCheck
} from "../../transam/index";
import { writeStderr } from "std/io";
import { lspJsonString, lspGetObjectField, lspGetField, lspGetNumberField, lspGetArrayItems, lspUriToPath, lspResponse, lspErrorResponse } from "../protocol";
import { parseJson } from "std/serialize/json/parser";
import { lspFmtMultiLineTextEdit, lspFmtQuickFix, lspFmtTextEdit } from "../format";
import { formatNode } from "../../fmt/printer";
import { FmtPos, StatementRun, formatRunEdits, rangeStatements, applyEdit, lineOffset } from "../../fmt/edit";
import { LineIndex, lineStart } from "../../../utils/sourceLines";
import { lspByteColumn, lspByteColumnIn, lspCharacterIn } from "../position";
import { checkLossless } from "../../fmt/lossless";
import { ByteEdit, diffTextEdits } from "../../fmt/textEdit";
import { registerCoreParsers } from "../../../parser/statements/core";
import { parseSource } from "../../../parser/statements/validation";
import { dbGetSource, lspDocumentUri } from "./shared";
import { getFormatOptions } from "./diagnostics";
import { splitLines, detectLineIndent, indentFault } from "./formatLint";


// ===== Formatting =====

let _fmtParsersRegistered = false;

// ===== Code Actions =====
// Quick fixes for format violations — "Fix: Use tabs" etc.
// Cache formatted output to avoid re-formatting on every code action request.
let _codeActionFmtSource = "";
let _codeActionFmtResult = "";

export function handleCodeAction(id: string, params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
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
	const hasIndentIssue = indentFault(line, info, options.useTabs) !== null;
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
			options.source = source;
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
				actions.push(lspFmtQuickFix(title, changesJson));
			}
		}
	}

	return lspResponse(id, "[" + actions.join(",") + "]");
}

export function handleFormatting(id: string, params: string, db: TransAmDb): string {
	const t0 = performance.now();
	const uri = lspDocumentUri(params);
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

	const edits = textEditsJson(source, diffTextEdits(source, formatted), 0);
	if (!edits.ok) return lspErrorResponse(id, -32603, edits.error);
	writeStderr(`[LSP-FMT] total=${performance.now() - t0}ms\n`);
	return lspResponse(id, "[" + edits.value + "]");
}

interface LspPosition {
	line: int32;
	character: int32;
}

function lspPositionAt(lines: LineIndex, source: string, offset: int32): Result<LspPosition, string> {
	if (offset < 0 || offset > source.byteLength) return Result.err(`Formatting edit offset ${offset} is outside the document`);
	const line = lines.lineOf(offset);
	const column = offset - lines.lineStart(line) + 1;
	const character = lspCharacterIn(lines, source, line, column);
	if (lspByteColumnIn(lines, source, line, character) != column) return Result.err(`Formatting edit offset ${offset} has no UTF-16 position`);
	return Result.ok({ line: line - 1, character });
}

// Edits are byte offsets into a slice of `source` starting at `base`.
function textEditsJson(source: string, edits: ByteEdit[], base: int32): Result<string, string> {
	const lines = LineIndex.build(source);
	const items: string[] = [];
	for (const edit of edits) {
		const from = try lspPositionAt(lines, source, base + edit.start);
		const to = try lspPositionAt(lines, source, base + edit.end);
		items.push(lspFmtMultiLineTextEdit(from.line, from.character, to.line, to.character, edit.newText));
	}
	return Result.ok(items.join(","));
}

function formattingBytePosition(source: string, position: string): Result<FmtPos, string> {
	const line = (lspGetNumberField(position, "line") + 1) as int32;
	const character = lspGetNumberField(position, "character") as int32;
	if (line < 1 || character < 0) return Result.err("Formatting position requires non-negative line and character");
	return Result.ok({ line, column: lspByteColumn(source, line, character) });
}

export function handleRangeFormatting(id: string, params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
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
	const stmts = rangeStatements(parsed.value, from.value, to.value);
	if (!stmts.ok) return lspErrorResponse(id, -32603, stmts.error);
	if (stmts.value == null) return lspResponse(id, "[]");

	return formatRunResponse(id, source, db, path, stmts.value);
}

function formatRunResponse(id: string, source: string, db: TransAmDb, path: string, run: StatementRun): string {
	const edits = formatRunEdits(run, source, getFormatOptions(db, path));
	if (!edits.ok) return lspErrorResponse(id, -32603, edits.error);
	let result = source;
	for (let i = edits.value.length - 1; i >= 0; i -= 1) {
		const e = edits.value[i];
		result = result.byteSlice(0, e.start) + e.newText + result.byteSlice(e.end, result.byteLength);
	}
	const kept = checkLossless(source, result);
	if (!kept.ok) return lspErrorResponse(id, -32603, "fmt refused: " + kept.error);
	const items = textEditsJson(source, edits.value, 0);
	if (!items.ok) return lspErrorResponse(id, -32603, items.error);
	return lspResponse(id, "[" + items.value + "]");
}

export function handleOnTypeFormatting(id: string, params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
	const path = lspUriToPath(uri);
	const source = dbGetSource(db, path);
	if (source == "") return lspResponse(id, "[]");

	const typed = lspGetField(params, "ch");
	if (typed != ";" && typed != "}") return lspResponse(id, "[]");
	const cursor = formattingBytePosition(source, lspGetObjectField(params, "position"));
	if (!cursor.ok) return lspErrorResponse(id, -32602, cursor.error);
	const offset = lineOffset(source, cursor.value.line) + cursor.value.column - 1;
	if (offset < 1 || offset > source.byteLength || source.byteSlice(offset - 1, offset) != typed) return lspResponse(id, "[]");

	if (!_fmtParsersRegistered) {
		registerCoreParsers();
		_fmtParsersRegistered = true;
	}
	const parsed = parseSource(source);
	if (!parsed.ok) return lspResponse(id, "[]");
	const typedAt: FmtPos = { line: cursor.value.line, column: cursor.value.column - 1 };
	const run = rangeStatements(parsed.value, typedAt, typedAt);
	if (!run.ok) return lspErrorResponse(id, -32603, run.error);
	if (run.value == null) return lspResponse(id, "[]");
	const end = run.value.last.location;
	if (end.endLine != cursor.value.line || end.endColumn != cursor.value.column) return lspResponse(id, "[]");
	return formatRunResponse(id, source, db, path, run.value);
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

function editCharacter(edit: string, side: string, field: string): int32 {
	return lspGetNumberField(lspGetObjectField(lspGetObjectField(edit, "range"), side), field) as int32;
}

function assertEditsWithin(edits: string[], line: int32, from: int32, to: int32): void {
	if (edits.length == 0) throw new Error("Expected at least one edit");
	for (const edit of edits) {
		const inside = editCharacter(edit, "start", "line") == line && editCharacter(edit, "end", "line") == line;
		if (!inside || editCharacter(edit, "start", "character") < from || editCharacter(edit, "end", "character") > to) throw new Error("Edit leaves the formatted span: " + edit);
	}
}

function assertDocumentUtf16(text: string, endCharacter: int32): void {
	const source = "export const s=\"" + text + "\";";
	const edits = formattingItems(handleFormatting("1", FORMAT_PARAMS, formattingDb(source)));
	const last = edits[edits.length - 1];
	if (editCharacter(last, "end", "line") != 0 || editCharacter(last, "end", "character") != endCharacter) throw new Error("Wrong document UTF-16 end: " + last);
	const result = applyClientUtf16Edits(source, edits);
	if (result != "export const s = \"" + text + "\";\n") throw new Error("Wrong formatted document: " + result);
	if (!parseSource(result).ok || dbTypeCheck(formattingDb(result), "/fmt/probe.ms").errors.length != 0) throw new Error("Formatted document must parse and check");
}

function assertRangeUtf16(text: string, startCharacter: int32, endCharacter: int32): void {
	const prefix = "export const s=\"" + text + "\"; ";
	const source = prefix + "export const   n=2;";
	const character = startCharacter + 1;
	const params = `{"textDocument":{"uri":"file:///fmt/probe.ms"},"range":{"start":{"line":0,"character":${character}},"end":{"line":0,"character":${character}}}}`;
	const edits = formattingItems(handleRangeFormatting("1", params, formattingDb(source)));
	assertEditsWithin(edits, 0, startCharacter, endCharacter);
	const result = applyClientUtf16Edits(source, edits);
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
	const last = edits[edits.length - 1];
	if (editCharacter(last, "end", "line") != 1 || editCharacter(last, "end", "character") != 24) throw new Error("Wrong multiline document end: " + last);
	const result = applyClientUtf16Edits(source, edits);
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
	assertEditsWithin(edits, 1, 26, 45);
	const result = applyClientUtf16Edits(source, edits);
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

function quickfixText(source: string): string {
	const actions = quickfixItems(source);
	if (actions.length != 1) throw new Error("Expected one quickfix, got " + actions.length.toString());
	return lspGetField(quickfixEdit(actions[0]), "newText");
}

test "indent quickfix keeps each literal spelled as written" {
	const prefix = "export function f(): string {\n";
	const suffix = "\n\treturn x;\n}\n";
	for (const literal of ["'a'", "\"a\\u0041\"", "`a${1}`"]) {
		const source = prefix + " \tconst x = " + literal + ";" + suffix;
		const result = prefix + "  const x = " + literal + ";" + suffix;
		assert quickfixText(source) == "  const x = " + literal + ";";
		assertFormattedBuffer(source, result);
	}
}

test "indent quickfix reads its own buffer after another document was formatted" {
	const source = "export function f(): string {\n \tconst x = \"a\";\n\treturn x;\n}\n";
	handleFormatting("1", FORMAT_PARAMS, formattingDb("export const a = 1;\nconst x12 = 'zzzz';\n"));
	assert quickfixText(source) == "  const x = \"a\";";
}

function applyClientUtf16Edits(source: string, edits: string[]): string {
	let result = source;
	for (let i = edits.length - 1; i >= 0; i -= 1) result = applyClientUtf16Edit(result, edits[i]);
	return result;
}

function assertOneLineChange(eol: string, value: string): void {
	const head = "export const a = \"é😀\";" + eol;
	const tail = "export const last = 3;" + eol;
	const source = head + "export const   b = " + value + ";" + eol + tail;
	const edits = formattingItems(handleFormatting("1", FORMAT_PARAMS, formattingDb(source)));
	assertEditsWithin(edits, 1, 0, 1000);
	if (applyClientUtf16Edits(source, edits) != head + "export const b = " + value + ";" + eol + tail) throw new Error("Edits do not reproduce the formatted text");
}

test "document formatting edits only the line that changes" {
	assertOneLineChange("\n", "2");
}

test "document formatting edits only the changed line holding non-ASCII text" {
	assertOneLineChange("\n", "\"é😀\"");
}

test "document formatting turns CRLF into LF with one edit per line break and one edit for the changed line" {
	const source = "export const a = \"é😀\";\r\nexport const   b = \"日😀\";\r\nexport const last = 3;\r\n";
	const edits = formattingItems(handleFormatting("1", FORMAT_PARAMS, formattingDb(source)));
	if (applyClientUtf16Edits(source, edits) != "export const a = \"é😀\";\nexport const b = \"日😀\";\nexport const last = 3;\n") throw new Error("Edits do not reproduce the formatted text");
	let inline = 0;
	for (const edit of edits) {
		if (lspGetField(edit, "newText") != "\n") {
			assertEditsWithin([edit], 1, 0, 1000);
			inline += 1;
		}
	}
	assert inline == 1;
	assert edits.length == 4;
}

function rangeFormatted(source: string, startLine: int32, startCharacter: int32, endLine: int32, endCharacter: int32): string {
	const params = `{"textDocument":{"uri":"file:///fmt/probe.ms"},"range":{"start":{"line":${startLine},"character":${startCharacter}},"end":{"line":${endLine},"character":${endCharacter}}}}`;
	const result = applyClientUtf16Edits(source, formattingItems(handleRangeFormatting("1", params, formattingDb(source))));
	assertFormattedBuffer(source, result);
	return result;
}

const TWO_LOOSE = "export function f(): int32 {\n\tconst  x=1;\n\tconst   y=2;\n\treturn x+y;\n}\n";
const TWO_TIDY = "export function f(): int32 {\n  const x = 1;\n  const y = 2;\n\treturn x+y;\n}\n";

test "range over two statements formats both and leaves the third alone" {
	assert rangeFormatted(TWO_LOOSE, 1, 0, 2, 14) == TWO_TIDY;
}

test "range starting mid-statement and ending in the next one formats both statements" {
	assert rangeFormatted(TWO_LOOSE, 1, 9, 2, 8) == TWO_TIDY;
}

test "range over statements in a nested block formats the run inside the block" {
	const source = "export function f(c: boolean): int32 {\n\tlet z=0;\n\tif (c) {\n\t\tconst  x=1;\n\t\tconst   y=2;\n\t\tz=x+y;\n\t}\n\treturn z;\n}\n";
	const expected = "export function f(c: boolean): int32 {\n\tlet z=0;\n\tif (c) {\n\t  const x = 1;\n\t  const y = 2;\n\t\tz=x+y;\n\t}\n\treturn z;\n}\n";
	assert rangeFormatted(source, 3, 2, 4, 5) == expected;
}

test "range over a statement and one in an outer block formats the enclosing statements" {
	const source = "export function f(c: boolean): int32 {\n\tlet  z=0;\n\tif (c) {\n\t\tz=1;\n\t}\n\treturn  z;\n}\n";
	const expected = "export function f(c: boolean): int32 {\n  let z = 0;\n  if (c) { z = 1; }\n  return z;\n}\n";
	assert rangeFormatted(source, 1, 0, 5, 5) == expected;
}

test "range formatting keeps one blank line between covered statements and squeezes more" {
	const source = "const  a=1;\n\n\n\nconst   b=2;\nconst c = 3;\n";
	assert rangeFormatted(source, 0, 0, 4, 3) == "const a = 1;\n\nconst b = 2;\nconst c = 3;\n";
}

test "range formatting joins covered statements of a block without blank lines, as the document does" {
	const source = "export function f(): int32 {\n\tconst  x=1;\n\n\n\tconst   y=2;\n\treturn x+y;\n}\n";
	assert rangeFormatted(source, 1, 0, 4, 14) == TWO_TIDY;
}

test "range over two class members formats the whole class declaration" {
	const source = "export class C {\n\tx:   int32=1;\n\ty:   int32=2;\n\tz:   int32=3;\n}\n";
	const expected = "export class C {\n  x: int32 = 1;\n  y: int32 = 2;\n  z: int32 = 3;\n}\n";
	assert rangeFormatted(source, 1, 0, 2, 5) == expected;
}

test "range formatting over a run is idempotent" {
	const once = rangeFormatted(TWO_LOOSE, 1, 0, 2, 14);
	assert rangeFormatted(once, 1, 0, 2, 14) == once;
}

function onTypeFormatted(source: string, line: int32, character: int32, ch: string): string {
	const params = `{"textDocument":{"uri":"file:///fmt/probe.ms"},"position":{"line":${line},"character":${character}},"ch":"${ch}","options":{"tabSize":2,"insertSpaces":true}}`;
	const result = applyClientUtf16Edits(source, formattingItems(handleOnTypeFormatting("1", params, formattingDb(source))));
	assertFormattedBuffer(source, result);
	return result;
}

test "semicolon formats the statement it ends and leaves its neighbours alone" {
	assert onTypeFormatted(TWO_LOOSE, 1, 12, ";") == "export function f(): int32 {\n\tconst x = 1;\n\tconst   y=2;\n\treturn x+y;\n}\n";
}

test "semicolon formats the statement one block deeper and after a non-ASCII line" {
	const source = "const s = \"h\u{e9}llo \u{1F600}\";\nexport function f(c: boolean): int32 {\n\tif (c) {\n\t\tconst  x=1;\n\t\tconst   y=2;\n\t}\n\treturn 0;\n}\n";
	const expected = "const s = \"h\u{e9}llo \u{1F600}\";\nexport function f(c: boolean): int32 {\n\tif (c) {\n\t\tconst x = 1;\n\t\tconst   y=2;\n\t}\n\treturn 0;\n}\n";
	assert onTypeFormatted(source, 3, 13, ";") == expected;
}

test "closing brace formats the block it closes" {
	const source = "export function f(c: boolean): int32 {\n\tlet  z=0;\n\tif (c) {\n\t\tz=1;\n\t}\n\treturn  z;\n}\n";
	assert onTypeFormatted(source, 4, 2, "}") == "export function f(c: boolean): int32 {\n\tlet  z=0;\n\tif (c) { z = 1; }\n\treturn  z;\n}\n";
}

test "on-type formatting answers no edit when the source does not parse" {
	const params = "{\"textDocument\":{\"uri\":\"file:///fmt/probe.ms\"},\"position\":{\"line\":0,\"character\":10},\"ch\":\";\"}";
	assert formattingItems(handleOnTypeFormatting("1", params, formattingDb("const  x=;\nconst   y=2;\n"))).length == 0;
}

test "on-type formatting answers no edit when the typed character is not at the cursor" {
	assert onTypeFormatted(TWO_LOOSE, 1, 11, ";") == TWO_LOOSE;
	assert onTypeFormatted(TWO_LOOSE, 1, 12, "}") == TWO_LOOSE;
}
