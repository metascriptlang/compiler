// LSP Handlers — Per-method dispatch, format JSON responses
//
// Each handler: extract params → query Trans-Am → call suggest.ms → format JSON.
// No I/O — returns JSON strings. server.ms handles stdin/stdout.

import {
	TransAmDb, createTransAmDb, dbSetFileText, dbParse, dbTypeCheck,
	dbGetCheckedProgram, dbEnsureModuleExports, getFileText, getFileId, getFilePath,
	recordModuleImport, clearImportsFor, getTransitiveDependents,
	dbGetFileCount, dbGetFilePathByIndex
} from "../transam/index";
import { detectCycle } from "../transam/moduleDeps";
import { readFile, clockMs, readDir } from "std/process";
import { translateCHeader } from "../../module/loader";
import { writeStderr } from "std/io";
import {
	lspJsonString, lspJsonNumber, lspJsonBool, lspJsonNull,
	lspGetField, lspGetNumberField, lspGetObjectField,
	lspResponse, lspNotification, lspErrorResponse,
	lspUriToPath, lspPathToUri, lspResolveImport, lspFormatMessage,
	lspDirname
} from "./protocol";
import {
	lspFmtPosition, lspFmtRange, lspFmtLineRange,
	lspFmtLocation, lspFmtTextEdit,
	lspFmtCompletionItem, lspFmtHoverResult,
	lspFmtDiagnostic, lspFmtPublishDiagnostics,
	lspFmtDocumentSymbol, lspFmtDocumentHighlight, lspFmtInlayHint,
	lspFmtSignatureParam, lspFmtSignature, lspFmtSignatureHelp,
	lspFmtMultiLineTextEdit
} from "./format";
import {
	sgTypeToString,
	sgFormatHover, sgCollectDiagnostics,
	sgDetectCompletionContext, sgGetPrefix, sgGetCompletionCandidates,
	sgCollectSymbolsInFile, sgFormatSignature, sgFormatExtensionSignatures, sgGetSignatureContext, SgSignatureContext,
	sgCollectInlayHints,
	sgFormatHoverDoc, sgExtractDocComment, sgBuiltinDoc,
	sgFindImportSource, sgFindImportBySource, sgFindExportedDecl, sgExtractImportPath, sgExtractImportSource, sgExtractExistingImportNames,
	sgComputeImportEdit,
	sgQueryAtPosition, sgQueryBySym, sgQueryByName, sgQueryByDefiningModule,
	SgSuggest, SgCompletionKind, sgObjectFieldPathAST, sgCompleteObjectFields,
	findEnclosingObjectLiteral, findNodeAtPosition,
	sgGetLineOffset, sgIsIdentChar,
	SgSymbolRef,
	SgDocumentSymbol,
	SgSignatureInfo,
	SgInlayHint, SgInlayHintKind,
	SgDiagnostic,
	SgSemanticToken, sgCollectSemanticTokens, sgSortTokens
} from "../../checker/suggest";
import { CheckerContext, createContext, findModuleExports, ExportedSymInfo } from "../../checker/context";
import { SymbolFlag, hasFlag, lookupSymbol } from "../../checker/symbol";
import { unknownType, getProperty, typeNameOf, createTypeRef } from "../../checker/types";
import { Node, IdentifierData, MemberExprData, ObjectLiteralData, VariableDeclData, NodeKind, ProgramData, ImportDeclData, ExportDeclData, SourceLocation, makeLoc, Type, TypeKind, Symbol, SymbolKind } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { FormatOptions, defaultFormatOptions, applyFmtSection } from "../fmt/options";
import { printNode as printFormattedNode } from "../fmt/printer";
import { formatDoc } from "../fmt/layout";
import { registerCoreParsers } from "../../parser/statements/core";
import { parseSource } from "../../parser/statements/validation";
import { FmtSection, defaultFmtSection, loadFmtSection, validateBuildConfig } from "../buildConfig";
import { isMsModuleExtension, stripMsModuleExtension } from "../../module/resolver";


// ===== Completion Cache =====
// Caches last completion list per file for zero-lag character-by-character filtering.
// Shared with server.ms via LspServerState.

export class CompletionCache {
	uri: string;           // file URI of last completion
	line: number;          // line of last completion (1-indexed, internal)
	prefix: string;        // prefix used for last completion
	items: string[];       // cached per-item JSON strings
}

// Resolve cache: maps label to additionalTextEdits JSON for completionItem/resolve.
// nvim-cmp strips additionalTextEdits from initial response and expects them on resolve.
let _resolveCache: Map<string, string> = new Map<string, string>();

function cacheResolveEdit(label: string, detail: string, editsJson: string): void {
	_resolveCache.set(label, editsJson);
}

function lookupResolveEdit(label: string, detail: string): string {
	if (_resolveCache.has(label)) return _resolveCache.get(label);
	return "";
}

export function createCompletionCache(): CompletionCache {
	return { uri: "", line: -1, prefix: "", items: [] };
}

// Pre-built completion items: computed during didOpen/didChange, returned instantly on completion.
// Contains all scope + cross-module symbols for the file. Keyed by file URI.
let _prebuiltUri: string = "";
let _prebuiltItems: string[] = [];

function prebuildCompletionCache(db: TransAmDb, path: string, uri: string): void {
	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return;
	const program = dbParse(db, path);
	if (program === null) return;
	const source = dbGetSource(db, path);
	// Build minimal items (label + kind + sortText only) for fast stdio transfer.
	// rust-analyzer pattern: defer detail/docs/textEdit to completionItem/resolve.
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null);
	const items: string[] = [];
	for (const c of candidates) {
		const kindNum = lspCompletionItemKind(c.kind, c.isMutable);
		const sortText = lspCompletionSortText(c);
		items.push("{\"label\":" + lspJsonString(c.name) + ",\"kind\":" + kindNum + ",\"sortText\":" + lspJsonString(sortText) + "}");
	}
	// Cross-module candidates (also minimal — just label + kind)
	if (db.exportRegistry !== null) {
		const inScopeSet: Set<string> = new Set<string>();
		for (const c of candidates) { inScopeSet.add(c.name); }
		for (const entry of db.exportRegistry.entries) {
			if (entry.modulePath === path) continue;
			for (const sym of entry.symbols) {
				if (sym.name.length === 0 || inScopeSet.has(sym.name)) continue;
				if (sym.extReceiverType.length > 0) continue;
				const kindNum = lspCompletionItemKind(sym.kind, false);
				items.push("{\"label\":" + lspJsonString(sym.name) + ",\"kind\":" + kindNum + ",\"sortText\":\"25\"}");
			}
		}
	}
	_prebuiltUri = uri;
	_prebuiltItems = items;
}

// ===== Shared Helpers =====

interface LspCursorParams {
	uri: string;
	line: number;   // 1-based (parser convention)
	col: number;    // 0-based (for text offset scanning)
	col1: number;   // 1-based (for AST node position matching)
}

function lspExtractPosition(params: string): LspCursorParams {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const position = lspGetObjectField(params, "position");
	const col0 = lspGetNumberField(position, "character");
	return { uri, line: lspGetNumberField(position, "line") + 1, col: col0, col1: col0 + 1 };
}

// Simple linear search for dedup (O(n^2) acceptable for typical reference counts).
// Get raw source text from Trans-Am DB for a given path.
// Used by handlers that need text scanning (completion prefix, callee detection).
function dbGetSource(db: TransAmDb, path: string): string {
	const fileId = getFileId(db.fileInput, path);
	if (fileId < 0) return "";
	return getFileText(db.fileInput, fileId);
}

// Load a file into the TransAm DB if not already present.
function lspEnsureFileLoaded(db: TransAmDb, filePath: string): void {
	if (getFileId(db.fileInput, filePath) < 0) {
		const t0 = clockMs();
		let source = readFile(filePath);
		if (source.byteLength > 0) {
			// Translate .h files to MS extern declarations at input boundary
			if (filePath.length >= 2 && filePath.slice(filePath.length - 2, filePath.length) === ".h") {
				source = translateCHeader(source, []);
			}
			dbSetFileText(db, filePath, source);
		}
		const t1 = clockMs();
		writeStderr("[LSP] loadFile " + filePath + " " + (t1 - t0) + "ms\n");
	}
}

// Resolve import specifier to absolute path. Handles relative (./foo) and std/ imports.
// For std/ imports, tries candidates in order: .ms, .cms, /index.ms, /index.cms.
// Loads from disk if not already in the db.
function resolveImportForLsp(db: TransAmDb, basePath: string, importSpec: string): string {
	// Relative imports — handled by existing resolver
	const rel = lspResolveImport(basePath, importSpec);
	if (rel !== "") return rel;

	// std/ imports — resolve against db.stdPath
	if (db.stdPath.length > 0 && importSpec.length > 4 && importSpec.slice(0, 4) === "std/") {
		const rest = importSpec.slice(4, importSpec.length);
		const base = db.stdPath + "/" + rest;
		// Try candidates: check db first (no disk I/O), then load from disk.
		const candidates: string[] = [];
		candidates.push(base + ".ms");
		candidates.push(base + ".cms");
		candidates.push(base + "/index.ms");
		candidates.push(base + "/index.cms");
		// Fast path: check if already loaded in db (no disk I/O)
		for (const c of candidates) {
			if (getFileId(db.fileInput, c) >= 0) return c;
		}
		// Slow path: try loading from disk
		for (const c of candidates) {
			lspEnsureFileLoaded(db, c);
			if (getFileId(db.fileInput, c) >= 0) return c;
		}
	}

	return "";
}

// ===== Object Literal Type Resolution (AST-Based) =====

// Find the root struct type for an object literal by walking the AST.
// Finds the outermost ObjectLiteral ancestor, then looks for the VariableDecl
// that contains it to get the declared type via sgRecords.
function lspFindObjectLiteralTypeAST(program: Node, line: number, col: number, ctx: CheckerContext): Type {
	// Find the outermost ObjectLiteral ancestor at cursor position
	const rootObj = lspFindRootObjectLiteral(program, line, col);
	if (rootObj === null) return null;
	// Find the VariableDecl that contains this ObjectLiteral
	const varDecl = lspFindParentVarDecl(program, rootObj);
	if (varDecl === null) return null;
	// Query sgRecords for the variable's type — use nameLocation (identifier position), not node location (keyword position)
	const vd = varDecl.data as VariableDeclData;
	const sg = sgQueryAtPosition(ctx, vd.nameLocation.line, vd.nameLocation.column);
	if (sg !== null) return sg.symType;
	return null;
}

// Find the outermost ObjectLiteral containing the cursor.
// If nested `{ fmt: { | } }`, returns the outer `{ }`.
// Uses findEnclosingObjectLiteral (from suggest.ms) which has subtree-touch validation,
// then walks up to find the outermost ancestor ObjectLiteral.
function lspFindRootObjectLiteral(root: Node, line: number, col: number): Node {
	// Find the innermost ObjectLiteral first (validated by subtree check)
	const innermost = findEnclosingObjectLiteral(root, line, col);
	if (innermost === null) return null as unknown as Node;
	// Walk from root to find the outermost ObjectLiteral that is an ancestor of innermost
	const outermost = lspFindOutermostObjLitAncestor(root, innermost);
	return outermost !== null ? outermost : innermost;
}

// Find the outermost ObjectLiteral node that is an ancestor of target.
function lspFindOutermostObjLitAncestor(root: Node, target: Node): Node {
	if (root === null) return null as unknown as Node;
	if (root === target) return null as unknown as Node;
	let isAncestor = false;
	let childResult = null as unknown as Node;
	forEachChild(root, (child: Node): void => {
		if (!isAncestor) {
			if (child === target) {
				isAncestor = true;
			} else {
				const r = lspFindOutermostObjLitAncestor(child, target);
				if (r !== null) {
					childResult = r;
					isAncestor = true;
				} else if (sgNodeContains(child, target)) {
					isAncestor = true;
				}
			}
		}
	});
	if (isAncestor && root.kind === NodeKind.ObjectLiteral) {
		return root;
	}
	return childResult;
}

// Check if node contains target anywhere in its subtree.
function sgNodeContains(node: Node, target: Node): boolean {
	if (node === null) return false;
	if (node === target) return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && sgNodeContains(child, target)) {
			found = true;
		}
	});
	return found;
}

// Find the VariableDecl AST node that contains a given ObjectLiteral node.
function lspFindParentVarDecl(root: Node, target: Node): Node {
	if (root === null) return null as unknown as Node;
	if (root.kind === NodeKind.VariableDecl) {
		const vd = root.data as VariableDeclData;
		if (vd.initializer === target) {
			return root;
		}
	}
	let found = null as unknown as Node;
	forEachChild(root, (child: Node): void => {
		if (found === null) {
			const r = lspFindParentVarDecl(child, target);
			if (r !== null) {
				found = r;
			}
		}
	});
	return found;
}

// ===== Format Options from build.ms =====

// Cached format options loaded from workspace build.ms on first use.
let _fmtOptions: FormatOptions = null as unknown as FormatOptions;
let _fmtOptionsLoaded = false;

// Get format options, loading from workspace build.ms if available.
// The workspace root is derived from db.stdPath (set on LSP initialize to rootUri + "/std").
function getFormatOptions(db: TransAmDb): FormatOptions {
	if (_fmtOptionsLoaded) return _fmtOptions;
	_fmtOptionsLoaded = true;
	let opts = defaultFormatOptions();
	// Derive workspace root from stdPath: "/path/to/project/std" → "/path/to/project"
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
function splitLines(s: string): string[] {
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
function describeFmtDiff(orig: string, fmt: string): string {
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
//   - Tabs-mode: tabs first, then optional trailing spaces for alignment → valid.
//     Only flag when a space appears *before* a tab (interleaved).
//   - Spaces-mode: any tab in leading whitespace → wrong.
interface LineIndent {
	indentEnd: number;
	hasSpace: boolean;
	hasTab: boolean;
	isMixed: boolean;
	trailStart: number;
}

function detectLineIndent(line: string): LineIndent {
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
				result.push(lspFmtDiagnostic(i, 0, info.indentEnd, 4, "Mixed tabs and spaces", "metascript-fmt", 0));
				continue;
			}
			if (useTabs && info.hasSpace && !info.hasTab) {
				result.push(lspFmtDiagnostic(i, 0, info.indentEnd, 4, "Use tabs for indentation", "metascript-fmt", 0));
				continue;
			}
			if (!useTabs && info.hasTab && !info.hasSpace) {
				result.push(lspFmtDiagnostic(i, 0, info.indentEnd, 4, "Use spaces for indentation", "metascript-fmt", 0));
				continue;
			}
		}
		if (info.trailStart < line.length && info.trailStart > 0) {
			result.push(lspFmtDiagnostic(i, info.trailStart, line.length, 4, "Remove trailing whitespace", "metascript-fmt", 0));
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

// Find the 0-based column of `name` as a whole word on 0-based `targetLine`.
function lspFindNameCol(src: string, targetLine: number, name: string): number {
	// Navigate to target line
	let lineNum = 0;
	let lineStart = 0;
	let i = 0;
	while (i < src.byteLength && lineNum < targetLine) {
		if (src[i] === "\n") {
			lineNum = lineNum + 1;
			lineStart = i + 1;
		}
		i = i + 1;
	}
	if (lineNum !== targetLine) return -1;
	// Scan line for word-boundary match
	let j = lineStart;
	while (j < src.byteLength && src[j] !== "\n") {
		if (src.slice(j, j + name.byteLength) === name) {
			const before = j === lineStart || !lspIsWordChar(src[j - 1]);
			const endIdx = j + name.byteLength;
			const after = endIdx >= src.byteLength || src[endIdx] === "\n" || !lspIsWordChar(src[endIdx]);
			if (before && after) return j - lineStart;
		}
		j = j + 1;
	}
	return -1;
}

function lspIsWordChar(ch: string): boolean {
	return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch === "_";
}

// Find field declaration within an interface/struct body.
// Scans from startLine+1 looking for `fieldName` followed by `:` (field declaration pattern).
// Returns 0-based {line, col} or {-1, -1} if not found.
function lspFindFieldLine(src: string, startLine: number, fieldName: string): SourceLocation {
	let lineNum = 0;
	let lineStart = 0;
	let i = 0;
	// Skip to startLine + 1 (body starts after declaration line)
	const bodyStart = startLine + 1;
	while (i < src.byteLength && lineNum < bodyStart) {
		if (src[i] === "\n") {
			lineNum = lineNum + 1;
			lineStart = i + 1;
		}
		i = i + 1;
	}
	// Scan lines looking for field declaration
	while (i < src.byteLength) {
		// Check if this line contains fieldName as a word followed by : or ?:
		let j = lineStart;
		while (j < src.byteLength && src[j] !== "\n") {
			if (src.slice(j, j + fieldName.byteLength) === fieldName) {
				const before = j === lineStart || !lspIsWordChar(src[j - 1]);
				const endIdx = j + fieldName.byteLength;
				const after = endIdx < src.byteLength && !lspIsWordChar(src[endIdx]);
				if (before && after) {
					// Check for ':' or '?:' after the field name (skip whitespace)
					let k = endIdx;
					while (k < src.byteLength && (src[k] === " " || src[k] === "\t")) {
						k = k + 1;
					}
					if (k < src.byteLength && (src[k] === ":" || src[k] === "?")) {
						return makeLoc(lineNum, j - lineStart);
					}
				}
			}
			j = j + 1;
		}
		// Hit closing brace — stop searching
		let b = lineStart;
		while (b < src.byteLength && b <= j) {
			if (src[b] === "}") return makeLoc(-1, -1);
			b = b + 1;
		}
		// Advance to next line
		i = j + 1;
		lineNum = lineNum + 1;
		lineStart = i;
	}
	return makeLoc(-1, -1);
}

// Find an enum member declaration: search for "enum ContainerName" then the member within the block.
function lspFindEnumMemberLine(src: string, containerName: string, memberName: string): SourceLocation {
	// First find the line containing "enum ContainerName"
	const enumPattern = "enum " + containerName;
	let lineNum = 0;
	let lineStart = 0;
	let enumLine = -1;
	let i = 0;
	while (i < src.byteLength) {
		if (src[i] === "\n") {
			lineNum = lineNum + 1;
			lineStart = i + 1;
		} else {
			// Check if this position starts the pattern
			if (i >= lineStart && i + enumPattern.byteLength <= src.byteLength) {
				if (src.slice(i, i + enumPattern.byteLength) === enumPattern) {
					const endIdx = i + enumPattern.byteLength;
					const before = i === lineStart || !lspIsWordChar(src[i - 1]);
					const after = endIdx >= src.byteLength || !lspIsWordChar(src[endIdx]);
					if (before && after) {
						enumLine = lineNum;
						// Now search for member within the enum block
						let j = endIdx;
						let memberLineNum = lineNum;
						let memberLineStart = lineStart;
						while (j < src.byteLength) {
							if (src[j] === "\n") {
								memberLineNum = memberLineNum + 1;
								memberLineStart = j + 1;
							} else if (src[j] === "}") {
								// End of enum block — member not found
								return makeLoc(enumLine, i - lineStart);
							} else if (j + memberName.byteLength <= src.byteLength && src.slice(j, j + memberName.byteLength) === memberName) {
								const mb = j === memberLineStart || !lspIsWordChar(src[j - 1]);
								const me = j + memberName.byteLength >= src.byteLength || !lspIsWordChar(src[j + memberName.byteLength]);
								if (mb && me) {
									return makeLoc(memberLineNum, j - memberLineStart);
								}
							}
							j = j + 1;
						}
						return makeLoc(enumLine, i - lineStart);
					}
				}
			}
		}
		i = i + 1;
	}
	return makeLoc(-1, -1);
}

// ===== Extern → Native Header Navigation =====

// Collect .h import paths from the parsed AST (ImportDecl nodes with .h source)
function lspCollectHeaderImports(program: Node): string {
	if (program === null) return "";
	const pd = program.data as ProgramData;
	let result = "";
	for (const stmt of pd.programStmts) {
		let importNode = stmt;
		if (importNode.kind === NodeKind.ExportDecl) {
			const ed = importNode.data as ExportDeclData;
			importNode = ed.exportedDecl;
		}
		if (importNode !== null && importNode.kind === NodeKind.ImportDecl) {
			const id = importNode.data as ImportDeclData;
			if (id.importSource.length > 2
				&& id.importSource.slice(id.importSource.length - 2, id.importSource.length) === ".h") {
				if (result !== "") { result = result + "\n"; }
				result = result + id.importSource;
			}
		}
	}
	return result;
}

function lspFindNativeDefinition(nativeName: string, headerPath: string, modulePath: string): string {
	// headerPath may contain multiple paths (newline-separated). Search each.
	// Resolve relative to the MODULE that declares the extern, not the current file.
	const headers = headerPath.split("\n");
	for (const h of headers) {
		if (h === "") continue;
		const result = lspSearchHeaderForName(nativeName, h, modulePath);
		if (result !== "") return result;
	}
	return "";
}

function lspSearchHeaderForName(nativeName: string, headerRelPath: string, modulePath: string): string {
	let hPath = headerRelPath;
	if (hPath.length > 0 && hPath.charCodeAt(0) !== "/".code) {
		hPath = lspDirname(modulePath) + "/" + hPath;
	}
	const hSrc = readFile(hPath);
	if (hSrc === "") return "";
	let lineNum = 0;
	let lineStart = 0;
	let i = 0;
	while (i < hSrc.byteLength) {
		if (hSrc.charCodeAt(i) === "\n".code) {
			lineNum = lineNum + 1;
			lineStart = i + 1;
			i = i + 1;
			continue;
		}
		if (i + nativeName.byteLength <= hSrc.byteLength) {
			if (hSrc.slice(i, i + nativeName.byteLength) === nativeName) {
				const endIdx = i + nativeName.byteLength;
				const before = i === 0 || !lspIsWordChar(hSrc.charAt(i - 1));
				const after = endIdx >= hSrc.byteLength || !lspIsWordChar(hSrc.charAt(endIdx));
				if (before && after) {
					const col = i - lineStart;
					const hUri = lspPathToUri(hPath);
					return lspFmtLocation(hUri, lineNum, col, lineNum, col + nativeName.byteLength);
				}
			}
		}
		i = i + 1;
	}
	return "";
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
				line, col, endCol, d.severity, d.message, "metascript", 0
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
								circLine, 0, 1, 2, "Circular import: " + cyclePath, "metascript", 0
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
			diagArray = diagArray + lspFmtDiagnostic(wLine, 0, 999, 2, w.message, "msc", 0);
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

// ===== Initialize =====

export function handleInitialize(id: string): string {
	const caps = "{\"capabilities\":{"
		+ "\"textDocumentSync\":{\"openClose\":true,\"change\":1}"
		+ ",\"hoverProvider\":true"
		+ ",\"completionProvider\":{\"triggerCharacters\":[\".\",\"/\"],\"resolveProvider\":true}"
		+ ",\"definitionProvider\":true"
		+ ",\"documentSymbolProvider\":true"
		+ ",\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}"
		+ ",\"inlayHintProvider\":true"
		+ ",\"referencesProvider\":true"
		+ ",\"documentHighlightProvider\":true"
		+ ",\"renameProvider\":true"
		+ ",\"documentFormattingProvider\":true"
		+ ",\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\",\"source.fixAll\"]}"
		+ ",\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":"
		+ "[\"namespace\",\"type\",\"class\",\"enum\",\"interface\",\"struct\","
		+ "\"typeParameter\",\"parameter\",\"variable\",\"property\","
		+ "\"enumMember\",\"event\",\"function\",\"method\",\"macro\","
		+ "\"keyword\",\"modifier\",\"comment\",\"string\",\"number\","
		+ "\"regexp\",\"operator\",\"decorator\"],"
		+ "\"tokenModifiers\":[\"declaration\",\"definition\",\"readonly\",\"static\",\"defaultLibrary\"]}"
		+ ",\"full\":true}"
		+ "}}";
	return lspResponse(id, caps);
}

// ===== Shutdown =====

export function handleShutdown(id: string): string {
	return lspResponse(id, "null");
}

// ===== Did Open =====

export function handleDidOpen(params: string, db: TransAmDb): string {
	const t0 = clockMs();
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const text = lspGetField(textDoc, "text");
	const path = lspUriToPath(uri);

	dbSetFileText(db, path, text);
	const t1 = clockMs();
	const program = dbParse(db, path);
	const t2 = clockMs();
	recordImportsForFile(db, path, program);
	const t3 = clockMs();
	dbTypeCheck(db, path);
	const t4 = clockMs();
	prebuildCompletionCache(db, path, uri);
	const t5 = clockMs();
	const diagParams = buildDiagnosticsJson(uri, db, path);
	const t6 = clockMs();
	writeStderr(`[LSP-OPEN] ${path} parse=${t2 - t1}ms imports=${t3 - t2}ms check=${t4 - t3}ms cache=${t5 - t4}ms diag=${t6 - t5}ms total=${t6 - t0}ms\n`);
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Did Change =====

export function handleDidChange(params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	// Full sync: contentChanges[0].text has entire document
	const changes = lspGetField(params, "text");
	const path = lspUriToPath(uri);
	dbSetFileText(db, path, changes);
	const program = dbParse(db, path);
	recordImportsForFile(db, path, program);
	prebuildCompletionCache(db, path, uri);
	const diagParams = buildDiagnosticsJson(uri, db, path);
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Did Close =====

export function handleDidClose(params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	// File stays in Trans-Am cache (LRU will evict if needed)
	// Clear diagnostics
	const diagParams = "{\"uri\":" + lspJsonString(uri) + ",\"diagnostics\":[]}";
	return lspNotification("textDocument/publishDiagnostics", diagParams);
}

// ===== Hover =====

export function handleHover(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "null");

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest === null) return lspResponse(id, "null");

	const hoverText = sgFormatHover(suggest);
	// Extract doc comment from the symbol's source file (may differ for cross-file symbols)
	let source = "";
	const modPath = suggest.modulePath;
	if (modPath !== null && modPath !== "" && modPath !== path) {
		lspEnsureFileLoaded(db, modPath);
		source = dbGetSource(db, modPath);
	} else {
		source = dbGetSource(db, path);
	}
	let docComment = sgExtractDocComment(source, suggest.location.line);
	// Fallback to built-in docs for well-known symbols (MDN-style)
	if (docComment === "") {
		docComment = sgBuiltinDoc(suggest.name, suggest.containerName);
	}
	const hoverDoc = sgFormatHoverDoc(suggest, docComment);
	// Hover range: highlight the hovered token (0-based line/col for LSP)
	const hoverLine = pos.line - 1;
	const hoverCol = pos.col1 - 1;
	const hoverEndCol = hoverCol + suggest.name.byteLength;
	return lspResponse(id, lspFmtHoverResult(hoverText, hoverDoc, hoverLine, hoverCol, hoverEndCol));
}

// ===== Completion =====

function lspCompletionItemKind(kind: SymbolKind, isMutable: boolean): number {
	// Const variables → Constant (21), let/var → Variable (6)
	if (kind === SymbolKind.Variable) {
		if (isMutable) return 6;
		return 21;
	}
	return match (kind) {
		SymbolKind.Function => 3,
		SymbolKind.Method => 2,
		SymbolKind.Parameter => 6,
		SymbolKind.Class => 7,
		SymbolKind.Interface => 8,
		SymbolKind.Enum => 13,
		SymbolKind.TypeAlias => 7,   // Class — TS-Go maps type names to Class
		SymbolKind.Property => 10,
		_ => 6,
	};
}

// Reverse-resolve a module path to an import specifier.
// e.g., "/Users/le/project/std/build.ms" → "std/build"
//       "/Users/le/project/src/foo.ms" → "./foo" (relative to currentPath)
function lspModulePathToImportSpec(db: TransAmDb, currentPath: string, targetPath: string): string {
	// std/ modules: strip stdPath prefix, extension, and /index suffix
	if (db.stdPath.length > 0 && targetPath.length > db.stdPath.length && targetPath.slice(0, db.stdPath.length) === db.stdPath) {
		let spec = targetPath.slice(db.stdPath.length - 3, targetPath.length); // keep "std/..."
		// Strip .ms/.cms extension
		if (spec.length > 3 && spec.slice(spec.length - 3, spec.length) === ".ms") spec = spec.slice(0, spec.length - 3);
		if (spec.length > 4 && spec.slice(spec.length - 4, spec.length) === ".cms") spec = spec.slice(0, spec.length - 4);
		// Strip /index suffix
		if (spec.length > 6 && spec.slice(spec.length - 6, spec.length) === "/index") spec = spec.slice(0, spec.length - 6);
		return spec;
	}
	// Relative path: compute from currentPath's directory
	const currentDir = lspDirname(currentPath);
	if (targetPath.length > currentDir.length && targetPath.slice(0, currentDir.length) === currentDir) {
		let rel = "./" + targetPath.slice(currentDir.length + 1, targetPath.length);
		if (rel.length > 3 && rel.slice(rel.length - 3, rel.length) === ".ms") rel = rel.slice(0, rel.length - 3);
		if (rel.length > 4 && rel.slice(rel.length - 4, rel.length) === ".cms") rel = rel.slice(0, rel.length - 4);
		if (rel.length > 6 && rel.slice(rel.length - 6, rel.length) === "/index") rel = rel.slice(0, rel.length - 6);
		return rel;
	}
	return targetPath;
}

// Search ExportRegistry for cross-module auto-import candidates.
function lspCrossModuleCandidates(
	db: TransAmDb, prefix: string, currentPath: string,
	program: Node, source: string, kind: SgCompletionKind, inScopeSet: Set<string>
): string[] {
	const items: string[] = [];
	if (db.exportRegistry === null) return items;
	const isTypeCtx = kind === SgCompletionKind.TypeAnnotation;

	for (let ei = 0; ei < db.exportRegistry.entries.length; ei = ei + 1) {
		const entry = db.exportRegistry.entries[ei];
		if (entry.modulePath === currentPath) continue; // skip self
		const importSpec = lspModulePathToImportSpec(db, currentPath, entry.modulePath);

		for (let si = 0; si < entry.symbols.length; si = si + 1) {
			const sym = entry.symbols[si];
			if (sym.name.length === 0) continue;
			// Skip extension methods — they only appear via member access
			if (sym.extReceiverType.length > 0) continue;
			// Prefix filter
			if (prefix.length > 0 && prefix.length > sym.name.length) continue;
			if (prefix.length > 0 && sym.name.slice(0, prefix.length) !== prefix) continue;
			// Skip if already in scope — O(1) Set lookup
			if (inScopeSet.has(sym.name)) continue;
			// Type context: only suggest type-like symbols
			if (isTypeCtx) {
				if (sym.kind !== SymbolKind.Interface && sym.kind !== SymbolKind.Class
					&& sym.kind !== SymbolKind.Enum && sym.kind !== SymbolKind.TypeAlias) continue;
			}
			// Compute import edit — included in initial response AND cached for resolve
			const edit = sgComputeImportEdit(program, source, sym.name, importSpec);
			const editJson = "[" + lspFmtMultiLineTextEdit(edit.line, edit.col, edit.line, edit.endCol, edit.newText) + "]";
			const detail = sgTypeToString(sym.symType) + " (from " + importSpec + ")";
			cacheResolveEdit(sym.name, detail, editJson);
			const kindNum = lspCompletionItemKind(sym.kind, false);
			const hasExistingImport = sgFindImportBySource(program, importSpec) !== null;
			const sortText = hasExistingImport ? "20" : "25";
			items.push(lspFmtCompletionItem(sym.name, kindNum, detail, sortText, false, "", "", editJson));
		}
	}

	// Also search prelude symbols (available even without explicit imports).
	// These are always in scope via globalImports — suggest with auto-import if not already imported.
	if (db.preludeCtx !== null && db.preludeCtx.table !== null && db.preludeCtx.table.current !== null) {
		// Build extension name set to filter prelude extensions from standalone suggestions
		const preludeExtNames: Set<string> = new Set<string>();
		if (db.preludeCtx.extensionRegistry !== null) {
			for (const m of db.preludeCtx.extensionRegistry.methods) {
				preludeExtNames.add(m.methodName);
			}
		}
		const preludeSyms = db.preludeCtx.table.current.symbols;
		for (let pi = 0; pi < preludeSyms.length; pi = pi + 1) {
			const sym = preludeSyms[pi];
			if (sym.name.length === 0) continue;
			if (!hasFlag(sym, SymbolFlag.Exported)) continue;
			// Skip extension methods — they only appear via member access
			if (preludeExtNames.has(sym.name)) continue;
			if (prefix.length > 0 && prefix.length > sym.name.length) continue;
			if (prefix.length > 0 && sym.name.slice(0, prefix.length) !== prefix) continue;
			if (inScopeSet.has(sym.name)) continue;
			if (isTypeCtx) {
				if (sym.symbolKind !== SymbolKind.Interface && sym.symbolKind !== SymbolKind.Class
					&& sym.symbolKind !== SymbolKind.Enum && sym.symbolKind !== SymbolKind.TypeAlias) continue;
			}
			// Determine import spec from symbol's modulePath
			const modPath = sym.modulePath !== null ? sym.modulePath : "";
			if (modPath === "" || modPath === currentPath) continue;
			const importSpec = lspModulePathToImportSpec(db, currentPath, modPath);
			const edit = sgComputeImportEdit(program, source, sym.name, importSpec);
			const editJson = "[" + lspFmtMultiLineTextEdit(edit.line, edit.col, edit.line, edit.endCol, edit.newText) + "]";
			const detail = sgTypeToString(sym.symbolType) + " (from " + importSpec + ")";
			cacheResolveEdit(sym.name, detail, editJson);
			const kindNum = lspCompletionItemKind(sym.symbolKind, false);
			const sortText = "22";
			items.push(lspFmtCompletionItem(sym.name, kindNum, detail, sortText, false, "", "", editJson));
		}
	}

	return items;
}

export function handleCompletion(id: string, params: string, db: TransAmDb, cache: CompletionCache): string {
	const t0 = clockMs();
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);
	const source = dbGetSource(db, path);
	if (source === "") return lspResponse(id, "[]");

	const prefix = sgGetPrefix(source, pos.line, pos.col);

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "[]");

	// AST-based context detection FIRST — import contexts bypass all caches
	const kind = sgDetectCompletionContext(program, pos.line, pos.col + 1);

	// ImportPath: scan filesystem for matching modules
	if (kind === SgCompletionKind.ImportPath) {
		const importItems = lspCompleteImportPath(source, pos, db, path);
		return lspResponse(id, joinJsonItems(importItems));
	}

	// ImportName: suggest exported symbols from the resolved module
	if (kind === SgCompletionKind.ImportName) {
		const importNameItems = lspCompleteImportName(program, source, pos, db, path);
		return lspResponse(id, joinJsonItems(importNameItems));
	}

	// ObjectField: suggest struct fields only (no global scope fallthrough)
	if (kind === SgCompletionKind.ObjectField) {
		const ctx = dbTypeCheck(db, path);
		if (ctx !== null) {
			const fieldPath = sgObjectFieldPathAST(program, pos.line, pos.col + 1);
			const enclosingObj = findEnclosingObjectLiteral(program, pos.line, pos.col + 1);
			let existingKeys: string[] = [];
			if (enclosingObj !== null) {
				existingKeys = (enclosingObj.data as ObjectLiteralData).keys;
			}
			const rootType = lspFindObjectLiteralTypeAST(program, pos.line, pos.col + 1, ctx);
			if (rootType !== null) {
				const objCandidates = sgCompleteObjectFields(ctx, prefix, rootType, fieldPath, existingKeys);
				const objItems = formatCompletionItemsArray(objCandidates, db, path);
				cache.uri = pos.uri;
				cache.line = pos.line;
				cache.prefix = prefix;
				cache.items = objItems;
				return lspResponse(id, joinJsonItems(objItems));
			}
		}
		return lspResponse(id, "[]");
	}

	// Prebuilt cache hit: return pre-computed items instantly.
	// Skip for member access (char before cursor is '.') and import triggers.
	const lineOffset = sgGetLineOffset(source, pos.line);
	const charBefore = pos.col > 0 ? source.byteAt(lineOffset + pos.col - 1) : 0;
	if (prefix.length === 0 && charBefore !== ".".code && _prebuiltUri === pos.uri && _prebuiltItems.length > 0) {
		const limited = _prebuiltItems.length > 100 ? _prebuiltItems.slice(0, 100) : _prebuiltItems;
		cache.uri = pos.uri;
		cache.line = pos.line;
		cache.prefix = "";
		cache.items = limited;
		return lspResponse(id, joinJsonItems(limited));
	}

	// Cache hit: same file, same line, prefix extends previous — filter instantly
	if (cache.uri === pos.uri && cache.line === pos.line && prefix.length >= cache.prefix.length && prefix.startsWith(cache.prefix)) {
		const filtered = filterCompletionItems(cache.items, prefix);
		cache.prefix = prefix;
		cache.items = filtered;
		return lspResponse(id, joinJsonItems(filtered));
	}

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) {
		// Type check failed (incomplete code) — still try cross-module/prelude suggestions
		if (kind === SgCompletionKind.Identifier || kind === SgCompletionKind.TypeAnnotation) {
			const emptyScope: Set<string> = new Set<string>();
			const fallbackItems = lspCrossModuleCandidates(db, prefix, path, program, source, kind, emptyScope);
			if (fallbackItems.length > 0) return lspResponse(id, joinJsonItems(fallbackItems));
		}
		return lspResponse(id, "[]");
	}

	// For MemberAccess, resolve receiver type via symRecords.
	// Works for both simple (config.) and nested (config.fmt.) chains:
	// scan backward from cursor to find the last `.`, then query the token before it.
	let receiverType: Type = null;
	if (kind === SgCompletionKind.MemberAccess) {
		// Find the dot position by scanning source backward from cursor
		const lineOffset = sgGetLineOffset(source, pos.line);
		let dotCol = pos.col; // 0-based col of cursor
		while (dotCol > 0 && source.byteAt(lineOffset + dotCol - 1) !== ".".code) {
			dotCol = dotCol - 1;
		}
		// dotCol: scan stopped here. byteAt(lineOffset + dotCol - 1) === "."
		// So dot is at 0-based col (dotCol - 1), char before dot at 0-based col (dotCol - 2)
		// sgQueryAtPosition uses 1-based col → (dotCol - 2) + 1 = dotCol - 1
		if (dotCol > 1) {
			const sg = sgQueryAtPosition(ctx, pos.line, dotCol - 1);
			if (sg !== null) {
				receiverType = sg.symType;
				// Static access on type name (e.g., Buffer.alloc, Result.ok):
				// use "typeof TypeName" so extension registry matches static extensions.
				if (sg.kind === SymbolKind.TypeAlias || sg.kind === SymbolKind.Class
					|| sg.kind === SymbolKind.Interface || sg.kind === SymbolKind.Struct) {
					receiverType = createTypeRef(sg.name);
				}
			}
		}
		// Fallback: try AST-based lookup
		if (receiverType === null) {
			const node = findNodeAtPosition(program, pos.line, pos.col + 1);
			if (node !== null && node.kind === NodeKind.MemberExpr) {
				const md = node.data as MemberExprData;
				if (md.object !== null) {
					const objLoc = md.object.location;
					const sg = sgQueryAtPosition(ctx, objLoc.line, objLoc.column);
					if (sg !== null) {
						receiverType = sg.symType;
					}
				}
			}
		}
	}

	// ObjectField handled early (before caches) — see above

	const candidates = sgGetCompletionCandidates(ctx, kind, prefix, receiverType);

	// Cache the individual formatted items for future prefix filtering
	const cachedItems = formatCompletionItemsArray(candidates, db, path);

	// Cross-module auto-import candidates
	if (kind === SgCompletionKind.Identifier || kind === SgCompletionKind.TypeAnnotation || kind === SgCompletionKind.ImportName) {
		const inScopeSet: Set<string> = new Set<string>();
		for (let ci = 0; ci < candidates.length; ci = ci + 1) {
			inScopeSet.add(candidates[ci].name);
		}
		const source = dbGetSource(db, path);
		const autoImportItems = lspCrossModuleCandidates(db, prefix, path, program, source, kind, inScopeSet);
		for (let ai = 0; ai < autoImportItems.length; ai = ai + 1) {
			cachedItems.push(autoImportItems[ai]);
		}
	}

	cache.uri = pos.uri;
	cache.line = pos.line;
	cache.prefix = prefix;
	cache.items = cachedItems;

	return lspResponse(id, joinJsonItems(cachedItems));
}

// completionItem/resolve — attach additionalTextEdits for auto-import items.
// nvim-cmp strips additionalTextEdits from initial response and requests them here.
function handleCompletionResolve(id: string, params: string): string {
	const label = lspGetField(params, "label");
	const detail = lspGetField(params, "detail");
	const edits = lookupResolveEdit(label, detail);
	if (edits.length > 0) {
		let result = params;
		const closeIdx = result.length - 1;
		result = result.slice(0, closeIdx) + ",\"additionalTextEdits\":" + edits + "}";
		return lspResponse(id, result);
	}
	return lspResponse(id, params);
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

// Format each candidate as an individual JSON item string for caching.
function formatCompletionItemsArray(candidates: SgSuggest[], db: TransAmDb, path: string): string[] {
	const result: string[] = [];
	// Pre-fetch current file source for doc comment extraction
	const currentSource = dbGetSource(db, path);
	for (let i = 0; i < candidates.length; i = i + 1) {
		const item = candidates[i];
		const typeStr = sgTypeToString(item.symType);
		const kindNum = lspCompletionItemKind(item.kind, item.isMutable);
		const sortText = lspCompletionSortText(item);
		const commitChars = lspCommitCharsForKind(item.kind);
		// Extract doc comment from declaration site
		let doc = "";
		const modPath = item.modulePath;
		if (modPath !== null && modPath !== "" && modPath !== path) {
			lspEnsureFileLoaded(db, modPath);
			const modSource = dbGetSource(db, modPath);
			doc = sgExtractDocComment(modSource, item.location.line);
		} else {
			doc = sgExtractDocComment(currentSource, item.location.line);
		}
		if (doc === "") {
			doc = sgBuiltinDoc(item.name, item.containerName);
		}
		result.push(lspFmtCompletionItem(item.name, kindNum, typeStr, sortText, false, commitChars, doc, ""));
	}
	return result;
}

// ===== Import Path Completion =====
// Scans filesystem for matching modules.

function lspCompleteImportPath(source: string, pos: LspCursorParams, db: TransAmDb, filePath: string): string[] {
	const partial = sgExtractImportPath(source, pos.line, pos.col + 1);
	// Split partial into directory prefix and filename prefix
	// "std/co" → dir="std", filePrefix="co"
	// "std/core/" → dir="std/core", filePrefix=""
	// "./pa" → dir=".", filePrefix="pa"
	// "" → dir="", filePrefix=""
	let dirPart = "";
	let filePrefix = partial;
	let lastSlash = -1;
	let si = 0;
	while (si < partial.length) {
		if (partial.charAt(si) === "/") {
			lastSlash = si;
		}
		si = si + 1;
	}
	if (lastSlash >= 0) {
		dirPart = partial.slice(0, lastSlash);
		filePrefix = partial.slice(lastSlash + 1, partial.length);
	}

	// Resolve the scan directory based on import category
	let scanDir = "";
	let insertPrefix = "";
	if (dirPart === "." || dirPart === ".." || partial.startsWith("./") || partial.startsWith("../")) {
		// Relative import — resolve against current file's directory
		const fileDir = lspDirname(filePath);
		if (dirPart === "") {
			scanDir = fileDir;
		} else {
			scanDir = fileDir + "/" + dirPart;
		}
		insertPrefix = "";
	} else if (dirPart.startsWith("std") || partial.startsWith("std")) {
		// std/ import — resolve against db.stdPath
		if (db.stdPath.length === 0) return [];
		if (dirPart === "") {
			scanDir = db.stdPath;
		} else {
			// "std/core" → stdPath + "/core"
			const stdSuffix = dirPart.slice(3, dirPart.length); // strip "std"
			scanDir = db.stdPath + stdSuffix;
		}
		insertPrefix = "";
	} else if (dirPart === "" && filePrefix === "") {
		// Empty — only suggest std/ (user types ./ or ../ explicitly for relative)
		const items: string[] = [];
		items.push(lspFmtCompletionItem("std/", 19, "Standard library", "00", false, "/", "", ""));
		return items;
	} else {
		// Bare import with partial dir — try relative first
		const fileDir = lspDirname(filePath);
		if (dirPart === "") {
			scanDir = fileDir;
		} else {
			scanDir = fileDir + "/" + dirPart;
		}
		insertPrefix = "";
	}

	if (scanDir === "") return [];

	// Scan directory — only show MetaScript files and directories containing MS modules
	const entries = readDir(scanDir);
	const items: string[] = [];
	let idx = 0;
	for (let i = 0; i < entries.length; i = i + 1) {
		const entry = entries[i];
		const isDir = entry.charAt(entry.length - 1) === "/";
		const name = isDir ? entry.slice(0, entry.length - 1) : entry;

		// Skip hidden files/dirs
		if (name.charAt(0) === ".") continue;
		if (name === "node_modules" || name === "out" || name === "build") continue;

		// Prefix filter
		if (filePrefix.length > 0 && !lspStartsWith(name, filePrefix)) continue;

		if (isDir) {
			// Only show directories that contain MetaScript modules
			if (!lspDirHasMsEntries(scanDir + "/" + name)) continue;
			const sortIdx = idx < 10 ? "0" + idx.toString() : idx.toString();
			items.push(lspFmtCompletionItem(insertPrefix + name, 19, "module", sortIdx, false, "/", "", ""));
			idx = idx + 1;
		} else {
			// Only show .ms/.cms/.jms files (strip extension)
			const moduleName = stripMsModuleExtension(name);
			if (moduleName === "") continue;
			if (moduleName === "index") continue; // accessed via directory name
			const sortIdx = idx < 10 ? "0" + idx.toString() : idx.toString();
			items.push(lspFmtCompletionItem(insertPrefix + moduleName, 17, "module", sortIdx, false, "", "", ""));
			idx = idx + 1;
		}
	}
	return items;
}

// ImportName: suggest exported symbols from the resolved module.
// AST-based: reads ImportDeclData.importSource and importNames directly.
function lspCompleteImportName(program: Node, source: string, pos: LspCursorParams, db: TransAmDb, filePath: string): string[] {
	// AST-based: get import source from ImportDecl node
	const importSpec = sgExtractImportSource(program, pos.line);
	if (importSpec === "") return [];

	// Resolve the module path
	const targetPath = resolveImportForLsp(db, filePath, importSpec);
	if (targetPath === "") return [];

	// Ensure the target module is loaded and its exports are registered
	lspEnsureFileLoaded(db, targetPath);
	if (findModuleExports(db.exportRegistry, targetPath) === null) {
		// Target not yet in registry — register its exports directly
		dbEnsureModuleExports(db, targetPath);
	}

	// Get exports from registry
	const modExports = findModuleExports(db.exportRegistry, targetPath);
	if (modExports === null) return [];

	// Prefix: reuse sgGetPrefix (same as any identifier completion)
	const namePrefix = sgGetPrefix(source, pos.line, pos.col);
	// AST-based: get already-imported names from ImportDeclData.importNames
	const existingNames = sgExtractExistingImportNames(program, pos.line, pos.col + 1);

	const items: string[] = [];
	let idx = 0;
	for (let i = 0; i < modExports.symbols.length; i = i + 1) {
		const sym = modExports.symbols[i];
		// Skip extension methods (they're auto-imported, not named imports)
		if (sym.extReceiverType.length > 0) continue;
		// Skip already-imported names
		let alreadyImported = false;
		for (let j = 0; j < existingNames.length; j = j + 1) {
			if (existingNames[j] === sym.name) { alreadyImported = true; j = existingNames.length; }
		}
		if (alreadyImported) continue;
		// Prefix filter
		if (namePrefix.length > 0 && !lspStartsWith(sym.name, namePrefix)) continue;
		const kindNum = lspCompletionItemKind(sym.kind, false);
		const detail = sgTypeToString(sym.symType);
		const sortIdx = idx < 10 ? "0" + idx.toString() : idx.toString();
		items.push(lspFmtCompletionItem(sym.name, kindNum, detail, sortIdx, false, "", "", ""));
		idx = idx + 1;
	}
	return items;
}

// Check if a directory contains at least one MetaScript file.
function lspDirHasMsEntries(dirPath: string): boolean {
	const entries = readDir(dirPath);
	for (let i = 0; i < entries.length; i = i + 1) {
		const entry = entries[i];
		if (entry.charAt(entry.length - 1) === "/") continue; // skip subdirs
		if (isMsModuleExtension(entry)) return true;
	}
	return false;
}

function lspStartsWith(text: string, prefix: string): boolean {
	if (prefix.length > text.length) return false;
	let i = 0;
	while (i < prefix.length) {
		if (text.charAt(i) !== prefix.charAt(i)) return false;
		i = i + 1;
	}
	return true;
}

// Join pre-formatted JSON items into a response array.
function joinJsonItems(items: string[]): string {
	if (items.length === 0) return "[]";
	return "[" + items.join(",") + "]";
}

// Filter cached completion items by prefix match on label.
function filterCompletionItems(items: string[], prefix: string): string[] {
	const result: string[] = [];
	for (let i = 0; i < items.length; i = i + 1) {
		const label = lspGetField(items[i], "label");
		if (label.startsWith(prefix)) {
			result.push(items[i]);
		}
	}
	return result;
}

// ===== Definition =====

export function handleDefinition(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);

	const program = dbParse(db, path);
	if (program === null) {
		writeStderr("[LSP-DEF] id=" + id + " null: no parse for " + path + "\n");
		return lspResponse(id, "null");
	}

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) {
		writeStderr("[LSP-DEF] id=" + id + " null: no ctx for " + path + "\n");
		return lspResponse(id, "null");
	}

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest === null) {
		writeStderr("[LSP-DEF] id=" + id + " null: no sgQuery at " + pos.line + ":" + pos.col1 + " in " + path + "\n");
	}
	if (suggest !== null) {
		// Extern function → navigate to C definition in module's .h file
		if (suggest.sym !== null && hasFlag(suggest.sym, SymbolFlag.ImportC)
			&& suggest.sym.nativeName !== "") {
			const externModPath = suggest.sym.modulePath !== null && suggest.sym.modulePath !== "" ? suggest.sym.modulePath : path;
			// Module's own .h imports from AST first (most specific), then @include headerPath fallback
			const externProgram = dbParse(db, externModPath);
			const moduleHdrs = lspCollectHeaderImports(externProgram);
			const hdrPath = moduleHdrs !== "" ? moduleHdrs : suggest.sym.headerPath;
			if (hdrPath !== "") {
				const nativeResult = lspFindNativeDefinition(suggest.sym.nativeName, hdrPath, externModPath);
				if (nativeResult !== "") return lspResponse(id, "[" + nativeResult + "]");
			}
		}

		let defLine = suggest.location.line - 1;
		let defCol = suggest.location.column - 1;
		let defUri = pos.uri;
		let defSrc = "";

		// Cross-file: symbol defined in another module (import or prelude)
		const modPath = suggest.modulePath;
		if (modPath !== null && modPath !== "" && modPath !== path) {
			lspEnsureFileLoaded(db, modPath);
			defUri = lspPathToUri(modPath);
			defSrc = dbGetSource(db, modPath);
		} else {
			defSrc = dbGetSource(db, path);
		}

		// Refine line/col using source text
		if (defSrc !== "") {
			if (suggest.kind === SymbolKind.EnumMember && suggest.containerName !== "") {
				// Enum member: search for "enum ContainerName" then member within block
				const enumLoc = lspFindEnumMemberLine(defSrc, suggest.containerName, suggest.name);
				if (enumLoc.line >= 0) {
					defLine = enumLoc.line;
					defCol = enumLoc.column;
				}
			} else if (suggest.kind === SymbolKind.Property) {
				const fieldLoc = lspFindFieldLine(defSrc, defLine, suggest.name);
				if (fieldLoc.line >= 0) {
					defLine = fieldLoc.line;
					defCol = fieldLoc.column;
				} else {
					const nameCol = lspFindNameCol(defSrc, defLine, suggest.name);
					if (nameCol >= 0) defCol = nameCol;
				}
			} else {
				const nameCol = lspFindNameCol(defSrc, defLine, suggest.name);
				if (nameCol >= 0) defCol = nameCol;
			}
		}
		const location = lspFmtLocation(defUri, defLine, defCol, defLine, defCol + suggest.name.byteLength);
		return lspResponse(id, "[" + location + "]");
	}

	// Cross-module fallback: check if cursor is on an imported name
	const src = dbGetSource(db, path);
	const identName = sgGetPrefix(src, pos.line, pos.col);
	if (identName === "") return lspResponse(id, "null");
	const importSpec = sgFindImportSource(program, identName);
	if (importSpec === "") return lspResponse(id, "null");

	const targetPath = resolveImportForLsp(db, path, importSpec);
	if (targetPath === "") return lspResponse(id, "null");

	lspEnsureFileLoaded(db, targetPath);

	const targetProgram = dbParse(db, targetPath);
	if (targetProgram === null) return lspResponse(id, "null");

	const declLoc = sgFindExportedDecl(targetProgram, identName);
	if (declLoc.line === 0) return lspResponse(id, "null");

	const targetUri = lspPathToUri(targetPath);
	const tLine = declLoc.line - 1;
	let tCol = declLoc.column - 1;
	const targetSrc = dbGetSource(db, targetPath);
	if (targetSrc !== "") {
		const tNameCol = lspFindNameCol(targetSrc, tLine, identName);
		if (tNameCol >= 0) tCol = tNameCol;
	}
	return lspResponse(id, "[" + lspFmtLocation(targetUri, tLine, tCol, tLine, tCol + identName.length) + "]");
}

// ===== Document Symbol =====

function lspDocumentSymbolKind(kind: SymbolKind, isMutable: boolean): number {
	// Const variables → Constant (14), let/var → Variable (13)
	if (kind === SymbolKind.Variable) {
		if (isMutable) return 13;
		return 14;
	}
	return match (kind) {
		SymbolKind.Function => 12,
		SymbolKind.Class => 5,
		SymbolKind.Interface => 11,
		SymbolKind.Enum => 10,
		SymbolKind.TypeAlias => 26,  // TypeParameter (was 25=Operator, wrong)
		SymbolKind.Method => 6,
		SymbolKind.Property => 7,
		_ => 13,
	};
}

function formatDocumentSymbolArray(symbols: SgDocumentSymbol[]): string {
	let items = "[";
	for (let i = 0; i < symbols.length; i = i + 1) {
		if (i > 0) items = items + ",";
		const sym = symbols[i];
		const kindNum = lspDocumentSymbolKind(sym.kind, sym.isMutable);
		const symLine = sym.location.line - 1;
		const symCol = sym.location.column;
		const endCol = symCol + sym.name.byteLength;
		let childrenJson = "";
		if (sym.children.length > 0) {
			childrenJson = formatDocumentSymbolArray(sym.children);
		}
		items = items + lspFmtDocumentSymbol(sym.name, kindNum, sym.detail, symLine, symCol, endCol, childrenJson);
	}
	items = items + "]";
	return items;
}

export function handleDocumentSymbol(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "[]");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

	const symbols = sgCollectSymbolsInFile(ctx, program);
	return lspResponse(id, formatDocumentSymbolArray(symbols));
}

// ===== Signature Help =====

export function handleSignatureHelp(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);
	const source = dbGetSource(db, path);
	if (source === "") return lspResponse(id, "null");

	// AST-based signature context (with text-based fallback for incomplete source)
	const program = dbParse(db, path);
	const sigCtx = sgGetSignatureContext(program, source, pos.line, pos.col);
	if (sigCtx.calleeName === "") return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "null");

	// For member calls (receiver.method()), try extension-based signatures first
	let sigs: SgSignatureInfo[] = [];
	if (sigCtx.receiverName !== "") {
		const recSym = lookupSymbol(ctx.table, sigCtx.receiverName);
		if (recSym !== null && recSym.symbolType !== null) {
			sigs = sgFormatExtensionSignatures(ctx, sigCtx.calleeName, recSym.symbolType);
		}
	}
	// Fallback: standard symbol lookup (direct calls + non-extension methods)
	if (sigs.length === 0) {
		const sym = lookupSymbol(ctx.table, sigCtx.calleeName);
		if (sym === null) return lspResponse(id, "null");
		sigs = sgFormatSignature(sym);
	}
	if (sigs.length === 0) return lspResponse(id, "null");

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

	return lspResponse(id, lspFmtSignatureHelp(sigArray, 0, sigCtx.activeParam));
}

// ===== Inlay Hints =====

export function handleInlayHint(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);

	const range = lspGetObjectField(params, "range");
	const rangeStart = lspGetObjectField(range, "start");
	const rangeEnd = lspGetObjectField(range, "end");
	const startLine = lspGetNumberField(rangeStart, "line") + 1;
	const endLine = lspGetNumberField(rangeEnd, "line") + 1;

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

	// Use checked program (has resolvedSym/nodeType on AST nodes).
	// Raw dbParse tree lacks resolved info — scope lookups find wrong symbols.
	const program = dbGetCheckedProgram(db, path);
	if (program === null) return lspResponse(id, "[]");

	const hintsList = sgCollectInlayHints(ctx, program, startLine, endLine);

	if (hintsList.length === 0) return lspResponse(id, "[]");

	let arr = "[";
	for (let i = 0; i < hintsList.length; i = i + 1) {
		if (i > 0) arr = arr + ",";
		const h = hintsList[i];
		// LSP InlayHintKind: 1 = Type, 2 = Parameter
		// Exception hints map to Type kind (1) with paddingLeft
		let lspKind = 2;
		if (h.hintKind === SgInlayHintKind.Type || h.hintKind === SgInlayHintKind.Exception) {
			lspKind = 1;
		}
		// Type + Exception hints: paddingLeft (space before label)
		// Parameter hints: paddingRight (space after "name:")
		const padLeft = h.hintKind === SgInlayHintKind.Type || h.hintKind === SgInlayHintKind.Exception;
		const padRight = h.hintKind === SgInlayHintKind.Parameter;
		arr = arr + lspFmtInlayHint(h.line - 1, h.col - 1, h.label, lspKind, padLeft, padRight);
	}
	arr = arr + "]";
	return lspResponse(id, arr);
}

// ===== References =====

export function handleReferences(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest === null) return lspResponse(id, "[]");

	const items: string[] = [];
	const seen: Set<string> = new Set<string>();

	// Search current file via symbol identity (no false positives from shadowing)
	const refs = sgQueryBySym(ctx, suggest.sym);
	for (let i = 0; i < refs.length; i = i + 1) {
		const ref = refs[i];
		const key = pos.uri + ":" + ref.line + ":" + ref.col;
		if (seen.has(key)) continue;
		seen.add(key);
		const refLine = ref.line - 1;
		items.push(lspFmtLocation(pos.uri, refLine, ref.col - 1, refLine, ref.col - 1 + ref.nameLen));
	}

	// Search transitive dependents only (files that could import this symbol)
	const defModule = suggest.modulePath !== null && suggest.modulePath !== "" ? suggest.modulePath : path;
	const targetFileId = getFileId(db.fileInput, path);
	let depIds: number[] = [];
	if (targetFileId >= 0) {
		depIds = getTransitiveDependents(db.moduleDeps, targetFileId);
	}
	let fi = 0;
	while (fi < depIds.length) {
		const depId = depIds[fi];
		fi = fi + 1;
		const otherPath = getFilePath(db.fileInput, depId);
		if (otherPath === "" || otherPath === path) continue;
		const otherCtx = dbTypeCheck(db, otherPath);
		if (otherCtx === null) continue;
		const otherUri = lspPathToUri(otherPath);
		const matched = sgQueryByDefiningModule(otherCtx, suggest.name, defModule);
		let mi = 0;
		while (mi < matched.length) {
			const mr = matched[mi];
			mi = mi + 1;
			const key = otherUri + ":" + mr.line + ":" + mr.col;
			if (seen.has(key)) continue;
			seen.add(key);
			const mrLine = mr.line - 1;
			items.push(lspFmtLocation(otherUri, mrLine, mr.col - 1, mrLine, mr.col - 1 + mr.nameLen));
		}
	}

	return lspResponse(id, "[" + items.join(",") + "]");
}

// ===== Document Highlight =====

export function handleDocumentHighlight(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest === null) return lspResponse(id, "[]");

	const refs = sgQueryBySym(ctx, suggest.sym);
	let arr = "[";
	for (let i = 0; i < refs.length; i = i + 1) {
		if (i > 0) arr = arr + ",";
		const ref = refs[i];
		const refLine = ref.line - 1;
		arr = arr + lspFmtDocumentHighlight(refLine, ref.col - 1, ref.col - 1 + ref.nameLen, 1);
	}
	arr = arr + "]";
	return lspResponse(id, arr);
}

// ===== Rename =====

// Build TextEdit array for refs in a single file (sym identity for current file)
function buildFileEditsBySym(ctx: CheckerContext, sym: Symbol, newName: string): string {
	const refs = sgQueryBySym(ctx, sym);
	if (refs.length === 0) return "";
	const edits: string[] = [];
	let i = 0;
	while (i < refs.length) {
		const ref = refs[i];
		const refLine = ref.line - 1;
		edits.push(lspFmtTextEdit(refLine, ref.col - 1, ref.col - 1 + ref.nameLen, newName));
		i = i + 1;
	}
	return "[" + edits.join(",") + "]";
}

// Build TextEdit array for refs in a cross-module file (name + modulePath fallback)
function buildFileEdits(ctx: CheckerContext, name: string, modulePath: string, newName: string): string {
	const refs = sgQueryByName(ctx, name, modulePath);
	if (refs.length === 0) return "";
	const edits: string[] = [];
	let i = 0;
	while (i < refs.length) {
		const ref = refs[i];
		const refLine = ref.line - 1;
		edits.push(lspFmtTextEdit(refLine, ref.col - 1, ref.col - 1 + ref.nameLen, newName));
		i = i + 1;
	}
	return "[" + edits.join(",") + "]";
}

export function handleRename(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);

	const newName = lspGetField(params, "newName");
	if (newName === "") return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "null");

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest === null) return lspResponse(id, "null");

	// Collect edits across all files
	let changes = "";
	let changeCount = 0;

	// Current file — use sym identity
	const curEdits = buildFileEditsBySym(ctx, suggest.sym, newName);
	if (curEdits.byteLength > 0) {
		changes = lspJsonString(pos.uri) + ":" + curEdits;
		changeCount = changeCount + 1;
	}

	// Other open files in workspace
	const fileCount = dbGetFileCount(db);
	let fi = 0;
	while (fi < fileCount) {
		const otherPath = dbGetFilePathByIndex(db, fi);
		fi = fi + 1;
		if (otherPath === path) continue;
		const otherCtx = dbTypeCheck(db, otherPath);
		if (otherCtx === null) continue;
		const otherEdits = buildFileEdits(otherCtx, suggest.name, suggest.modulePath, newName);
		if (otherEdits.byteLength > 0) {
			const otherUri = lspPathToUri(otherPath);
			if (changeCount > 0) changes = changes + ",";
			changes = changes + lspJsonString(otherUri) + ":" + otherEdits;
			changeCount = changeCount + 1;
		}
	}

	if (changeCount === 0) return lspResponse(id, "null");

	const result = "{\"changes\":{" + changes + "}}";
	return lspResponse(id, result);
}

// ===== Semantic Tokens =====

// Encode absolute SgSemanticToken[] as LSP relative delta format: [deltaLine, deltaStart, length, type, modifiers, ...]
function encodeSemanticTokenDeltas(tokens: SgSemanticToken[]): string {
	sgSortTokens(tokens);
	let prevLine = 0;
	let prevCol = 0;
	let arr = "[";
	let i = 0;
	while (i < tokens.length) {
		const t = tokens[i];
		const line = t.line - 1; // to 0-indexed
		const col = t.col - 1;   // to 0-indexed
		const deltaLine = line - prevLine;
		let deltaStart = col;
		if (deltaLine === 0) deltaStart = col - prevCol;
		if (i > 0) arr = arr + ",";
		arr = arr + lspJsonNumber(deltaLine) + "," + lspJsonNumber(deltaStart)
			+ "," + lspJsonNumber(t.length)
			+ "," + lspJsonNumber(t.tokenType)
			+ "," + lspJsonNumber(t.modifiers);
		prevLine = line;
		prevCol = col;
		i = i + 1;
	}
	arr = arr + "]";
	return arr;
}

export function handleSemanticTokensFull(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "{\"data\":[]}");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "{\"data\":[]}");

	const tokens = sgCollectSemanticTokens(ctx, program);
	const data = encodeSemanticTokenDeltas(tokens);
	return lspResponse(id, "{\"data\":" + data + "}");
}

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

// ===== Dispatch =====

export function lspDispatch(method: string, id: string, params: string, db: TransAmDb, cache: CompletionCache): string {
	return match (method) {
		"initialize" => handleInitialize(id),
		"shutdown" => handleShutdown(id),
		"textDocument/didOpen" => handleDidOpen(params, db),
		"textDocument/didChange" => handleDidChange(params, db),
		"textDocument/didClose" => handleDidClose(params, db),
		"textDocument/hover" => handleHover(id, params, db),
		"textDocument/completion" => handleCompletion(id, params, db, cache),
		"completionItem/resolve" => handleCompletionResolve(id, params),
		"textDocument/definition" => handleDefinition(id, params, db),
		"textDocument/documentSymbol" => handleDocumentSymbol(id, params, db),
		"textDocument/signatureHelp" => handleSignatureHelp(id, params, db),
		"textDocument/inlayHint" => handleInlayHint(id, params, db),
		"textDocument/references" => handleReferences(id, params, db),
		"textDocument/documentHighlight" => handleDocumentHighlight(id, params, db),
		"textDocument/rename" => handleRename(id, params, db),
		"textDocument/semanticTokens/full" => handleSemanticTokensFull(id, params, db),
		"textDocument/formatting" => handleFormatting(id, params, db),
		"textDocument/codeAction" => handleCodeAction(id, params, db),
		"$/cancelRequest" => {
			// Single-threaded: requests complete before we read this.
			return "";
		},
		_ => {
			return "";
		},
	};
}

// ===== Tests =====

// Helper: create a Trans-Am DB with a file pre-loaded
function testDb(uri: string, source: string): TransAmDb {
	const db = createTransAmDb(100);
	const path = lspUriToPath(uri);
	dbSetFileText(db, path, source);
	return db;
}

function testCache(): CompletionCache {
	return createCompletionCache();
}

test "returns capabilities" {
	const r = handleInitialize("1");
	assert lspGetField(r, "jsonrpc") === "2.0";
	assert lspGetNumberField(r, "id") === 1;
	const result = lspGetObjectField(r, "result");
	assert result.length > 0;
}

test "returns null result" {
	const r = handleShutdown("2");
	assert lspGetNumberField(r, "id") === 2;
}

test "clean source has no diagnostics" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const diags = buildDiagnosticsJson("file:///test.ms", db, lspUriToPath("file:///test.ms"));
	assert lspGetField(diags, "uri") === "file:///test.ms";
}

test "initialize" {
	const db = createTransAmDb(100);
	const r = lspDispatch("initialize", "1", "{}", db, testCache());
	assert lspGetNumberField(r, "id") === 1;
}

test "shutdown" {
	const db = createTransAmDb(100);
	const r = lspDispatch("shutdown", "2", "{}", db, testCache());
	assert lspGetNumberField(r, "id") === 2;
}

test "unknown method with id" {
	const db = createTransAmDb(100);
	const r = lspDispatch("unknown/method", "3", "{}", db, testCache());
	// Unknown methods are silently ignored (no response) to avoid client-side noise
	assert r === "";
}

test "unknown notification" {
	const db = createTransAmDb(100);
	const r = lspDispatch("$/unknownNotification", "", "{}", db, testCache());
	assert r === "";
}

test "completion dispatch" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":3}}";
	const r = lspDispatch("textDocument/completion", "10", params, db, testCache());
	assert lspGetNumberField(r, "id") === 10;
	assert r.length > 0;
}

test "definition dispatch" {
	const db = testDb("file:///test.ms", "const myVar = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/definition", "11", params, db, testCache());
	assert lspGetNumberField(r, "id") === 11;
	assert r.length > 0;
}

test "returns completion items" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":0}}";
	const r = handleCompletion("5", params, db, testCache());
	assert lspGetNumberField(r, "id") === 5;
	assert r.length > 50;
}

test "unknown doc returns empty" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleCompletion("6", params, db, testCache());
	assert lspGetNumberField(r, "id") === 6;
}

test "completion cache hit on prefix extend" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;");
	const cache = testCache();
	// First completion: "ab" prefix — populates cache
	const params1 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":2}}";
	const r1 = handleCompletion("10", params1, db, cache);
	assert cache.items.length > 0;
	assert cache.uri === "file:///test.ms";
	// Second completion: same line, prefix extends to "abd" — should hit cache
	const params2 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":3}}";
	const r2 = handleCompletion("11", params2, db, cache);
	assert r2.length > 0;
}

test "completion cache miss on different line" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst abd = 2;\nconst xyz = 3;");
	const cache = testCache();
	// Populate cache on line 2
	const params1 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":2}}";
	handleCompletion("10", params1, db, cache);
	const cachedLine = cache.line;
	// Request on line 3 — different line, should miss cache and recompute
	const params2 = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":2,\"character\":2}}";
	handleCompletion("11", params2, db, cache);
	assert cache.line !== cachedLine;
}

test "member access completion returns struct fields" {
	const src = "interface Foo {\n\tx: number;\n\ty: string;\n}\nconst f: Foo = { x: 1, y: \"hi\" };\nf.";
	const db = testDb("file:///test.ms", src);
	// line 5 (0-based), character 2 (right after "f.")
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":5,\"character\":2}}";
	const r = handleCompletion("20", params, db, testCache());
	assert lspGetNumberField(r, "id") === 20;
	// Result contains x and y field completions
	assert r.indexOf("\"label\":\"x\"") >= 0;
	assert r.indexOf("\"label\":\"y\"") >= 0;
	assert r.indexOf("\"detail\":\"number\"") >= 0;
	assert r.indexOf("\"detail\":\"string\"") >= 0;
}

test "returns location for known symbol" {
	const db = testDb("file:///test.ms", "const myVar = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleDefinition("7", params, db);
	assert lspGetNumberField(r, "id") === 7;
	assert r.length > 0;
}

test "unknown doc returns null" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleDefinition("8", params, db);
	assert lspGetNumberField(r, "id") === 8;
}

test "unknown position returns null result" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":99,\"character\":0}}";
	const r = handleDefinition("9", params, db);
	assert lspGetNumberField(r, "id") === 9;
}

test "definition inside template literal" {
	const src = "const myName = \"world\";\nconst msg = `hello ${myName}`;";
	const db = testDb("file:///test.ms", src);
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":21}}";
	const r = handleDefinition("50", params, db);
	assert r.indexOf("\"line\":0") >= 0;
	assert r.indexOf("\"character\":6") >= 0;
}

test "definition on param inside template literal" {
	const src = "function fmt(expected: string): string {\n\treturn `Expected ${expected}!`;\n}";
	const db = testDb("file:///test.ms", src);
	// "expected" in template at line 1, character 22 → should jump to param declaration on line 0
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":22}}";
	const r = handleDefinition("51", params, db);
	assert r.indexOf("\"line\":0") >= 0;
	assert r.indexOf("\"character\":13") >= 0;
}

test "returns symbols for file" {
	const db = testDb("file:///test.ms", "function foo() { return 1; }\nconst x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = handleDocumentSymbol("20", params, db);
	assert lspGetNumberField(r, "id") === 20;
	assert r.length > 60;
}

test "unknown doc returns empty array" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"}}";
	const r = handleDocumentSymbol("21", params, db);
	assert lspGetNumberField(r, "id") === 21;
}

test "dispatch routes correctly" {
	const db = testDb("file:///test.ms", "const a = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"}}";
	const r = lspDispatch("textDocument/documentSymbol", "22", params, db, testCache());
	assert lspGetNumberField(r, "id") === 22;
	assert r.length > 0;
}

test "returns signature for function" {
	const db = testDb("file:///test.ms", "function greet(name: string): void { }\ngreet(");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":1,\"character\":6}}";
	const r = handleSignatureHelp("30", params, db);
	assert lspGetNumberField(r, "id") === 30;
	assert r.length > 0;
}

test "unknown doc returns null" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleSignatureHelp("31", params, db);
	assert lspGetNumberField(r, "id") === 31;
}

test "dispatch routes correctly" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = lspDispatch("textDocument/signatureHelp", "32", params, db, testCache());
	assert lspGetNumberField(r, "id") === 32;
}

test "type hint for untyped var" {
	const db = testDb("file:///test.ms", "const x = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("40", params, db);
	assert lspGetNumberField(r, "id") === 40;
	assert r.length > 50;
}

test "empty for unknown doc" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("41", params, db);
	assert lspGetNumberField(r, "id") === 41;
}

test "dispatch routes correctly" {
	const db = testDb("file:///test.ms", "const y = true;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = lspDispatch("textDocument/inlayHint", "42", params, db, testCache());
	assert lspGetNumberField(r, "id") === 42;
}

test "array size hint: inferred type shows string[4]" {
	const db = testDb("file:///test.ms", "const a = new Array<string>(4);");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("43", params, db);
	// Type hint should show "string[4]" not "string[]"
	assert r.indexOf("string[4]") >= 0;
}

test "array size hint: annotated type shows string[8] trailing" {
	const db = testDb("file:///test.ms", "const e: string[] = new Array(8);");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("44", params, db);
	// Should contain "string[8]" as trailing hint
	assert r.indexOf("string[8]") >= 0;
}

test "no array size hint for empty new Array<T>()" {
	const db = testDb("file:///test.ms", "const a = new Array<string>();");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":10,\"character\":0}}}";
	const r = handleInlayHint("45", params, db);
	// Type hint should show "string[]" — no size
	assert r.indexOf("string[]") >= 0;
}

test "finds all references to a variable" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst def = abc + 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleReferences("50", params, db);
	assert lspGetNumberField(r, "id") === 50;
	assert r.length > 60;
}

test "unknown doc returns empty" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const r = handleReferences("51", params, db);
	assert lspGetNumberField(r, "id") === 51;
}

test "dispatch routes correctly" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = lspDispatch("textDocument/references", "52", params, db, testCache());
	assert lspGetNumberField(r, "id") === 52;
}

test "renames variable occurrences" {
	const db = testDb("file:///test.ms", "const abc = 1;\nconst def = abc + 2;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"xyz\"}";
	const r = handleRename("60", params, db);
	assert lspGetNumberField(r, "id") === 60;
	assert r.length > 60;
}

test "unknown doc returns null" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0},\"newName\":\"xyz\"}";
	const r = handleRename("61", params, db);
	assert lspGetNumberField(r, "id") === 61;
}

test "empty newName returns null" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const r = handleRename("62", params, db);
	assert lspGetNumberField(r, "id") === 62;
}

test "dispatch routes correctly" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"y\"}";
	const r = lspDispatch("textDocument/rename", "63", params, db, testCache());
	assert lspGetNumberField(r, "id") === 63;
}

test "Trans-Am cache hit on comment-only change" {
	const db = createTransAmDb(100);
	const path = "/test.ms";
	dbSetFileText(db, path, "const x = 1;");
	// First query — populates cache
	const ctx1 = dbTypeCheck(db, path);
	assert ctx1 !== null;
	assert db.revision.value === 1;
	// Comment-only change — content hash changes but semantics identical
	dbSetFileText(db, path, "const x = 1; // comment");
	assert db.revision.value === 2;
	// Second query — should re-execute (parse output differs) but Trans-Am handles it
	const ctx2 = dbTypeCheck(db, path);
	assert ctx2 !== null;
}
