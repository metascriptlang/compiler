// LSP Handlers — Go to Definition, source navigation helpers.

import { TransAmDb, dbParse, dbTypeCheck } from "../../transam/index";
import { readFile, exists } from "std/fs";
import { resolveRuntimeDir } from "../../../utils/path";
import { writeStderr } from "std/io";
import {
	lspUriToPath, lspPathToUri, dirname,
	lspResponse
} from "../protocol";
import {
	lspFmtLocation,
} from "../format";
import { sgQueryAtPosition } from "../../../checker/suggest";
import { findExportedSymbol } from "../../../checker/context";
import { SymbolFlag, hasFlag } from "../../../checker/symbol";
import { Node, SourceLocation, makeLoc, Symbol, SymbolKind, NodeKind, TypeKind, EnumDeclData, ImportDeclData, ExportDeclData, ProgramData } from "../../../ast/node";
import { lspExtractPosition, dbGetSource, lspEnsureFileLoaded } from "./shared";
import { lspPosition, lspPositionAt } from "../position";
import { dbResolveImport } from "../../transam/index";
import { isAlphanumeric, newlineWidth } from "../../../lexer/chars";
import { LineIndex, lineStart, lineOf } from "../../../utils/sourceLines";


// Byte offset of the first whole-word `word` that lies inside [from, to), or -1.
function findWord(src: string, word: string, from: int32, to: int32): int32 {
	const width = word.byteLength;
	if (width == 0) return -1;
	let at = src.byteIndexOf(word, from);
	while (at >= 0 && at + width <= to) {
		const end = at + width;
		const startsWord = at == 0 || !isAlphanumeric(src.byteAt(at - 1));
		const endsWord = end >= src.byteLength || !isAlphanumeric(src.byteAt(end));
		if (startsWord && endsWord) return at;
		at = src.byteIndexOf(word, at + 1);
	}
	return -1;
}

function lineEnd(src: string, start: int32): int32 {
	let end = start;
	while (end < src.byteLength && newlineWidth(src, end) == 0) end += 1;
	return end;
}

// 0-based line and LSP character of a byte offset.
function locationAt(src: string, offset: int32): SourceLocation {
	const at = lspPositionAt(LineIndex.buildLsp(src), src, offset);
	return makeLoc(at.line, at.character);
}

function findNameByteColumn(src: string, targetLine: int32, name: string): int32 {
	if (targetLine < 0) return -1;
	const lines = LineIndex.build(src);
	const start = lines.lineStart(targetLine + 1);
	const at = findWord(src, name, start, lineEnd(src, start));
	return at < 0 ? -1 : at - start;
}

// Find a field declaration (`name:` or `name?`) in the lines after `startLine`, stopping at the
// first line that closes a brace. Returns 0-based {line, col}, or {-1, -1}.
function lspFindFieldLine(src: string, startLine: int32, fieldName: string): SourceLocation {
	let line = startLine + 1;
	const lines = LineIndex.build(src);
	let start = lines.lineStart(line + 1);
	while (start < src.byteLength) {
		const end = lineEnd(src, start);
		let at = findWord(src, fieldName, start, end);
		while (at >= 0) {
			let next = at + fieldName.byteLength;
			while (next < src.byteLength && (src.byteAt(next) == " ".code || src.byteAt(next) == "\t".code)) {
				next++;
			}
			if (next < src.byteLength && (src.byteAt(next) == ":".code || src.byteAt(next) == "?".code)) {
				return makeLoc(line, at - start);
			}
			at = findWord(src, fieldName, at + 1, end);
		}
		const brace = src.byteIndexOf("}", start);
		if (brace >= 0 && brace < end) return makeLoc(-1, -1);
		line++;
		start = lines.lineStart(line + 1);
	}
	return makeLoc(-1, -1);
}

// The member's own declaration, read from the enum declaration its type's symbol owns;
// line 0 when the symbol names no enum member.
function lspEnumMemberDecl(sym: Symbol | null, memberName: string): SourceLocation {
	let enumType = sym != null ? sym.symbolType : null;
	if (enumType != null && enumType.kind == TypeKind.EnumLiteral) enumType = enumType.typeReturn;
	const enumSym = enumType != null ? enumType.sym : null;
	const decl = enumSym != null ? enumSym.declNode : null;
	if (decl == null || decl.kind != NodeKind.EnumDecl) return makeLoc(0, 0);
	const d = decl.data as EnumDeclData;
	const at = d.enumMembers.indexOf(memberName);
	return at >= 0 && at < d.memberLocations.length ? d.memberLocations[at] : makeLoc(0, 0);
}

// ===== Extern -> Native Header Navigation =====

function lspFindNativeDefinition(nativeName: string, headerPath: string, modulePath: string): string {
	// headerPath may contain multiple paths (newline-separated). Search each.
	// Resolve relative to the MODULE that declares the extern, not the current file.
	const headers = headerPath.split("\n");
	for (const h of headers) {
		if (h == "") continue;
		const result = lspSearchHeaderForName(nativeName, h, modulePath);
		if (result != "") return result;
	}
	return "";
}

// Resolve a header path from an extern symbol's headerPath/@include directive.
// Absolute paths are used as-is. Relative paths are tried against the module's
// own directory first (for ./local.h style imports), then against the compiler
// root (for workspace-rooted imports like runtime/os.h).
function lspResolveHeaderPath(headerRelPath: string, modulePath: string): string {
	if (headerRelPath.length > 0 && headerRelPath.charCodeAt(0) == "/".code) {
		return headerRelPath;
	}
	const moduleRel = dirname(modulePath) + "/" + headerRelPath;
	if (exists(moduleRel)) return moduleRel;
	const root = resolveRuntimeDir();
	if (root != "") {
		const rootRel = root + "/" + headerRelPath;
		if (exists(rootRel)) return rootRel;
	}
	return moduleRel;
}

function lspSearchHeaderForName(nativeName: string, headerRelPath: string, modulePath: string): string {
	const hPath = lspResolveHeaderPath(headerRelPath, modulePath);
	const hResult = readFile(hPath);
	if (!hResult.ok) return "";
	const at = findWord(hResult.value, nativeName, 0, hResult.value.byteLength);
	if (at < 0) return "";
	const start = locationAt(hResult.value, at);
	const hUri = lspPathToUri(hPath);
	return lspFmtLocation(
		hUri, start.line, start.column, start.line, start.column + nativeName.byteLength,
	);
}

// ===== Definition =====

export function handleDefinition(id: string, params: string, db: TransAmDb): string {
	const pos = lspExtractPosition(params, db);
	const path = lspUriToPath(pos.uri);

	const program = dbParse(db, path);
	if (program == null) {
		writeStderr("[LSP-DEF] id=" + id + " null: no parse for " + path + "\n");
		return lspResponse(id, "null");
	}

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) {
		writeStderr("[LSP-DEF] id=" + id + " null: no ctx for " + path + "\n");
		return lspResponse(id, "null");
	}

	const suggest = sgQueryAtPosition(ctx, pos.line, pos.col1);
	if (suggest == null) {
		writeStderr("[LSP-DEF] id=" + id + " null: no sgQuery at " + pos.line + ":" + pos.col1 + " in " + path + "\n");
	}
	if (suggest != null) {
		// Extern symbol -> navigate to C definition: a header's declarations are the
		// module of the header that writes them; a hand-written extern names its
		// headers in @include. The raw C source is searched for the native name.
		if (suggest.sym != null && hasFlag(suggest.sym, SymbolFlag.ImportC)
			&& suggest.sym.nativeName != "") {
			const externModPath = suggest.sym.modulePath != null && suggest.sym.modulePath != "" ? suggest.sym.modulePath : path;
			const hdrPath = externModPath.endsWith(".h") ? externModPath : suggest.sym.headerPath;
			if (hdrPath != "") {
				const nativeResult = lspFindNativeDefinition(suggest.sym.nativeName, hdrPath, externModPath);
				if (nativeResult != "") return lspResponse(id, "[" + nativeResult + "]");
			}
		}

		let defLine = suggest.location.line - 1;
		let defCol = suggest.location.column - 1;
		let defUri = pos.uri;
		let defSrc = "";

		// Cross-file: symbol defined in another module (import or prelude)
		const modPath = suggest.modulePath;
		if (modPath != null && modPath != "" && modPath != path) {
			lspEnsureFileLoaded(db, modPath);
			defUri = lspPathToUri(modPath);
			defSrc = dbGetSource(db, modPath);
		} else {
			defSrc = dbGetSource(db, path);
		}

		// Refine line/col using source text
		if (defSrc != "") {
			if (suggest.kind == SymbolKind.EnumMember) {
				const memberLoc = lspEnumMemberDecl(suggest.sym, suggest.name);
				if (memberLoc.line > 0) {
					defLine = memberLoc.line - 1;
					defCol = memberLoc.column - 1;
				}
			} else if (suggest.kind == SymbolKind.Property) {
				const fieldLoc = lspFindFieldLine(defSrc, defLine, suggest.name);
				if (fieldLoc.line >= 0) {
					defLine = fieldLoc.line;
					defCol = fieldLoc.column;
				} else {
					const nameCol = findNameByteColumn(defSrc, defLine, suggest.name);
					if (nameCol >= 0) defCol = nameCol;
				}
			} else {
				const nameCol = findNameByteColumn(defSrc, defLine, suggest.name);
				if (nameCol >= 0) defCol = nameCol;
			}
			const at = lspPosition(defSrc, defLine + 1, defCol + 1);
			defLine = at.line;
			defCol = at.character;
		}
		const location = lspFmtLocation(defUri, defLine, defCol, defLine, defCol + suggest.name.length);
		return lspResponse(id, "[" + location + "]");
	}

	// No record at the cursor: it may sit on an import specifier whose binding is not recorded.
	// The specifier names an export of the source module; that export's symbol says where it is declared.
	const specifier = lspImportSpecifierAt(program, pos.line, pos.col1);
	if (specifier == null) return lspResponse(id, "null");
	const importSpec = specifier.source;
	const targetPath = dbResolveImport(db, path, importSpec);
	if (targetPath == "" || db.exportRegistry == null) return lspResponse(id, "null");

	lspEnsureFileLoaded(db, targetPath);

	const exported = findExportedSymbol(db.exportRegistry, targetPath, specifier.name);
	if (exported == null || exported.sym == null || exported.sym.location == null || exported.sym.location.line <= 0) return lspResponse(id, "null");
	const declPath = exported.sym.modulePath != null && exported.sym.modulePath != "" ? exported.sym.modulePath : targetPath;
	lspEnsureFileLoaded(db, declPath);

	const targetUri = lspPathToUri(declPath);
	let tLine = exported.sym.location.line - 1;
	let tCol = exported.sym.location.column - 1;
	const targetSrc = dbGetSource(db, declPath);
	if (targetSrc != "") {
		const tNameCol = findNameByteColumn(targetSrc, tLine, specifier.name);
		if (tNameCol >= 0) tCol = tNameCol;
		const at = lspPosition(targetSrc, tLine + 1, tCol + 1);
		tLine = at.line;
		tCol = at.character;
	}
	return lspResponse(id, "[" + lspFmtLocation(targetUri, tLine, tCol, tLine, tCol + specifier.name.length) + "]");
}

interface ImportSpecifierAt {
	source: string;
	name: string;
}

// The import specifier written at a 1-based position, found by its recorded location and not by spelling.
function lspImportSpecifierAt(program: Node, line: int32, col1: int32): ImportSpecifierAt | null {
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
		if (decl.kind != NodeKind.ImportDecl) continue;
		const imp = decl.data as ImportDeclData;
		for (let i = 0; i < imp.importNames.length && i < imp.nameLocations.length; i += 1) {
			const at = imp.nameLocations[i];
			if (at.line == line && col1 >= at.column && col1 < at.column + imp.importNames[i].byteLength) {
				return { source: imp.importSource, name: imp.importNames[i] };
			}
		}
	}
	return null;
}

// ===== Tests =====

test "findWord matches only at word boundaries" {
	const src = "fooBar foo foo_x foo";
	assert findWord(src, "foo", 0, src.byteLength) == 7;
	assert findWord(src, "foo", 8, src.byteLength) == 17;
	assert findWord(src, "foo", 0, 10) == 7;
	assert findWord(src, "foo", 0, 9) == -1;
	assert findWord(src, "bar", 0, src.byteLength) == -1;
}

test "findWord offsets are bytes after multibyte text" {
	const src = "// héllo\nname";
	assert findWord(src, "name", 0, src.byteLength) == 10;
	assert findWord(src, "héllo", 0, src.byteLength) == 3;
	assert findWord(src, "", 0, src.byteLength) == -1;
}

test "definition name lookup keeps byte coordinates until the protocol boundary" {
	const src = "let é = name;\nname";
	assert findNameByteColumn(src, 0, "name") == 9;
	assert lspPosition(src, 1, findNameByteColumn(src, 0, "name") + 1).character == 8;
	assert findNameByteColumn(src, 1, "name") == 0;
	assert findNameByteColumn(src, 2, "name") == -1;
	assert findNameByteColumn(src, -1, "name") == -1;
}

test "lspFindFieldLine stops at the closing brace" {
	const src = "interface A {\n\tx: int32;\n\ty?: int32;\n}\nconst y: int32 = 1;";
	assert lspFindFieldLine(src, 0, "y").line == 2;
	assert lspFindFieldLine(src, 0, "y").column == 1;
	assert lspFindFieldLine(src, 0, "z").line == -1;
}
