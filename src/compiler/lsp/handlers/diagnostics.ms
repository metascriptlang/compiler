// LSP Handlers — Diagnostics, format violations, dependency recording, transitive diagnostics.

import {
	TransAmDb, dbParse, dbTypeCheck, getFileId, getFilePath,
	clearImportsFor, getTransitiveDependents, recordModuleImport
} from "../../transam/index";
import { detectCycle } from "../../transam/moduleDeps";
import { writeStderr } from "std/io";
import { lspNotification, lspFormatMessage, lspPathToUri, lspDirname } from "../protocol";
import { lspFmtDiagnostic, lspFmtPublishDiagnostics } from "../format";
import { sgCollectDiagnostics } from "../../../checker/suggest";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData } from "../../../ast/node";
import { FormatOptions, defaultFormatOptions, applyFmtSection } from "../../fmt/options";
import { loadFmtSection, validateBuildConfig } from "../../buildConfig";
import { dbGetSource, resolveImportForLsp, lspEnsureFileLoaded } from "./shared";


// ===== Format Options from build.ms =====

// Cached format options loaded from workspace build.ms on first use.
let _fmtOptions: FormatOptions = null as unknown as FormatOptions;
let _fmtOptionsLoaded = false;

// Get format options, loading from workspace build.ms if available.
// The workspace root is derived from db.stdPath (set on LSP initialize to rootUri + "/std").
export function getFormatOptions(db: TransAmDb): FormatOptions {
	if (_fmtOptionsLoaded) return _fmtOptions;
	_fmtOptionsLoaded = true;
	let opts = defaultFormatOptions();
	// Derive workspace root from stdPath: "/path/to/project/std" -> "/path/to/project"
	const stdPath = db.stdPath;
	if (stdPath.length > 4) {
		const wsRoot = stdPath.slice(0, stdPath.length - 4);
		const fmtCfg = loadFmtSection(wsRoot);
		opts = applyFmtSection(opts, fmtCfg);
	}
	_fmtOptions = opts;
	return opts;
}

// Reset cached format options (call when workspace changes).
export function resetFormatOptions(): void {
	_fmtOptionsLoaded = false;
	_fmtOptions = null as unknown as FormatOptions;
}

// ===== Format Violation Check =====

// Split a string into lines (preserving empty trailing line if present).
export function splitLines(s: string): string[] {
	const lines: string[] = [];
	let start = 0;
	for (let i = 0; i < s.byteLength; i = i + 1) {
		if (s[i] === "\n") {
			lines.push(s.slice(start, i));
			start = i + 1;
		}
	}
	if (start <= s.byteLength) {
		lines.push(s.slice(start, s.byteLength));
	}
	return lines;
}

// Describe the formatting difference between an original and formatted line.
export function describeFmtDiff(orig: string, fmt: string): string {
	// Both empty — no difference worth reporting
	if (orig.byteLength === 0 && fmt.byteLength === 0) return "";
	// Blank original, non-blank formatted — missing content
	if (orig.byteLength === 0) return "Unexpected blank line";
	// Deleted line (formatted version removed it entirely)
	if (fmt.byteLength === 0) return "Delete this line";
	// Check indentation difference
	let origIndent = 0;
	while (origIndent < orig.byteLength && (orig[origIndent] === " " || orig[origIndent] === "\t")) {
		origIndent = origIndent + 1;
	}
	let fmtIndent = 0;
	while (fmtIndent < fmt.byteLength && (fmt[fmtIndent] === " " || fmt[fmtIndent] === "\t")) {
		fmtIndent = fmtIndent + 1;
	}
	if (origIndent !== fmtIndent) {
		if (fmtIndent > origIndent) return "Indent this line";
		return "Unindent this line";
	}
	// Check trailing whitespace
	let origEnd = orig.byteLength;
	while (origEnd > 0 && (orig[origEnd - 1] === " " || orig[origEnd - 1] === "\t")) {
		origEnd = origEnd - 1;
	}
	if (origEnd < orig.byteLength) return "Remove trailing whitespace";
	// Generic
	return "Reformat this line";
}

// Shared indent/trailing-whitespace detection — used by both diagnostics and code actions.
// Uses the "tabs for indentation, spaces for alignment" model (EditorConfig/Go convention):
//   - Tabs-mode: tabs first, then optional trailing spaces for alignment -> valid.
//     Only flag when a space appears *before* a tab (interleaved).
//   - Spaces-mode: any tab in leading whitespace -> wrong.
export interface LineIndent {
	indentEnd: number;
	hasSpace: boolean;
	hasTab: boolean;
	isMixed: boolean;
	trailStart: number;
}

export function detectLineIndent(line: string): LineIndent {
	let indentEnd = 0;
	let hasSpace = false;
	let hasTab = false;
	let isMixed = false;
	let seenSpace = false;
	while (indentEnd < line.length) {
		if (line[indentEnd] === " ") { hasSpace = true; seenSpace = true; }
		else if (line[indentEnd] === "\t") {
			hasTab = true;
			if (seenSpace) { isMixed = true; }
		}
		else { break; }
		indentEnd = indentEnd + 1;
	}
	let trailStart = line.length;
	while (trailStart > 0 && (line[trailStart - 1] === " " || line[trailStart - 1] === "\t")) {
		trailStart = trailStart - 1;
	}
	return { indentEnd, hasSpace, hasTab, isMixed, trailStart };
}

// Lint-style per-line format checks. Runs independently of the full formatter —
// detects specific issues (wrong indent char, trailing whitespace) on each line.
function checkFormatViolations(db: TransAmDb, path: string): string[] {
	const result: string[] = [];
	const source = dbGetSource(db, path);
	if (source === "") return result;

	const options = getFormatOptions(db);
	const useTabs = options.useTabs;
	const lines = splitLines(source);

	// Strip trailing empty line from split (artifact of trailing newline)
	let lineCount = lines.length;
	while (lineCount > 0 && lines[lineCount - 1] === "") {
		lineCount = lineCount - 1;
	}

	for (let i = 0; i < lineCount; i = i + 1) {
		const line = lines[i];
		if (line.length === 0) continue;

		const info = detectLineIndent(line);
		if (info.indentEnd > 0 && info.indentEnd < line.length) {
			// Skip block comment continuation lines ( * text) — spaces before * are alignment
			const afterIndent = line.byteAt(info.indentEnd);
			if (afterIndent === "*".code) continue;
			if (info.isMixed) {
				result.push(lspFmtDiagnostic(i, 0, info.indentEnd, 4, "Mixed tabs and spaces", "metascript-fmt", 0, 0));
				continue;
			}
			if (useTabs && info.hasSpace && !info.hasTab) {
				result.push(lspFmtDiagnostic(i, 0, info.indentEnd, 4, "Use tabs for indentation", "metascript-fmt", 0, 0));
				continue;
			}
			if (!useTabs && info.hasTab && !info.hasSpace) {
				result.push(lspFmtDiagnostic(i, 0, info.indentEnd, 4, "Use spaces for indentation", "metascript-fmt", 0, 0));
				continue;
			}
		}
		if (info.trailStart < line.length && info.trailStart > 0) {
			result.push(lspFmtDiagnostic(i, info.trailStart, line.length, 4, "Remove trailing whitespace", "metascript-fmt", 0, 0));
		}
	}

	return result;
}

// Extract filename from absolute path (for diagnostic messages)
function lspBasename(path: string): string {
	if (path === "") return "";
	let lastSlash = -1;
	for (let i = path.byteLength - 1; i >= 0; i = i - 1) {
		if (path[i] === "/") { lastSlash = i; break; }
	}
	if (lastSlash >= 0) return path.slice(lastSlash + 1, path.byteLength);
	return path;
}

// ===== Diagnostics =====

export function buildDiagnosticsJson(uri: string, db: TransAmDb, path: string): string {
	const ctx = dbTypeCheck(db, path);

	let diagArray = "[";
	let diagCount = 0;

	if (ctx !== null) {
		const diags = sgCollectDiagnostics(ctx);
		for (let i = 0; i < diags.length; i = i + 1) {
			if (diagCount > 0) diagArray = diagArray + ",";
			const d = diags[i];
			const line = d.line - 1;
			// Convert 1-based checker columns to 0-based LSP columns
			const col = d.column > 0 ? d.column - 1 : 0;
			const endCol = d.endColumn > d.column ? d.endColumn - 1 : col + 1;
			diagArray = diagArray + lspFmtDiagnostic(
				line, col, endCol, d.severity, d.message, "metascript", 0, d.tags
			);
			diagCount = diagCount + 1;
		}
	}

	// Circular dependency warnings — at the import declaration line
	const circProgram = dbParse(db, path);
	if (circProgram !== null && circProgram.kind === NodeKind.Program) {
		const circPd = circProgram.data as ProgramData;
		const circFileId = getFileId(db.fileInput, path);
		for (let ci = 0; ci < circPd.programStmts.length; ci = ci + 1) {
			let circStmt = circPd.programStmts[ci];
			if (circStmt.kind === NodeKind.ExportDecl) {
				const ced = circStmt.data as ExportDeclData;
				circStmt = ced.exportedDecl;
			}
			if (circStmt.kind === NodeKind.ImportDecl) {
				const circImp = circStmt.data as ImportDeclData;
				const circTarget = resolveImportForLsp(db, path, circImp.importSource);
				if (circTarget !== "") {
					const circTargetId = getFileId(db.fileInput, circTarget);
					if (circTargetId >= 0 && circFileId >= 0) {
						const cycle = detectCycle(db.moduleDeps, circFileId, circTargetId);
						if (cycle.length > 0) {
							// Build cycle path string
							let cyclePath = "";
							for (let cpi = 0; cpi < cycle.length; cpi = cpi + 1) {
								if (cpi > 0) cyclePath = cyclePath + " -> ";
								const cp = getFilePath(db.fileInput, cycle[cpi]);
								cyclePath = cyclePath + lspBasename(cp);
							}
							cyclePath = cyclePath + " -> " + lspBasename(path);
							const circLine = circStmt.location !== null ? circStmt.location.line - 1 : 0;
							if (diagCount > 0) diagArray = diagArray + ",";
							diagArray = diagArray + lspFmtDiagnostic(
								circLine, 0, 1, 2, "Circular import: " + cyclePath, "metascript", 0, 0
							);
							diagCount = diagCount + 1;
						}
					}
				}
			}
		}
	}

	// Per-line format violation diagnostics — hint severity (4)
	// Per-line format violation diagnostics — hint severity (4)
	const fmtDiags = checkFormatViolations(db, path);
	for (let fi = 0; fi < fmtDiags.length; fi = fi + 1) {
		if (diagCount > 0) diagArray = diagArray + ",";
		diagArray = diagArray + fmtDiags[fi];
		diagCount = diagCount + 1;
	}

	// build.ms validation warnings (entry path not found, etc.)
	if (path.length > 9 && path.slice(path.length - 9, path.length) === "/build.ms") {
		const buildSource = dbGetSource(db, path);
		const buildWarnings = validateBuildConfig(lspDirname(path), buildSource);
		for (let bw = 0; bw < buildWarnings.length; bw = bw + 1) {
			if (diagCount > 0) diagArray = diagArray + ",";
			const w = buildWarnings[bw];
			const wLine = w.line > 0 ? w.line - 1 : 0;
			diagArray = diagArray + lspFmtDiagnostic(wLine, 0, 999, 2, w.message, "msc", 0, 0);
			diagCount = diagCount + 1;
		}
	}

	diagArray = diagArray + "]";

	return lspFmtPublishDiagnostics(uri, diagArray);
}

// ===== Dependency Recording =====

// Record import edges for a file. Called after parsing on didOpen/didChange.
export function recordImportsForFile(db: TransAmDb, path: string, program: Node): void {
	const fileId = getFileId(db.fileInput, path);
	if (fileId < 0) return;
	// Clear stale edges for this file
	clearImportsFor(db.moduleDeps, fileId);
	if (program === null) return;
	if (program.kind !== NodeKind.Program) return;
	const data = program.data as ProgramData;
	let loadCount = 0;
	for (let i = 0; i < data.programStmts.length; i = i + 1) {
		let stmt = data.programStmts[i];
		// Unwrap ExportDecl (re-exports)
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind === NodeKind.ImportDecl) {
			const imp = stmt.data as ImportDeclData;
			const targetPath = resolveImportForLsp(db, path, imp.importSource);
			if (targetPath === "") continue;
			const alreadyLoaded = getFileId(db.fileInput, targetPath) >= 0;
			lspEnsureFileLoaded(db, targetPath);
			if (!alreadyLoaded) loadCount = loadCount + 1;
			const targetId = getFileId(db.fileInput, targetPath);
			if (targetId >= 0) {
				recordModuleImport(db.moduleDeps, fileId, targetId);
			}
		}
	}
	if (loadCount > 0) {
		writeStderr("[LSP] recordImports " + path + " loaded " + loadCount + " new files\n");
	}
}

// ===== Transitive Diagnostics =====

// Build wire-formatted diagnostics notifications for all files that
// transitively depend on the changed file. Concatenated Content-Length messages.
// Cache last diagnostics per file — skip publish if unchanged (output-hash gate).
// Prevents redundant re-checks on comment edits that don't change semantics.
let _lastDiagCache: Map<string, string> = new Map<string, string>();

export function buildTransitiveDiagnosticsWire(db: TransAmDb, path: string): string {
	const fileId = getFileId(db.fileInput, path);
	if (fileId < 0) return "";
	const deps = getTransitiveDependents(db.moduleDeps, fileId);
	if (deps.length === 0) return "";

	let result = "";
	for (let i = 0; i < deps.length; i = i + 1) {
		const depPath = getFilePath(db.fileInput, deps[i]);
		if (depPath === "") continue;
		const depUri = lspPathToUri(depPath);
		const diagJson = buildDiagnosticsJson(depUri, db, depPath);
		// Skip publish if diagnostics unchanged since last time
		const cached = _lastDiagCache.has(depPath) ? _lastDiagCache.get(depPath) : "";
		if (diagJson === cached) continue;
		_lastDiagCache.set(depPath, diagJson);
		const notif = lspNotification("textDocument/publishDiagnostics", diagJson);
		result = result + lspFormatMessage(notif);
	}
	return result;
}
