// LSP Handlers — Completion, completion resolve, import path/name completion.

import { TransAmDb, createTransAmDb, dbSetFileText, dbParse, dbTypeCheck, dbEnsureModuleExports, dbResolveImport, dbSetStdPath } from "../../transam/index";
import { resolveRuntimeDir } from "../../../utils/path";
import { readDir } from "std/fs";
import {
	lspJsonString,
	lspGetField,
	lspUriToPath, dirname,
	lspResponse
} from "../protocol";
import {
	lspFmtCompletionItem, lspFmtMultiLineTextEdit,
} from "../format";
import {
	sgTypeToString, sgDetectCompletionContext, sgGetPrefix, sgGetCompletionCandidates,
	sgExtractDocComment, sgBuiltinDoc,
	sgFindImportBySource, sgExtractImportPath, sgExtractImportSource, sgExtractExistingImportNames,
	sgComputeImportEdit, sgQueryAtPosition, sgQueryContextualTypeAt, sgObjectFieldPathAST, sgCompleteObjectFields,
	findEnclosingObjectLiteral, findNodeAtPosition,
	sgGetLineOffset,
	SgSuggest, SgCompletionKind
} from "../../../checker/suggest";
import { CheckerContext, findModuleExports } from "../../../checker/context";
import { handleDidOpen, handleDidChange } from "./lifecycle";
import { SymbolFlag, hasFlag } from "../../../checker/symbol";
import { createTypeRef } from "../../../checker/types";
import { Node, MemberExprData, ObjectLiteralData, VariableDeclData, NodeKind, Type, SymbolKind } from "../../../ast/node";
import { forEachChild } from "../../../ast/visitor";
import { isMsModuleExtension, stripMsModuleExtension } from "../../../module/resolver";
import {
	dbGetSource, lspExtractPosition, lspEnsureFileLoaded,
	cacheResolveEdit, lookupResolveEdit,
	CompletionCache, createCompletionCache, LspCursorParams
} from "./shared";


// Pre-built completion items: per-file cache (Map with capacity 10).
// Prevents cache thrashing when jumping between open files.
let _prebuiltCache: HashMap<string, string[]> = new HashMap<string, string[]>();
const PREBUILT_CAPACITY = 10;

const STMT_KEYWORDS: string[] = ["actor", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue", "converter", "default", "defer", "do", "else", "enum", "export", "extern", "false", "finally", "for", "function", "if", "import", "interface", "let", "macro", "match", "move", "new", "null", "quote", "return", "sizeof", "static", "struct", "super", "switch", "template", "test", "this", "throw", "true", "try", "type", "typeof", "undefined", "unreachable", "var", "when", "while"];
const TYPE_KEYWORDS: string[] = ["char", "cstring", "distinct", "double", "float", "float32", "float64", "int", "int16", "int32", "int64", "int8", "keyof", "never", "ref", "typeof", "uint16", "uint32", "uint64", "uint8", "unknown", "void"];
const KEYWORD_COMPLETION_KIND = 14;

function lspKeywordItems(kind: SgCompletionKind, prefix: string): string[] {
	const words = kind === SgCompletionKind.TypeAnnotation ? TYPE_KEYWORDS : STMT_KEYWORDS;
	const result: string[] = [];
	for (const w of words) {
		if (prefix.length > 0 && !w.startsWith(prefix)) continue;
		result.push(lspFmtCompletionItem(w, KEYWORD_COMPLETION_KIND, "keyword", "16", false, "", "", ""));
	}
	return result;
}

export function prebuildCompletionCache(db: TransAmDb, path: string, uri: string): void {
	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return;
	const program = dbParse(db, path);
	if (program === null) return;
	const source = dbGetSource(db, path);
	// Build minimal items (label + kind + sortText only) for fast stdio transfer.
	// Defer detail/docs/textEdit to completionItem/resolve.
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null);
	const items: string[] = [];
	for (const kw of STMT_KEYWORDS) {
		items.push("{\"label\":" + lspJsonString(kw) + ",\"kind\":" + KEYWORD_COMPLETION_KIND + ",\"sortText\":\"16\"}");
	}
	for (const c of candidates) {
		const kindNum = lspCompletionItemKind(c.kind, c.isMutable);
		const sortText = lspCompletionSortText(c);
		items.push("{\"label\":" + lspJsonString(c.name) + ",\"kind\":" + kindNum + ",\"sortText\":" + lspJsonString(sortText) + "}");
	}
	// Cross-module candidates (also minimal — just label + kind)
	if (db.exportRegistry !== null) {
		const inScopeSet: HashSet<string> = new HashSet<string>();
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
	// Evict oldest if at capacity (simple: clear all — LRU is overkill for 10 entries)
	if (_prebuiltCache.size >= PREBUILT_CAPACITY) {
		_prebuiltCache = new HashMap<string, string[]>();
	}
	_prebuiltCache.set(uri, items);
}

// ===== Object Literal Type Resolution (AST-Based) =====

// Find the root struct type for an object literal by walking the AST.
// Finds the outermost ObjectLiteral ancestor, then looks for the VariableDecl
// that contains it to get the declared type via sgRecords.
function lspFindObjectLiteralTypeAST(program: Node, line: number, col: number, ctx: CheckerContext): Type | null {
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

// ===== Completion =====

function lspCompletionItemKind(kind: SymbolKind, isMutable: boolean): number {
	// Const variables -> Constant (21), let/var -> Variable (6)
	if (kind === SymbolKind.Variable) {
		if (isMutable) return 6;
		return 21;
	}
	return match (kind) {
		SymbolKind.Function => 3,
		SymbolKind.Method => 2,
		SymbolKind.Parameter => 6,
		SymbolKind.Class => 7,
		SymbolKind.Actor => 7,
		SymbolKind.Interface => 8,
		SymbolKind.Enum => 13,
		SymbolKind.TypeAlias => 7,   // Class — TS-Go maps type names to Class
		SymbolKind.Property => 10,
		_ => 6,
	};
}

// Reverse-resolve a module path to an import specifier.
// e.g., "/Users/le/project/std/build.ms" -> "std/build"
//       "/Users/le/project/src/foo.ms" -> "./foo" (relative to currentPath)
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
	const currentDir = dirname(currentPath);
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
	program: Node, source: string, kind: SgCompletionKind, inScopeSet: HashSet<string>
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
					&& sym.kind !== SymbolKind.Actor && sym.kind !== SymbolKind.Enum && sym.kind !== SymbolKind.TypeAlias) continue;
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
		const preludeExtNames: HashSet<string> = new HashSet<string>();
		if (db.preludeCtx.extensionRegistry !== null) {
			for (const m of db.preludeCtx.extensionRegistry.methods) {
				preludeExtNames.add(m.methodName);
			}
		}
		for (const sym of db.preludeCtx.table.current.symbols.values()) {
			if (sym.name.length === 0) continue;
			if (!hasFlag(sym, SymbolFlag.Exported)) continue;
			// Skip extension methods — they only appear via member access
			if (preludeExtNames.has(sym.name)) continue;
			if (prefix.length > 0 && prefix.length > sym.name.length) continue;
			if (prefix.length > 0 && sym.name.slice(0, prefix.length) !== prefix) continue;
			if (inScopeSet.has(sym.name)) continue;
			if (isTypeCtx) {
				if (sym.symbolKind !== SymbolKind.Interface && sym.symbolKind !== SymbolKind.Class
					&& sym.symbolKind !== SymbolKind.Actor && sym.symbolKind !== SymbolKind.Enum && sym.symbolKind !== SymbolKind.TypeAlias) continue;
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
	const t0 = performance.now();
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
			// The checker records every object literal's contextual type at the
			// literal's own '{'. Resolving the INNERMOST literal that way needs no
			// field path and works in argument/return/nested position; the
			// declaration walk below stays as the fallback.
			const innerObj = findEnclosingObjectLiteral(program, pos.line, pos.col + 1);
			if (innerObj !== null) {
				let innerSg = sgQueryContextualTypeAt(ctx, innerObj.location.line, innerObj.location.column);
				if (innerSg === null) {
					innerSg = sgQueryAtPosition(ctx, innerObj.location.line, innerObj.location.column);
				}
				if (innerSg !== null && innerSg.symType !== null) {
					const innerKeys = (innerObj.data as ObjectLiteralData).keys;
					const emptyPath: string[] = [];
					const innerCands = sgCompleteObjectFields(ctx, prefix, innerSg.symType, emptyPath, innerKeys);
					if (innerCands.length > 0) {
						const innerItems = formatCompletionItemsArray(innerCands, db, path);
						cache.uri = pos.uri;
						cache.line = pos.line;
						cache.prefix = prefix;
						cache.items = innerItems;
						return lspResponse(id, joinJsonItems(innerItems));
					}
				}
			}
			const fieldPath = sgObjectFieldPathAST(program, pos.line, pos.col + 1);
			const enclosingObj = findEnclosingObjectLiteral(program, pos.line, pos.col + 1);
			let existingKeys: string[] = [];
			if (enclosingObj !== null && enclosingObj.kind === NodeKind.ObjectLiteral) {
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
	const prebuiltItems = _prebuiltCache.has(pos.uri) ? _prebuiltCache.get(pos.uri) : null as unknown as string[];
	if (prefix.length === 0 && charBefore !== ".".code && prebuiltItems !== null && prebuiltItems.length > 0) {
		const limited = prebuiltItems.length > 100 ? prebuiltItems.slice(0, 100) : prebuiltItems;
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
			const emptyScope: HashSet<string> = new HashSet<string>();
			const fallbackItems = lspCrossModuleCandidates(db, prefix, path, program, source, kind, emptyScope);
			for (const kwItem of lspKeywordItems(kind, prefix)) {
				fallbackItems.push(kwItem);
			}
			if (fallbackItems.length > 0) return lspResponse(id, joinJsonItems(fallbackItems));
		}
		return lspResponse(id, "[]");
	}

	// For MemberAccess, resolve receiver type via symRecords.
	// Works for both simple (config.) and nested (config.fmt.) chains:
	// scan backward from cursor to find the last `.`, then query the token before it.
	let receiverType: Type | null = null;
	if (kind === SgCompletionKind.MemberAccess) {
		// Find the dot position by scanning source backward from cursor
		const lineOffset = sgGetLineOffset(source, pos.line);
		let dotCol = pos.col; // 0-based col of cursor
		while (dotCol > 0 && source.byteAt(lineOffset + dotCol - 1) !== ".".code) {
			dotCol = dotCol - 1;
		}
		// dotCol: scan stopped here. byteAt(lineOffset + dotCol - 1) === "."
		// So dot is at 0-based col (dotCol - 1), char before dot at 0-based col (dotCol - 2)
		// sgQueryAtPosition uses 1-based col -> (dotCol - 2) + 1 = dotCol - 1
		if (dotCol > 1) {
			const sg = sgQueryAtPosition(ctx, pos.line, dotCol - 1);
			if (sg !== null) {
				receiverType = sg.symType;
				// Static access on type name (e.g., Buffer.alloc, Result.ok):
				// use "typeof TypeName" so extension registry matches static extensions.
				if (sg.kind === SymbolKind.TypeAlias || sg.kind === SymbolKind.Class
					|| sg.kind === SymbolKind.Actor || sg.kind === SymbolKind.Interface || sg.kind === SymbolKind.Struct) {
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
		const inScopeSet: HashSet<string> = new HashSet<string>();
		for (let ci = 0; ci < candidates.length; ci = ci + 1) {
			inScopeSet.add(candidates[ci].name);
		}
		const source = dbGetSource(db, path);
		const autoImportItems = lspCrossModuleCandidates(db, prefix, path, program, source, kind, inScopeSet);
		for (let ai = 0; ai < autoImportItems.length; ai = ai + 1) {
			cachedItems.push(autoImportItems[ai]);
		}
	}

	if (kind === SgCompletionKind.Identifier || kind === SgCompletionKind.TypeAnnotation) {
		for (const kwItem of lspKeywordItems(kind, prefix)) {
			cachedItems.push(kwItem);
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
export function handleCompletionResolve(id: string, params: string): string {
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
	// "std/co" -> dir="std", filePrefix="co"
	// "std/core/" -> dir="std/core", filePrefix=""
	// "./pa" -> dir=".", filePrefix="pa"
	// "" -> dir="", filePrefix=""
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
		const fileDir = dirname(filePath);
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
			// "std/core" -> stdPath + "/core"
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
		const fileDir = dirname(filePath);
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

	const targetPath = dbResolveImport(db, filePath, importSpec);
	if (targetPath === "") return [];

	// Ensure the target module is loaded and its exports are registered
	lspEnsureFileLoaded(db, targetPath);
	if (findModuleExports(db.exportRegistry, targetPath) === null) {
		// Target not yet in registry — register its exports directly
		dbEnsureModuleExports(db, targetPath);
	}

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

// ===== Object-field completion: the contextual type, not the declaration =====
// Completion used to resolve an object literal's type by climbing to an
// annotated VariableDecl, so it only fired for `const x: T = { … }`. The
// checker now records each literal's contextual type at its own '{', and the
// innermost literal is resolved from that — argument, return and nested
// positions all complete. Measured before the fix: only DECLS_FIXTURE case A hit.

const COMPLETION_FIXTURE = `interface Style { colorX: string; widthX: number; padX: number; }
interface VNode { tagX: string; }
function mk(s: Style): VNode { return { tagX: "d" }; }
interface Sheet { btn: Style; }
`;

function completionFixtureAt(tail: string, line: number, col: number): string {
	const db = createTransAmDb(100);
	dbSetFileText(db, lspUriToPath("file:///objcomp.ms"), `${COMPLETION_FIXTURE}${tail}`);
	const params = `{"textDocument":{"uri":"file:///objcomp.ms"},"position":{"line":${line},"character":${col}}}`;
	return handleCompletion("1", params, db, createCompletionCache());
}

test "object completion: annotated variable" {
	const r = completionFixtureAt("const a: Style = {  };\n", 4, 18);
	assert r.indexOf("colorX", 0) >= 0;
}

test "object completion: nested literal offers the INNER type" {
	const r = completionFixtureAt("const c: Sheet = { btn: {  } };\n", 4, 25);
	assert r.indexOf("colorX", 0) >= 0;
	assert r.indexOf("\"label\":\"btn\"", 0) < 0;
}

test "object completion: function argument" {
	const r = completionFixtureAt("const b = mk({  });\n", 4, 14);
	assert r.indexOf("colorX", 0) >= 0;
}

test "object completion: argument with no enclosing variable" {
	const r = completionFixtureAt("function run(): void { mk({  }); }\n", 4, 27);
	assert r.indexOf("colorX", 0) >= 0;
}

test "object completion: return position" {
	const r = completionFixtureAt("function give(): Style { return {  }; }\n", 4, 33);
	assert r.indexOf("colorX", 0) >= 0;
}

// Cross-module macro-arg completion — the Neon createStyles shape. The macro
// rewrites each entry to styleOfX(entry); its body references Node/NodeKind
// imported by the DECLARING module, so the engine compile needs that module's
// ctx registered (lookupModuleCtx) — batch registers it in checkProgram, the
// db must full-check macro-declaring deps on demand.

const MACRO_MOD_FIXTURE = `import { Node, NodeKind } from "std/meta";
export interface StyleX { colorX: string; widthX: number; }
export function styleOfX(s: StyleX): StyleX { return s; }
export macro sheetX(node: Node): Node {
	let entries: Node[] = [];
	for (const v of node.properties) {
		entries.push({
			kind: NodeKind.CallExpr, line: v.line, column: v.column,
			callee: { kind: NodeKind.Identifier, line: v.line, column: v.column, name: "styleOfX" },
			arguments: [v],
		});
	}
	return {
		kind: NodeKind.ObjectLiteral, line: node.line, column: node.column,
		properties: entries, keys: node.keys, keyLocations: node.keyLocations,
	};
}
`;

const MACRO_USE_FIXTURE = `import { sheetX, styleOfX } from "./macmod";

const s = sheetX({ box: {  } });
`;

function macroFixtureDb(): TransAmDb {
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, lspUriToPath("file:///macmod.ms"), MACRO_MOD_FIXTURE);
	dbSetFileText(db, lspUriToPath("file:///macuse.ms"), MACRO_USE_FIXTURE);
	dbEnsureModuleExports(db, lspUriToPath("file:///macmod.ms"));
	return db;
}

test "cross-module macro body compiles in LSP db" {
	const db = macroFixtureDb();
	const ctx = dbTypeCheck(db, lspUriToPath("file:///macuse.ms"));
	assert ctx !== null;
	let bad = false;
	for (const e of ctx.errors) {
		if (e.message.indexOf("evaluator unavailable", 0) >= 0) bad = true;
		if (e.message.indexOf("Unresolved type", 0) >= 0) bad = true;
	}
	assert !bad;
}

test "object completion: macro argument literal (Neon createStyles shape)" {
	const db = macroFixtureDb();
	const params = `{"textDocument":{"uri":"file:///macuse.ms"},"position":{"line":2,"character":25}}`;
	const r = handleCompletion("1", params, db, createCompletionCache());
	assert r.indexOf("colorX", 0) >= 0;
}

// JSX shape (Neon element macro): the style attr literal is re-emitted as a call
// argument by the macro; its position must survive and complete against the
// param type. Callee stamped at the TAG position (no literal-position collision).

const JSX_MACRO_FIXTURE = `import { Node, NodeKind } from "std/meta";
export interface StyleX { colorX: string; widthX: number; }
export function styleOfX(s: StyleX): StyleX { return s; }
export macro jelX(node: Node): Node {
	let args: Node[] = [];
	for (const a of node.jsxAttrs) {
		if (a.jsxAttrName === "style") {
			args.push(a.jsxAttrValue);
		}
	}
	return {
		kind: NodeKind.CallExpr, line: node.line, column: node.column,
		callee: { kind: NodeKind.Identifier, line: node.line, column: node.column, name: "styleOfX" },
		arguments: args,
	};
}
`;

const JSX_USE_FIXTURE = `import { jelX, styleOfX } from "./jelmod";

const t = jelX(<div style={{  }}></div>);
`;

test "object completion: JSX style attribute literal (Neon element shape)" {
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, lspUriToPath("file:///jelmod.ms"), JSX_MACRO_FIXTURE);
	dbSetFileText(db, lspUriToPath("file:///jeluse.ms"), JSX_USE_FIXTURE);
	dbEnsureModuleExports(db, lspUriToPath("file:///jelmod.ms"));
	const params = `{"textDocument":{"uri":"file:///jeluse.ms"},"position":{"line":2,"character":28}}`;
	const r = handleCompletion("1", params, db, createCompletionCache());
	assert r.indexOf("colorX", 0) >= 0;
}

// Lifecycle parity matters: didOpen records the user file's import edges, and
// didChange's invalidation reaches dependents THROUGH those edges. Raw
// dbSetFileText without a prior didOpen leaves the dependent green and stale.
test "object completion: macro module edit refreshes the expansion" {
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	handleDidOpen(`{"textDocument":{"uri":"file:///macmod.ms","text":${lspJsonString(MACRO_MOD_FIXTURE)}}}`, db);
	handleDidOpen(`{"textDocument":{"uri":"file:///macuse.ms","text":${lspJsonString(MACRO_USE_FIXTURE)}}}`, db);
	const params = `{"textDocument":{"uri":"file:///macuse.ms"},"position":{"line":2,"character":25}}`;
	const r1 = handleCompletion("1", params, db, createCompletionCache());
	assert r1.indexOf("colorX", 0) >= 0;
	assert r1.indexOf("padX", 0) < 0;
	const v2 = MACRO_MOD_FIXTURE.replace("colorX: string;", "colorX: string; padX: number;");
	handleDidChange(`{"textDocument":{"uri":"file:///macmod.ms"},"contentChanges":[{"text":${lspJsonString(v2)}}]}`, db);
	const r2 = handleCompletion("2", params, db, createCompletionCache());
	assert r2.indexOf("padX", 0) >= 0;
}

test "mutually importing macro modules terminate" {
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	const cycA = `import { mB } from "./cycb";
import { Node } from "std/meta";
export macro mA(node: Node): Node { return node; }
`;
	const cycB = `import { mA } from "./cyca";
import { Node } from "std/meta";
export macro mB(node: Node): Node { return node; }
`;
	dbSetFileText(db, lspUriToPath("file:///cyca.ms"), cycA);
	dbSetFileText(db, lspUriToPath("file:///cycb.ms"), cycB);
	dbEnsureModuleExports(db, lspUriToPath("file:///cyca.ms"));
	dbEnsureModuleExports(db, lspUriToPath("file:///cycb.ms"));
	const use = `import { mA } from "./cyca";

const z = mA({ a: 1 });
`;
	dbSetFileText(db, lspUriToPath("file:///cycuse.ms"), use);
	const ctx = dbTypeCheck(db, lspUriToPath("file:///cycuse.ms"));
	assert ctx !== null;
}

// ===== Keyword completion =====

test "keyword completion: statement prefix offers converter" {
	const r = completionFixtureAt("conv\n", 4, 4);
	assert r.indexOf("\"label\":\"converter\"", 0) >= 0;
}

test "keyword completion: statement prefix offers function" {
	const r = completionFixtureAt("fun\n", 4, 3);
	assert r.indexOf("\"label\":\"function\"", 0) >= 0;
}

test "keyword completion: type annotation offers uint32 not function" {
	const r = completionFixtureAt("const v: uin = 0;\n", 4, 12);
	assert r.indexOf("\"label\":\"uint32\"", 0) >= 0;
	assert r.indexOf("\"label\":\"function\"", 0) < 0;
}

test "keyword completion: member access offers no keywords" {
	const r = completionFixtureAt("function f(s: Style): void { s. }\n", 4, 31);
	assert r.indexOf("colorX", 0) >= 0;
	assert r.indexOf("\"label\":\"const\"", 0) < 0;
}

test "keyword completion: annotation on decl without initializer" {
	const r = completionFixtureAt("let v: uin\n", 4, 10);
	assert r.indexOf("\"label\":\"uint32\"", 0) >= 0;
}

test "keyword completion: file holds a decl without initializer elsewhere" {
	const r = completionFixtureAt("conv\nlet v: uin\n", 4, 4);
	assert r.indexOf("\"label\":\"converter\"", 0) >= 0;
}

test "keyword completion: items carry the LSP Keyword kind" {
	const r = completionFixtureAt("conv\n", 4, 4);
	assert r.indexOf("\"label\":\"converter\",\"kind\":14", 0) >= 0;
}

test "keyword completion: a clean file still offers keywords" {
	const r = completionFixtureAt("const q = 1;\nfun\n", 5, 3);
	assert r.indexOf("\"label\":\"function\"", 0) >= 0;
}

test "keyword completion: object field context offers none" {
	const r = completionFixtureAt("const a: Style = {  };\n", 4, 18);
	assert r.indexOf("colorX", 0) >= 0;
	assert r.indexOf("\"kind\":14", 0) < 0;
}

test "keyword completion: import name context offers none" {
	const r = completionFixtureAt("import { m } from \"./x\";\n", 4, 10);
	assert r.indexOf("\"kind\":14", 0) < 0;
}

test "keyword completion: a prefix matching no keyword adds no noise" {
	const r = completionFixtureAt("zzq\n", 4, 3);
	assert r.indexOf("\"kind\":14", 0) < 0;
}

test "keyword completion: parameter annotation offers type keywords" {
	const r = completionFixtureAt("function g(p: uin): void { }\n", 4, 17);
	assert r.indexOf("\"label\":\"uint32\"", 0) >= 0;
}

test "keyword completion: prebuilt empty-prefix includes const" {
	const db = createTransAmDb(100);
	dbSetFileText(db, lspUriToPath("file:///kwpre.ms"), "const a = 1;\n\n");
	prebuildCompletionCache(db, lspUriToPath("file:///kwpre.ms"), "file:///kwpre.ms");
	const params = `{"textDocument":{"uri":"file:///kwpre.ms"},"position":{"line":1,"character":0}}`;
	const r = handleCompletion("1", params, db, createCompletionCache());
	assert r.indexOf("\"label\":\"const\"", 0) >= 0;
}
