// LSP Handlers — Code Actions (quick fixes) and Document Formatting.

import {
	TransAmDb, dbParse
} from "../../transam/index";
import { clockMs } from "std/process";
import { writeStderr } from "std/io";
import { lspJsonString, lspGetObjectField, lspGetField, lspGetNumberField, lspUriToPath, lspResponse } from "../protocol";
import { lspFmtRange, lspFmtTextEdit } from "../format";
import { printNode as printFormattedNode } from "../../fmt/printer";
import { formatDoc } from "../../fmt/layout";
import { registerCoreParsers } from "../../../parser/statements/core";
import { parseSource } from "../../../parser/statements/validation";
import { dbGetSource } from "./shared";
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
	if (source === "") return lspResponse(id, "[]");

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
	const options = getFormatOptions(db);
	const isCommentCont = info.indentEnd > 0 && info.indentEnd < line.length && line.byteAt(info.indentEnd) === "*".code;
	const hasIndentIssue = info.indentEnd > 0 && info.indentEnd < line.length && !isCommentCont
		&& (info.isMixed || (options.useTabs && info.hasSpace && !info.hasTab) || (!options.useTabs && info.hasTab && !info.hasSpace));
	const hasTrailingWs = info.trailStart < line.length && info.trailStart > 0;

	if (hasIndentIssue || hasTrailingWs) {
		// Use the formatter as source of truth — get the correctly formatted version of this line.
		// This ensures the fix is identical to what "Format Document" would produce.
		// Cache: reuse formatted output if source unchanged
		if (_codeActionFmtSource !== source) {
			if (!_fmtParsersRegistered) {
				registerCoreParsers();
				_fmtParsersRegistered = true;
			}
			const parseResult = parseSource(source);
			if (parseResult.ok) {
				const doc = printFormattedNode(parseResult.value, options);
				_codeActionFmtResult = formatDoc(doc, options);
			} else {
				_codeActionFmtResult = "";
			}
			_codeActionFmtSource = source;
		}
		if (_codeActionFmtResult.length > 0) {
			const fmtLines = splitLines(_codeActionFmtResult);

			if (startLine < fmtLines.length && fmtLines[startLine] !== line) {
				// Single-line fix: replace this line with the formatted version
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
	const t0 = clockMs();
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);
	const source = dbGetSource(db, path);
	if (source === "") return lspResponse(id, "[]");

	const t1 = clockMs();
	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "[]");
	const t2 = clockMs();

	const options = getFormatOptions(db);
	options.source = source;
	const doc = printFormattedNode(program, options);
	const t3 = clockMs();
	const formatted = formatDoc(doc, options);
	const t4 = clockMs();

	writeStderr(`[LSP-FMT] ${path} parse=${t2 - t1}ms print=${t3 - t2}ms layout=${t4 - t3}ms source=${source.byteLength}b\n`);

	if (formatted.byteLength === source.byteLength && formatted === source) return lspResponse(id, "[]");

	let lineCount = 0;
	let lastNl = -1;
	for (let i = 0; i < source.byteLength; i = i + 1) {
		if (source.byteAt(i) === "\n".code) { lineCount = lineCount + 1; lastNl = i; }
	}
	const lastLineLen = source.byteLength - lastNl - 1;
	const range = lspFmtRange(0, 0, lineCount, lastLineLen);
	const t5 = clockMs();
	const edit = "{\"range\":" + range + ",\"newText\":" + lspJsonString(formatted) + "}";
	const t6 = clockMs();
	writeStderr(`[LSP-FMT] json=${t6 - t5}ms total=${t6 - t0}ms lines=${lineCount} lastLineLen=${lastLineLen} responseLen=${edit.length}\n`);
	return lspResponse(id, "[" + edit + "]");
}
