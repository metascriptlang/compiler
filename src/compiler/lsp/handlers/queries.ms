// LSP Query Handlers — Hover, Document Symbol, Signature Help, Inlay Hints,
//                      References, Document Highlight, Rename.
// All query symbol state without modifying it. Semantic tokens in semanticTokens.ms.

import {
	TransAmDb, dbParse, dbTypeCheck, dbGetCheckedProgram,
	getFileId, getFilePath, getTransitiveDependents, dbGetFileCount, dbGetFilePathByIndex
} from "../../transam/index";
import {
	lspJsonString, lspGetField, lspGetNumberField, lspGetObjectField,
	lspUriToPath, lspPathToUri, lspResponse
} from "../protocol";
import {
	lspFmtLocation, lspFmtTextEdit,
	lspFmtHoverResult, lspFmtDocumentSymbol, lspFmtDocumentHighlight, lspFmtInlayHint,
	lspFmtSignatureParam, lspFmtSignature, lspFmtSignatureHelp,
} from "../format";
import {
	sgFormatHover, sgCollectSymbolsInFile, sgFormatSignature, sgFormatExtensionSignatures,
	sgGetSignatureContext, sgPickActiveOverload, sgCollectInlayHints,
	sgFormatHoverDoc, sgExtractDocComment, sgBuiltinDoc,
	sgQueryAtPosition, sgQuerySourceAt, sgQueryBySym, sgQueryByName, sgQueryByDefiningModule,
	sgFindCallExprByCalleeLocation, sgFieldDeclLine, FIELD_NO_CONTAINER,
	SgDocumentSymbol,
	SgSignatureInfo,
	SgSymbolRef,
	SgInlayHintKind,
} from "../../../checker/suggest";
import { CheckerContext } from "../../../checker/context";
import { lookupSymbol } from "../../../checker/symbol";
import { Symbol, SymbolKind, CallExprData, TypeKind } from "../../../ast/node";
import {
	lspExtractPosition, lspDocumentUri, dbGetSource, lspEnsureFileLoaded,
} from "./shared";
import { LineIndex } from "../../../utils/sourceLines";
import { lspCharacterIn } from "../position";

// ===== Hover =====

export function handleHover(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params, db);
	const path = lspUriToPath(pos.uri);

	const program = dbParse(db, path);
	if (program == null) return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "null");

	const suggest = sgQuerySourceAt(ctx, dbGetSource(db, path), pos.line, pos.col1);
	if (suggest == null) return lspResponse(id, "null");

	// Overload-aware hover: the symRecord stores the PRIMARY sym (so
	// find-references, goto-def, rename see all call sites as references
	// to a single declaration). For HOVER on an overloaded function call,
	// we want the RESOLVED overload's signature instead — matches the
	// reference's behavior. The truth lives on the CallExpr's
	// `resolvedOverloadIdx` field, set by resolveOverloadCall at check time.
	//
	// Query the AST for a CallExpr whose callee is this exact Identifier
	// position. If found, substitute the winning overload's type into
	// `suggest.symType` before formatting. Non-overloaded calls and
	// Identifier-as-value references fall through unchanged.
	if (suggest.kind == SymbolKind.Function && suggest.sym != null
			&& suggest.sym.overloads != null && suggest.sym.overloads.length > 0) {
		// Use the checked program (AST with resolvedOverloadIdx populated).
		// Fall back to the raw parse tree if the checked version is missing.
		let checkedProgram = dbGetCheckedProgram(db, path);
		if (checkedProgram == null) checkedProgram = program;
		const callExpr = sgFindCallExprByCalleeLocation(checkedProgram, pos.line, pos.col1);
		if (callExpr != null) {
			const cd = callExpr.data as CallExprData;
			const idx = cd.resolvedOverloadIdx;
			if (idx > 0 && idx - 1 < suggest.sym.overloads.length) {
				const winnerSym = suggest.sym.overloads[idx - 1];
				if (winnerSym != null && winnerSym.symbolType != null
						&& winnerSym.symbolType.kind == TypeKind.Function) {
					suggest.symType = winnerSym.symbolType;
				}
			}
		}
	}

	const hoverText = sgFormatHover(suggest);
	// Extract doc comment from the symbol's source file (may differ for cross-file symbols)
	let source = "";
	const modPath = suggest.modulePath;
	if (modPath != null && modPath != "" && modPath != path) {
		lspEnsureFileLoaded(db, modPath);
		source = dbGetSource(db, modPath);
	} else {
		source = dbGetSource(db, path);
	}
	let docLine = suggest.location.line;
	if (suggest.kind == SymbolKind.Property && suggest.sym != null && suggest.sym.location != null && suggest.sym.location.line > 0) {
		const declared = modPath != null && modPath != "" && modPath != path ? dbParse(db, modPath) : program;
		if (declared != null) {
			const fieldLine = sgFieldDeclLine(declared, suggest.sym.location, suggest.name);
			if (fieldLine != FIELD_NO_CONTAINER) docLine = fieldLine;
		}
	}
	let docComment = sgExtractDocComment(source, docLine);
	// Fallback to built-in docs for well-known symbols (MDN-style)
	if (docComment == "") {
		docComment = sgBuiltinDoc(suggest.name, suggest.containerName);
	}
	const hoverDoc = sgFormatHoverDoc(suggest, docComment);
	// Hover range: highlight the hovered token (0-based line/col for LSP)
	const fileSource = dbGetSource(db, path);
	const hoverLine = pos.line - 1;
	const lines = LineIndex.build(fileSource);
	const hoverCol = lspCharacterIn(lines, fileSource, pos.line, pos.col1);
	const hoverEndCol = lspCharacterIn(lines, fileSource, pos.line, pos.col1 + suggest.name.byteLength);
	return lspResponse(id, lspFmtHoverResult(hoverText, hoverDoc, hoverLine, hoverCol, hoverEndCol));
}

// ===== Document Symbol =====

function lspDocumentSymbolKind(kind: SymbolKind, isMutable: boolean): int32 {
	return match (kind) {
		SymbolKind.Variable when isMutable => 13,
		SymbolKind.Variable => 14,
		SymbolKind.Function => 12,
		SymbolKind.Class => 5,
		SymbolKind.Actor => 5,
		SymbolKind.Interface => 11,
		SymbolKind.Enum => 10,
		SymbolKind.TypeAlias => 26,  // TypeParameter (was 25=Operator, wrong)
		SymbolKind.Method => 6,
		SymbolKind.Property => 7,
		SymbolKind.Struct => 23,
		SymbolKind.Macro => 12,
		_ => 13,
	};
}

function formatDocumentSymbolArray(symbols: SgDocumentSymbol[]): string {
	const items: string[] = [];
	for (const sym of symbols) {
		const kindNum = lspDocumentSymbolKind(sym.kind, sym.isMutable);
		const symLine = sym.location.line - 1;
		const symCol = sym.location.column;
		const endCol = symCol + sym.name.byteLength;
		let childrenJson = "";
		if (sym.children.length > 0) {
			childrenJson = formatDocumentSymbolArray(sym.children);
		}
		items.push(lspFmtDocumentSymbol(sym.name, kindNum, sym.detail, symLine, symCol, endCol, childrenJson));
	}
	return "[" + items.join(",") + "]";
}

export function handleDocumentSymbol(id: string, params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
	const path = lspUriToPath(uri);

	const program = dbParse(db, path);
	if (program == null) return lspResponse(id, "[]");

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "[]");

	const symbols = sgCollectSymbolsInFile(ctx, program);
	return lspResponse(id, formatDocumentSymbolArray(symbols));
}

// ===== Signature Help =====

export function handleSignatureHelp(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params, db);
	const path = lspUriToPath(pos.uri);
	const source = dbGetSource(db, path);
	if (source == "") return lspResponse(id, "null");

	// Run type check first so nodeType is populated — sgPickActiveOverload
	// reads arg.nodeType to score candidates. Using dbParse (raw tree) would
	// give null nodeTypes and the scoring would always pick the primary.
	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "null");

	// AST-based signature context (with text-based fallback for incomplete source)
	// Prefer the CHECKED program (has nodeType set on arguments) over the raw
	// parse tree — overload scoring needs the argument types.
	let program = dbGetCheckedProgram(db, path);
	if (program == null) program = dbParse(db, path);
	const sigCtx = sgGetSignatureContext(program, source, pos.line, pos.col);
	if (sigCtx.calleeName == "") return lspResponse(id, "null");

	// For member calls (receiver.method()), try extension-based signatures first
	let sigs: SgSignatureInfo[] = [];
	let activeSignature = 0;
	if (sigCtx.receiverName != "") {
		const recSym = lookupSymbol(ctx.table, sigCtx.receiverName);
		if (recSym != null && recSym.symbolType != null) {
			sigs = sgFormatExtensionSignatures(ctx, sigCtx.calleeName, recSym.symbolType, recSym);
		}
	}
	// Fallback: standard symbol lookup (direct calls + non-extension methods)
	if (sigs.length == 0) {
		const sym = lookupSymbol(ctx.table, sigCtx.calleeName);
		if (sym == null) return lspResponse(id, "null");
		sigs = sgFormatSignature(sym);
		// Overload narrowing: pick the signature whose param types best match
		// the already-typed arguments at the cursor position. Without this,
		// the LSP always highlights the primary (first) overload, so typing
		// `createNodeAt(NodeKind.StringLiteral, ...)` shows the NumberLiteral
		// signature hint — misleading for macro authors.
		activeSignature = sgPickActiveOverload(sigCtx.callNode, sym);
	}
	if (sigs.length == 0) return lspResponse(id, "null");

	const sigItems: string[] = [];
	for (const sig of sigs) {
		const params: string[] = [];
		for (const label of sig.paramLabels) {
			params.push(lspFmtSignatureParam(label));
		}
		sigItems.push(lspFmtSignature(sig.label, "[" + params.join(",") + "]"));
	}

	return lspResponse(id, lspFmtSignatureHelp("[" + sigItems.join(",") + "]", activeSignature, sigCtx.activeParam));
}

// ===== Inlay Hints =====

export function handleInlayHint(id: string, params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
	const path = lspUriToPath(uri);

	const range = lspGetObjectField(params, "range");
	const rangeStart = lspGetObjectField(range, "start");
	const rangeEnd = lspGetObjectField(range, "end");
	const startLine = (lspGetNumberField(rangeStart, "line") as int32) + 1;
	const endLine = (lspGetNumberField(rangeEnd, "line") as int32) + 1;

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "[]");

	// Use checked program (has resolvedSym/nodeType on AST nodes).
	// Raw dbParse tree lacks resolved info — scope lookups find wrong symbols.
	const program = dbGetCheckedProgram(db, path);
	if (program == null) return lspResponse(id, "[]");

	const hintsList = sgCollectInlayHints(ctx, program, startLine, endLine);
	const source = dbGetSource(db, path);

	if (hintsList.length == 0) return lspResponse(id, "[]");

	const hints: string[] = [];
	const lines = LineIndex.build(source);
	for (const h of hintsList) {
		// LSP InlayHintKind: 1 = Type, 2 = Parameter
		// Exception hints map to Type kind (1) with paddingLeft
		let lspKind = 2;
		if (h.hintKind == SgInlayHintKind.Type || h.hintKind == SgInlayHintKind.Exception) {
			lspKind = 1;
		}
		// Type hints (`: T`) sit right after an identifier whose source already
		// has a separator (space, `=`, `;`) following it — no extra padding.
		// Exception hints (`throws E`) need a leading space to separate from
		// the preceding identifier or `try` keyword.
		// Parameter hints (`name:`) need a trailing space to separate from the
		// following argument expression.
		const padLeft = h.hintKind == SgInlayHintKind.Exception;
		const padRight = h.hintKind == SgInlayHintKind.Parameter;
		hints.push(lspFmtInlayHint(h.line - 1, lspCharacterIn(lines, source, h.line, h.col), h.label, lspKind, padLeft, padRight));
	}
	return lspResponse(id, "[" + hints.join(",") + "]");
}

// ===== References =====

function lspRefEnd(ref: SgSymbolRef): int32 {
	return ref.col + (ref.nameLen as int32);
}

// Reference positions are unique per file; line and column pack into one key without collisions.
function lspRefKey(ref: SgSymbolRef): int64 {
	return ((ref.line as int64) << 32) | (ref.col as int64);
}

function pushUniqueLocations(items: string[], uri: string, source: string, refs: SgSymbolRef[]): void {
	const seen: HashSet<int64> = new HashSet<int64>();
	const lines = LineIndex.build(source);
	for (const ref of refs) {
		const key = lspRefKey(ref);
		if (seen.has(key)) continue;
		seen.add(key);
		items.push(lspFmtLocation(
			uri, ref.line - 1, lspCharacterIn(lines, source, ref.line, ref.col),
			ref.line - 1, lspCharacterIn(lines, source, ref.line, lspRefEnd(ref)),
		));
	}
}

export function handleReferences(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params, db);
	const path = lspUriToPath(pos.uri);

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "[]");

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest == null) return lspResponse(id, "[]");

	const items: string[] = [];

	// Search current file via symbol identity (no false positives from shadowing)
	pushUniqueLocations(items, pos.uri, dbGetSource(db, path), sgQueryBySym(ctx, suggest.sym));

	// Search transitive dependents only (files that could import this symbol)
	const defModule = suggest.modulePath != null && suggest.modulePath != "" ? suggest.modulePath : path;
	const targetFileId = getFileId(db.fileInput, path);
	let depIds: int32[] = [];
	if (targetFileId >= 0) {
		depIds = getTransitiveDependents(db.moduleDeps, targetFileId);
	}
	for (const depId of depIds) {
		const otherPath = getFilePath(db.fileInput, depId);
		if (otherPath == "" || otherPath == path) continue;
		const otherCtx = dbTypeCheck(db, otherPath);
		if (otherCtx == null) continue;
		pushUniqueLocations(
			items, lspPathToUri(otherPath), dbGetSource(db, otherPath),
			sgQueryByDefiningModule(otherCtx, suggest.name, defModule),
		);
	}

	return lspResponse(id, "[" + items.join(",") + "]");
}

// ===== Document Highlight =====

export function handleDocumentHighlight(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params, db);
	const path = lspUriToPath(pos.uri);

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "[]");

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest == null) return lspResponse(id, "[]");

	const source = dbGetSource(db, path);
	const refs = sgQueryBySym(ctx, suggest.sym);
	const highlights: string[] = [];
	const lines = LineIndex.build(source);
	for (const ref of refs) {
		highlights.push(lspFmtDocumentHighlight(
			ref.line - 1, lspCharacterIn(lines, source, ref.line, ref.col),
			lspCharacterIn(lines, source, ref.line, lspRefEnd(ref)), 1,
		));
	}
	return lspResponse(id, "[" + highlights.join(",") + "]");
}

// ===== Rename =====

function buildTextEdits(refs: SgSymbolRef[], newName: string, source: string): string {
	if (refs.length == 0) return "";
	const edits: string[] = [];
	const lines = LineIndex.build(source);
	for (const ref of refs) {
		edits.push(lspFmtTextEdit(
			ref.line - 1, lspCharacterIn(lines, source, ref.line, ref.col),
			lspCharacterIn(lines, source, ref.line, lspRefEnd(ref)), newName,
		));
	}
	return "[" + edits.join(",") + "]";
}

// Build TextEdit array for refs in a single file (sym identity for current file)
function buildFileEditsBySym(ctx: CheckerContext, sym: Symbol | null, newName: string, source: string): string {
	return buildTextEdits(sgQueryBySym(ctx, sym), newName, source);
}

// Build TextEdit array for refs in a cross-module file (name + modulePath fallback)
function buildFileEdits(ctx: CheckerContext, name: string, modulePath: string, newName: string, source: string): string {
	return buildTextEdits(sgQueryByName(ctx, name, modulePath), newName, source);
}

export function handleRename(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params, db);
	const path = lspUriToPath(pos.uri);

	const newName = lspGetField(params, "newName");
	if (newName == "") return lspResponse(id, "null");

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "null");

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest == null) return lspResponse(id, "null");

	// Collect edits across all files
	const changes: string[] = [];

	// Current file — use sym identity
	const curEdits = buildFileEditsBySym(ctx, suggest.sym, newName, dbGetSource(db, path));
	if (curEdits.byteLength > 0) {
		changes.push(lspJsonString(pos.uri) + ":" + curEdits);
	}

	// Other open files in workspace
	const fileCount = dbGetFileCount(db);
	for (let fi: int32 = 0; fi < fileCount; fi++) {
		const otherPath = dbGetFilePathByIndex(db, fi);
		if (otherPath == path) continue;
		const otherCtx = dbTypeCheck(db, otherPath);
		if (otherCtx == null) continue;
		const otherEdits = buildFileEdits(otherCtx, suggest.name, suggest.modulePath, newName, dbGetSource(db, otherPath));
		if (otherEdits.byteLength > 0) {
			changes.push(lspJsonString(lspPathToUri(otherPath)) + ":" + otherEdits);
		}
	}

	if (changes.length == 0) return lspResponse(id, "null");

	return lspResponse(id, "{\"changes\":{" + changes.join(",") + "}}");
}

