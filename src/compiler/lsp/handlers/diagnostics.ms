// LSP Handlers — Diagnostics, format violations, dependency recording, transitive diagnostics.

import {
	TransAmDb, dbParse, dbTypeCheck, dbGetCheckedProgram, getFileId, getFilePath,
	clearImportsFor, getTransitiveDependents, recordModuleImport
} from "../../transam/index";
import { detectCycle } from "../../transam/moduleDeps";
import { writeStderr } from "std/io";
import { platform, env, cwd } from "std/process";
import { mkdir, writeFile } from "std/fs";
import { lspNotification, lspFormatMessage, lspPathToUri, dirname } from "../protocol";
import { lspFmtDiagnostic, lspFmtDiagnosticRange, lspFmtPublishDiagnostics } from "../format";
import { sgCollectDiagnostics } from "../../../checker/suggest";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData } from "../../../ast/node";
import { FormatOptions, defaultFormatOptions, applyFmtSection } from "../../fmt/options";
import { loadFmtSection, loadLspSection, validateBuildConfig, LspSection } from "../../buildConfig";
import { collectFreestandingAsync, freestandingAsyncLoc, FREESTANDING_ASYNC_MSG } from "../../../checker/freestanding";
import { dbGetSource, lspEnsureFileLoaded } from "./shared";
import { dbResolveImport } from "../../transam/index";
import { findProjectRoot } from "../../../utils/path";


// ===== Format Options from build.ms =====

// Per-workspace cache: project root → FormatOptions loaded from its build.ms.
// Keyed by the directory containing build.ms (result of findProjectRoot), so
// multi-root workspaces each get their own config without collisions.
let _fmtOptionsCacheKeys: string[] = [];
let _fmtOptionsCacheValues: FormatOptions[] = [];

// Get format options, loading from the project's build.ms if available.
// The project root is found by walking up from `path` looking for build.ms.
// Falls back to defaults when no build.ms is found. Results are cached per root.
export function getFormatOptions(db: TransAmDb, path: string): FormatOptions {
	const projectRoot = findProjectRoot(path);
	for (let i = 0; i < _fmtOptionsCacheKeys.length; i = i + 1) {
		if (_fmtOptionsCacheKeys[i] === projectRoot) return _fmtOptionsCacheValues[i];
	}
	let opts = defaultFormatOptions();
	if (projectRoot !== "") {
		const fmtCfg = loadFmtSection(projectRoot);
		opts = applyFmtSection(opts, fmtCfg);
	}
	_fmtOptionsCacheKeys.push(projectRoot);
	_fmtOptionsCacheValues.push(opts);
	return opts;
}

// Reset cached format options (call when workspace changes or build.ms is saved).
export function resetFormatOptions(): void {
	_fmtOptionsCacheKeys = [];
	_fmtOptionsCacheValues = [];
}

// ===== LSP Target from build.ms =====

// Effective build target for diagnostics that depend on target capabilities.
// Mirrors the compile-side resolution: os defaults to the host platform, gc
// infers from os (bare/solana => manual, else orc). An explicit lsp.gc wins.
export interface LspTarget {
	os: string;
	gc: string;
}

let _lspTargetCacheKeys: string[] = [];
let _lspTargetCacheValues: LspTarget[] = [];

export function getLspTarget(path: string): LspTarget {
	const projectRoot = findProjectRoot(path);
	for (let i = 0; i < _lspTargetCacheKeys.length; i = i + 1) {
		if (_lspTargetCacheKeys[i] === projectRoot) return _lspTargetCacheValues[i];
	}
	let section: LspSection = { os: "", gc: "" };
	if (projectRoot !== "") {
		section = loadLspSection(projectRoot);
	}
	const os = section.os !== "" ? section.os : platform;
	const gc = section.gc !== ""
		? section.gc
		: ((os === "bare" || os === "solana") ? "manual" : "orc");
	const target: LspTarget = { os, gc };
	_lspTargetCacheKeys.push(projectRoot);
	_lspTargetCacheValues.push(target);
	return target;
}

export function resetLspTargetCache(): void {
	_lspTargetCacheKeys = [];
	_lspTargetCacheValues = [];
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

	const options = getFormatOptions(db, path);
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
			const endLine = d.endLine > 0 ? d.endLine - 1 : line;
			const endCol = d.endColumn > d.column ? d.endColumn - 1 : col + 1;
			diagArray = diagArray + lspFmtDiagnosticRange(
				line, col, endLine, endCol, d.severity, d.message, "metascript", 0, d.tags
			);
			diagCount = diagCount + 1;
		}
	}

	// FREESTANDING E01 (LSP side): when build.ms declares a freestanding target
	// (effective gc = manual), async/await/spawn surface is a WARNING, not an
	// error — the editor cannot know if the user will build with a different
	// target. Silent unless the lsp section opts in (host default never manual).
	const lspTarget = getLspTarget(path);
	if (lspTarget.gc === "manual" && !(db.stdPath !== "" && path.startsWith(db.stdPath))) {
		const fsProgram = dbGetCheckedProgram(db, path);
		if (fsProgram !== null) {
			const fsHits = collectFreestandingAsync(fsProgram);
			for (let fi = 0; fi < fsHits.length; fi = fi + 1) {
				const loc = freestandingAsyncLoc(fsHits[fi]);
				if (loc === null) continue;
				const fsLine = loc.line > 0 ? loc.line - 1 : 0;
				const fsCol = loc.column > 0 ? loc.column - 1 : 0;
				if (diagCount > 0) diagArray = diagArray + ",";
				diagArray = diagArray + lspFmtDiagnostic(
					fsLine, fsCol, fsCol + 1, 2, FREESTANDING_ASYNC_MSG, "metascript", 0, 0
				);
				diagCount = diagCount + 1;
			}
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
				const circTarget = dbResolveImport(db, path,circImp.importSource);
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
		const buildWarnings = validateBuildConfig(dirname(path), buildSource);
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
			const targetPath = dbResolveImport(db, path, imp.importSource);
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
let _lastDiagCache: HashMap<string, string> = new HashMap<string, string>();

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
		const cached = _lastDiagCache.get(depPath) ?? "";
		if (diagJson === cached) continue;
		_lastDiagCache.set(depPath, diagJson);
		const notif = lspNotification("textDocument/publishDiagnostics", diagJson);
		result = result + lspFormatMessage(notif);
	}
	return result;
}

// ===== Tests — LSP target resolution =====

function lspProbeTmpDir(): string {
	const t = env.get("TMP");
	if (t !== "") return t;
	const t2 = env.get("TEMP");
	if (t2 !== "") return t2;
	const t3 = env.get("TMPDIR");
	if (t3 !== "") return t3;
	return "/tmp";
}

test "getLspTarget infers manual for bare os" {
	const dir = lspProbeTmpDir() + "/msc-lspprobe-bare";
	mkdir(dir);
	writeFile(dir + "/build.ms", "const config = { lsp: { os: \"bare\" } };\n\nexport default config;\n");
	resetLspTargetCache();
	const t = getLspTarget(dir + "/main.ms");
	assert t.os === "bare";
	assert t.gc === "manual";
}

test "getLspTarget keeps explicit gc over inference" {
	const dir = lspProbeTmpDir() + "/msc-lspprobe-gc";
	mkdir(dir);
	writeFile(dir + "/build.ms", "const config = { lsp: { os: \"bare\", gc: \"drc\" } };\n\nexport default config;\n");
	resetLspTargetCache();
	const t = getLspTarget(dir + "/main.ms");
	assert t.os === "bare";
	assert t.gc === "drc";
}

test "getLspTarget defaults to host + orc without section" {
	const dir = lspProbeTmpDir() + "/msc-lspprobe-none";
	mkdir(dir);
	writeFile(dir + "/build.ms", "const config = { entry: \"./src/index\" };\n\nexport default config;\n");
	resetLspTargetCache();
	const t = getLspTarget(dir + "/main.ms");
	assert t.os === platform;
	assert t.gc === "orc";
}
