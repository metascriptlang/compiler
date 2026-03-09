// LSP Handlers — Per-method dispatch, format JSON responses
//
// Each handler: extract params → query Trans-Am → call suggest.ms → format JSON.
// No I/O — returns JSON strings. server.ms handles stdin/stdout.

import { sliceStr, charAt } from "../../utils/string";
import {
	TransAmDb, createTransAmDb, dbSetFileText, dbParse, dbTypeCheck,
	getFileText, getFileId, getFilePath,
	recordModuleImport, clearImportsFor, getTransitiveDependents,
	dbGetFileCount, dbGetFilePathByIndex
} from "../transam/index";
import { detectCycle } from "../transam/moduleDeps";
import { readFile } from "std/process";
import {
	lspJsonString, lspJsonNumber, lspJsonBool, lspJsonNull,
	lspGetField, lspGetNumberField, lspGetObjectField,
	lspResponse, lspNotification, lspErrorResponse,
	lspUriToPath, lspPathToUri, lspResolveImport, lspFormatMessage
} from "./protocol";
import {
	lspFmtPosition, lspFmtRange, lspFmtLineRange,
	lspFmtLocation, lspFmtTextEdit,
	lspFmtCompletionItem, lspFmtHoverResult,
	lspFmtDiagnostic, lspFmtPublishDiagnostics,
	lspFmtDocumentSymbol, lspFmtInlayHint,
	lspFmtSignatureParam, lspFmtSignature, lspFmtSignatureHelp
} from "./format";
import {
	sgTypeToString, sgFindNodeAtPosition, sgGetSymbolAtCursor,
	sgFormatHover, sgCollectDiagnostics,
	sgDetectCompletionContext, sgGetPrefix, sgGetCompletionCandidates,
	sgCollectSymbolsInFile, sgFormatSignature, sgFormatExtensionSignatures, sgCountActiveParam, sgGetCalleeAtCursor, sgGetReceiverAtCursor,
	sgCollectInlayHints,
	sgCollectReferences, sgFindUsagesByName,
	sgFormatHoverDoc, sgExtractDocComment,
	sgFindImportSource, sgFindExportedDecl,
	SgSuggest, SgCompletionKind,
	SgSymbolRef,
	SgDocumentSymbol,
	SgSignatureInfo,
	SgInlayHint, SgInlayHintKind,
	SgDiagnostic,
	SgSemanticToken, sgCollectSemanticTokens, sgSortTokens
} from "../../checker/suggest";
import { CheckerContext, createContext } from "../../checker/context";
import { SymbolKind, lookupSymbol } from "../../checker/symbol";
import { Type, TypeKind, unknownType, getProperty, typeNameOf } from "../../checker/types";
import { Node, IdentifierData, MemberExprData, NodeKind, ProgramData, ImportDeclData, ExportDeclData, SourceLocation } from "../../ast/node";
import { defaultFormatOptions } from "../fmt/options";
import { printNode as printFormattedNode } from "../fmt/printer";
import { formatDoc } from "../fmt/layout";
import { registerCoreParsers } from "../../parser/statements/core";
import { parseSource } from "../../parser/statements/validation";


// ===== Completion Cache =====
// Caches last completion list per file for zero-lag character-by-character filtering.
// Shared with server.ms via LspServerState.

export interface CompletionCache {
	uri: string;           // file URI of last completion
	line: number;          // line of last completion (1-indexed, internal)
	prefix: string;        // prefix used for last completion
	items: string[];       // cached per-item JSON strings
}

export function createCompletionCache(): CompletionCache {
	return { uri: "", line: -1, prefix: "", items: [] };
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
		const source = readFile(filePath);
		if (source.length > 0) {
			dbSetFileText(db, filePath, source);
		}
	}
}

// ===== Format Violation Check =====

// Returns a single LSP diagnostic JSON string if the file is unformatted, empty string otherwise.
// Severity 4 = Hint (renders as faint underline / info squiggle in editors).
function checkFormatViolation(db: TransAmDb, path: string): string {
	const source = dbGetSource(db, path);
	if (source === "") return "";

	if (!_fmtParsersRegistered) {
		registerCoreParsers();
		_fmtParsersRegistered = true;
	}

	const parseResult = parseSource(source);
	if (!parseResult.ok) return "";

	const options = defaultFormatOptions();
	const doc = printFormattedNode(parseResult.value, options);
	const formatted = formatDoc(doc, options);

	if (formatted === source) return "";

	// Place diagnostic at line 0, col 0 with hint severity
	return lspFmtDiagnostic(0, 0, 1, 2, "File is not formatted. Run 'msc fmt' or use format document.", "metascript-fmt", 0);
}

// Extract filename from absolute path (for diagnostic messages)
function lspBasename(path: string): string {
	if (path === "") return "";
	let lastSlash = -1;
	for (let i = path.length - 1; i >= 0; i = i - 1) {
		if (path[i] === "/") { lastSlash = i; break; }
	}
	if (lastSlash >= 0) return path.slice(lastSlash + 1, path.length);
	return path;
}

// Find the 0-based column of `name` as a whole word on 0-based `targetLine`.
function lspFindNameCol(src: string, targetLine: number, name: string): number {
	// Navigate to target line
	let lineNum = 0;
	let lineStart = 0;
	let i = 0;
	while (i < src.length && lineNum < targetLine) {
		if (src[i] === "\n") {
			lineNum = lineNum + 1;
			lineStart = i + 1;
		}
		i = i + 1;
	}
	if (lineNum !== targetLine) return -1;
	// Scan line for word-boundary match
	let j = lineStart;
	while (j < src.length && src[j] !== "\n") {
		if (src.slice(j, j + name.length) === name) {
			const before = j === lineStart || !lspIsWordChar(src[j - 1]);
			const endIdx = j + name.length;
			const after = endIdx >= src.length || src[endIdx] === "\n" || !lspIsWordChar(src[endIdx]);
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
	while (i < src.length && lineNum < bodyStart) {
		if (src[i] === "\n") {
			lineNum = lineNum + 1;
			lineStart = i + 1;
		}
		i = i + 1;
	}
	// Scan lines looking for field declaration
	while (i < src.length) {
		// Check if this line contains fieldName as a word followed by : or ?:
		let j = lineStart;
		while (j < src.length && src[j] !== "\n") {
			if (src.slice(j, j + fieldName.length) === fieldName) {
				const before = j === lineStart || !lspIsWordChar(src[j - 1]);
				const endIdx = j + fieldName.length;
				const after = endIdx < src.length && !lspIsWordChar(src[endIdx]);
				if (before && after) {
					// Check for ':' or '?:' after the field name (skip whitespace)
					let k = endIdx;
					while (k < src.length && (src[k] === " " || src[k] === "\t")) {
						k = k + 1;
					}
					if (k < src.length && (src[k] === ":" || src[k] === "?")) {
						return { line: lineNum, column: j - lineStart } as SourceLocation;
					}
				}
			}
			j = j + 1;
		}
		// Hit closing brace — stop searching
		let b = lineStart;
		while (b < src.length && b <= j) {
			if (src[b] === "}") return { line: -1, column: -1 } as SourceLocation;
			b = b + 1;
		}
		// Advance to next line
		i = j + 1;
		lineNum = lineNum + 1;
		lineStart = i;
	}
	return { line: -1, column: -1 } as SourceLocation;
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
			diagArray = diagArray + lspFmtDiagnostic(
				line, d.column, d.column + 1, d.severity, d.message, "metascript", 0
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
				const circTarget = lspResolveImport(path, circImp.importSource);
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

	// Format violation diagnostic — warning severity (2)
	const fmtDiag = checkFormatViolation(db, path);
	if (fmtDiag !== "") {
		if (diagCount > 0) diagArray = diagArray + ",";
		diagArray = diagArray + fmtDiag;
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
	for (let i = 0; i < data.programStmts.length; i = i + 1) {
		let stmt = data.programStmts[i];
		// Unwrap ExportDecl (re-exports)
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind === NodeKind.ImportDecl) {
			const imp = stmt.data as ImportDeclData;
			const targetPath = lspResolveImport(path, imp.importSource);
			if (targetPath === "") continue;
			lspEnsureFileLoaded(db, targetPath);
			const targetId = getFileId(db.fileInput, targetPath);
			if (targetId >= 0) {
				recordModuleImport(db.moduleDeps, fileId, targetId);
			}
		}
	}
}

// ===== Transitive Diagnostics =====

// Build wire-formatted diagnostics notifications for all files that
// transitively depend on the changed file. Concatenated Content-Length messages.
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
		+ ",\"completionProvider\":{\"triggerCharacters\":[\".\"]}"
		+ ",\"definitionProvider\":true"
		+ ",\"documentSymbolProvider\":true"
		+ ",\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}"
		+ ",\"inlayHintProvider\":true"
		+ ",\"referencesProvider\":true"
		+ ",\"renameProvider\":true"
		+ ",\"documentFormattingProvider\":true"
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
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const text = lspGetField(textDoc, "text");
	const path = lspUriToPath(uri);
	dbSetFileText(db, path, text);
	// Record import edges for dependency tracking
	const program = dbParse(db, path);
	recordImportsForFile(db, path, program);
	const diagParams = buildDiagnosticsJson(uri, db, path);
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
	// Record import edges for dependency tracking
	const program = dbParse(db, path);
	recordImportsForFile(db, path, program);
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

	const suggest = sgGetSymbolAtCursor(ctx, program, pos.line, pos.col1);
	if (suggest === null) return lspResponse(id, "null");

	const hoverText = sgFormatHover(suggest);
	const source = dbGetSource(db, path);
	const docComment = sgExtractDocComment(source, suggest.location.line);
	const hoverDoc = sgFormatHoverDoc(suggest, docComment);
	return lspResponse(id, lspFmtHoverResult(hoverText, hoverDoc));
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

export function handleCompletion(id: string, params: string, db: TransAmDb, cache: CompletionCache): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);
	const source = dbGetSource(db, path);
	if (source === "") return lspResponse(id, "[]");

	const prefix = sgGetPrefix(source, pos.line, pos.col);

	// Cache hit: same file, same line, prefix extends previous — filter instantly
	if (cache.uri === pos.uri && cache.line === pos.line && prefix.length >= cache.prefix.length && prefix.startsWith(cache.prefix)) {
		const filtered = filterCompletionItems(cache.items, prefix);
		cache.prefix = prefix;
		cache.items = filtered;
		return lspResponse(id, joinJsonItems(filtered));
	}

	const kind = sgDetectCompletionContext(source, pos.line, pos.col);

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "[]");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

	// For MemberAccess, try to resolve receiver type
	let receiverType = null;
	if (kind === SgCompletionKind.MemberAccess) {
		const dotCol = pos.col - prefix.length - 1;
		if (dotCol >= 0) {
			const node = sgFindNodeAtPosition(program, pos.line, dotCol);
			if (node !== null) {
				const suggest = sgGetSymbolAtCursor(ctx, program, pos.line, dotCol);
				if (suggest !== null) {
					receiverType = suggest.symType;
				}
			}
		}
	}

	const candidates = sgGetCompletionCandidates(ctx, kind, prefix, receiverType);

	// Cache the individual formatted items for future prefix filtering
	const cachedItems = formatCompletionItemsArray(candidates);
	cache.uri = pos.uri;
	cache.line = pos.line;
	cache.prefix = prefix;
	cache.items = cachedItems;

	return lspResponse(id, joinJsonItems(cachedItems));
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
function formatCompletionItemsArray(candidates: SgSuggest[]): string[] {
	const result: string[] = [];
	for (let i = 0; i < candidates.length; i = i + 1) {
		const item = candidates[i];
		const typeStr = sgTypeToString(item.symType);
		const kindNum = lspCompletionItemKind(item.kind, item.isMutable);
		const sortText = lspCompletionSortText(item);
		const commitChars = lspCommitCharsForKind(item.kind);
		result.push(lspFmtCompletionItem(item.name, kindNum, typeStr, sortText, false, commitChars));
	}
	return result;
}

// Join pre-formatted JSON items into a JSON array string.
function joinJsonItems(items: string[]): string {
	let result = "[";
	for (let i = 0; i < items.length; i = i + 1) {
		if (i > 0) result = result + ",";
		result = result + items[i];
	}
	result = result + "]";
	return result;
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
	if (program === null) return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "null");

	const suggest = sgGetSymbolAtCursor(ctx, program, pos.line, pos.col1);
	if (suggest !== null) {
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
			if (suggest.kind === SymbolKind.Property) {
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
		const location = lspFmtLocation(defUri, defLine, defCol, defLine, defCol + suggest.name.length);
		return lspResponse(id, "[" + location + "]");
	}

	// Cross-module fallback: check if cursor is on an imported name
	const node = sgFindNodeAtPosition(program, pos.line, pos.col1);
	if (node === null) return lspResponse(id, "null");
	if (node.kind !== NodeKind.Identifier) return lspResponse(id, "null");

	const identData = node.data as IdentifierData;
	const identName = identData.name;
	const importSpec = sgFindImportSource(program, identName);
	if (importSpec === "") return lspResponse(id, "null");

	const targetPath = lspResolveImport(path, importSpec);
	if (targetPath === "") return lspResponse(id, "null");

	lspEnsureFileLoaded(db, targetPath);

	const targetProgram = dbParse(db, targetPath);
	if (targetProgram === null) return lspResponse(id, "null");

	const declLoc = sgFindExportedDecl(targetProgram, identName);
	if (declLoc.line === 0) return lspResponse(id, "null");

	const targetUri = lspPathToUri(targetPath);
	const tLine = declLoc.line - 1;
	let tCol = declLoc.column;
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

export function handleDocumentSymbol(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "[]");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

	const symbols = sgCollectSymbolsInFile(ctx, program);

	let items = "[";
	for (let i = 0; i < symbols.length; i = i + 1) {
		if (i > 0) items = items + ",";
		const sym = symbols[i];
		const kindNum = lspDocumentSymbolKind(sym.kind, sym.isMutable);
		const symLine = sym.location.line - 1;
		const symCol = sym.location.column;
		const endCol = symCol + sym.name.length;
		items = items + lspFmtDocumentSymbol(sym.name, kindNum, sym.detail, symLine, symCol, endCol);
	}
	items = items + "]";
	return lspResponse(id, items);
}

// ===== Signature Help =====

export function handleSignatureHelp(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);
	const source = dbGetSource(db, path);
	if (source === "") return lspResponse(id, "null");

	const calleeName = sgGetCalleeAtCursor(source, pos.line, pos.col);
	if (calleeName === "") return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "null");

	// For member calls (receiver.method()), try extension-based signatures first
	let sigs: SgSignatureInfo[] = [];
	const receiverName = sgGetReceiverAtCursor(source, pos.line, pos.col);
	if (receiverName !== "") {
		const recSym = lookupSymbol(ctx.table, receiverName);
		if (recSym !== null && recSym.symbolType !== null) {
			sigs = sgFormatExtensionSignatures(ctx, calleeName, recSym.symbolType);
		}
	}
	// Fallback: standard symbol lookup (direct calls + non-extension methods)
	if (sigs.length === 0) {
		const sym = lookupSymbol(ctx.table, calleeName);
		if (sym === null) return lspResponse(id, "null");
		sigs = sgFormatSignature(sym);
	}
	if (sigs.length === 0) return lspResponse(id, "null");

	const activeParam = sgCountActiveParam(source, pos.line, pos.col);

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

	return lspResponse(id, lspFmtSignatureHelp(sigArray, 0, activeParam));
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

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "[]");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

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
		arr = arr + lspFmtInlayHint(h.line - 1, h.col, h.label, lspKind, padLeft, padRight);
	}
	arr = arr + "]";
	return lspResponse(id, arr);
}

// ===== References =====

export function handleReferences(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "[]");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "[]");

	const suggest = sgGetSymbolAtCursor(ctx, program, pos.line, pos.col1);
	if (suggest === null) return lspResponse(id, "[]");

	let arr = "[";
	let count = 0;

	// Search current file
	const allRefs = sgCollectReferences(program);
	const refs = sgFindUsagesByName(allRefs, suggest.name);
	for (let i = 0; i < refs.length; i = i + 1) {
		if (count > 0) arr = arr + ",";
		const ref = refs[i];
		const refLine = ref.line - 1;
		arr = arr + lspFmtLocation(pos.uri, refLine, ref.col, refLine, ref.col + ref.nameLen);
		count = count + 1;
	}

	// Search all other open files in the workspace
	const fileCount = dbGetFileCount(db);
	let fi = 0;
	while (fi < fileCount) {
		const otherPath = dbGetFilePathByIndex(db, fi);
		fi = fi + 1;
		if (otherPath === path) continue;
		const otherProgram = dbParse(db, otherPath);
		if (otherProgram === null) continue;
		const otherUri = lspPathToUri(otherPath);
		const otherRefs = sgCollectReferences(otherProgram);
		const matched = sgFindUsagesByName(otherRefs, suggest.name);
		let mi = 0;
		while (mi < matched.length) {
			if (count > 0) arr = arr + ",";
			const mr = matched[mi];
			const mrLine = mr.line - 1;
			arr = arr + lspFmtLocation(otherUri, mrLine, mr.col, mrLine, mr.col + mr.nameLen);
			count = count + 1;
			mi = mi + 1;
		}
	}

	arr = arr + "]";
	return lspResponse(id, arr);
}

// ===== Rename =====

// Build TextEdit array for refs in a single file
function buildFileEdits(program: Node, name: string, newName: string): string {
	const allRefs = sgCollectReferences(program);
	const refs = sgFindUsagesByName(allRefs, name);
	if (refs.length === 0) return "";
	let edits = "[";
	let i = 0;
	while (i < refs.length) {
		if (i > 0) edits = edits + ",";
		const ref = refs[i];
		const refLine = ref.line - 1;
		edits = edits + lspFmtTextEdit(refLine, ref.col, ref.col + ref.nameLen, newName);
		i = i + 1;
	}
	edits = edits + "]";
	return edits;
}

export function handleRename(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params);
	const path = lspUriToPath(pos.uri);

	const newName = lspGetField(params, "newName");
	if (newName === "") return lspResponse(id, "null");

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "null");

	const suggest = sgGetSymbolAtCursor(ctx, program, pos.line, pos.col1);
	if (suggest === null) return lspResponse(id, "null");

	// Collect edits across all files
	let changes = "";
	let changeCount = 0;

	// Current file
	const curEdits = buildFileEdits(program, suggest.name, newName);
	if (curEdits.length > 0) {
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
		const otherProgram = dbParse(db, otherPath);
		if (otherProgram === null) continue;
		const otherEdits = buildFileEdits(otherProgram, suggest.name, newName);
		if (otherEdits.length > 0) {
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

export function handleFormatting(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);
	const source = dbGetSource(db, path);
	if (source === "") return lspResponse(id, "[]");

	if (!_fmtParsersRegistered) {
		registerCoreParsers();
		_fmtParsersRegistered = true;
	}

	const parseResult = parseSource(source);
	if (!parseResult.ok) return lspResponse(id, "[]");

	const options = defaultFormatOptions();
	const doc = printFormattedNode(parseResult.value, options);
	const formatted = formatDoc(doc, options);

	if (formatted === source) return lspResponse(id, "[]");

	// Single TextEdit replacing entire document
	let lineCount = 0;
	for (let i = 0; i < source.length; i = i + 1) {
		if (source[i] === "\n") lineCount = lineCount + 1;
	}
	let lastLineLen = 0;
	let lastNl = -1;
	for (let j = source.length - 1; j >= 0; j = j - 1) {
		if (source[j] === "\n") { lastNl = j; break; }
	}
	lastLineLen = source.length - lastNl - 1;
	const range = lspFmtRange(0, 0, lineCount, lastLineLen);
	const edit = "{\"range\":" + range + ",\"newText\":" + lspJsonString(formatted) + "}";
	return lspResponse(id, "[" + edit + "]");
}

// ===== Dispatch =====

export function lspDispatch(method: string, id: string, params: string, db: TransAmDb, cache: CompletionCache): string {
	if (method === "initialize") return handleInitialize(id);
	if (method === "shutdown") return handleShutdown(id);
	if (method === "textDocument/didOpen") return handleDidOpen(params, db);
	if (method === "textDocument/didChange") return handleDidChange(params, db);
	if (method === "textDocument/didClose") return handleDidClose(params, db);
	if (method === "textDocument/hover") return handleHover(id, params, db);
	if (method === "textDocument/completion") return handleCompletion(id, params, db, cache);
	if (method === "textDocument/definition") return handleDefinition(id, params, db);
	if (method === "textDocument/documentSymbol") return handleDocumentSymbol(id, params, db);
	if (method === "textDocument/signatureHelp") return handleSignatureHelp(id, params, db);
	if (method === "textDocument/inlayHint") return handleInlayHint(id, params, db);
	if (method === "textDocument/references") return handleReferences(id, params, db);
	if (method === "textDocument/rename") return handleRename(id, params, db);
	if (method === "textDocument/semanticTokens/full") return handleSemanticTokensFull(id, params, db);
	if (method === "textDocument/formatting") return handleFormatting(id, params, db);
	if (id.length > 0) return lspErrorResponse(id, -32601, "Method not found");
	return "";
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
	assert r.length > 0;
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
