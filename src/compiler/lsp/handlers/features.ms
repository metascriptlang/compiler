// LSP Handlers — Hover, Document Symbol, Signature Help, Inlay Hints,
//                 References, Document Highlight, Rename, Semantic Tokens.

import {
	TransAmDb, dbParse, dbTypeCheck, dbGetCheckedProgram,
	getFileId, getFilePath, getTransitiveDependents, dbGetFileCount, dbGetFilePathByIndex
} from "../../transam/index";
import {
	lspJsonString, lspJsonNumber, lspGetField, lspGetNumberField, lspGetObjectField,
	lspUriToPath, lspPathToUri, lspResponse
} from "../protocol";
import {
	lspFmtLocation, lspFmtTextEdit,
	lspFmtHoverResult, lspFmtDocumentSymbol, lspFmtDocumentHighlight, lspFmtInlayHint,
	lspFmtSignatureParam, lspFmtSignature, lspFmtSignatureHelp,
} from "../format";
import {
	sgFormatHover, sgCollectSymbolsInFile, sgFormatSignature, sgFormatExtensionSignatures,
	sgGetSignatureContext, sgCollectInlayHints,
	sgFormatHoverDoc, sgExtractDocComment, sgBuiltinDoc,
	sgQueryAtPosition, sgQueryBySym, sgQueryByName, sgQueryByDefiningModule,
	SgDocumentSymbol,
	SgSignatureInfo,
	SgInlayHintKind,
	SgSemanticToken, sgCollectSemanticTokens, sgSortTokens
} from "../../../checker/suggest";
import { CheckerContext } from "../../../checker/context";
import { lookupSymbol } from "../../../checker/symbol";
import { Symbol, SymbolKind } from "../../../ast/node";
import { lspExtractPosition, dbGetSource, lspEnsureFileLoaded } from "./shared";

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

// ===== Document Symbol =====

function lspDocumentSymbolKind(kind: SymbolKind, isMutable: boolean): number {
	// Const variables -> Constant (14), let/var -> Variable (13)
	if (kind === SymbolKind.Variable) {
		if (isMutable) return 13;
		return 14;
	}
	return match (kind) {
		SymbolKind.Function => 12,
		SymbolKind.Class => 5,
		SymbolKind.Actor => 5,
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
