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
import { sgGetPrefix, sgFindImportSource, sgFindExportedDecl, sgQueryAtPosition } from "../../../checker/suggest";
import { SymbolFlag, hasFlag } from "../../../checker/symbol";
import { SourceLocation, makeLoc, SymbolKind } from "../../../ast/node";
import { lspExtractPosition, dbGetSource, lspEnsureFileLoaded, lspCharacter } from "./shared";
import { dbResolveImport } from "../../transam/index";
import { isAlphanumeric } from "../../../lexer/chars";
import { lineOffset } from "../../fmt/edit";


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

function lineEnd(src: string, lineStart: int32): int32 {
	const newline = src.byteIndexOf("\n", lineStart);
	return newline < 0 ? src.byteLength : newline;
}

// 0-based line and LSP character of a byte offset.
function locationAt(src: string, offset: int32): SourceLocation {
	let line: int32 = 0;
	let lineStart: int32 = 0;
	for (let i: int32 = 0; i < offset; i++) {
		if (src.byteAt(i) == "\n".code) {
			line++;
			lineStart = i + 1;
		}
	}
	return makeLoc(line, lspCharacter(src, line + 1, offset - lineStart + 1));
}

// Find the 0-based column of `name` as a whole word on 0-based `targetLine`.
function lspFindNameCol(src: string, targetLine: int32, name: string): int32 {
	if (targetLine < 0) return -1;
	const lineStart = lineOffset(src, targetLine + 1);
	const at = findWord(src, name, lineStart, lineEnd(src, lineStart));
	return at < 0 ? -1 : lspCharacter(src, targetLine + 1, at - lineStart + 1);
}

// Find a field declaration (`name:` or `name?`) in the lines after `startLine`, stopping at the
// first line that closes a brace. Returns 0-based {line, col}, or {-1, -1}.
function lspFindFieldLine(src: string, startLine: int32, fieldName: string): SourceLocation {
	let line = startLine + 1;
	let lineStart = lineOffset(src, line + 1);
	while (lineStart < src.byteLength) {
		const end = lineEnd(src, lineStart);
		let at = findWord(src, fieldName, lineStart, end);
		while (at >= 0) {
			let next = at + fieldName.byteLength;
			while (next < src.byteLength && (src.byteAt(next) == " ".code || src.byteAt(next) == "\t".code)) {
				next++;
			}
			if (next < src.byteLength && (src.byteAt(next) == ":".code || src.byteAt(next) == "?".code)) {
				return makeLoc(line, lspCharacter(src, line + 1, at - lineStart + 1));
			}
			at = findWord(src, fieldName, at + 1, end);
		}
		const brace = src.byteIndexOf("}", lineStart);
		if (brace >= 0 && brace < end) return makeLoc(-1, -1);
		line++;
		lineStart = end + 1;
	}
	return makeLoc(-1, -1);
}

// Find an enum member declaration: the `enum ContainerName` line, then the member before the
// closing brace. A member that is not found resolves to the enum declaration itself.
function lspFindEnumMemberLine(src: string, containerName: string, memberName: string): SourceLocation {
	const enumAt = findWord(src, "enum " + containerName, 0, src.byteLength);
	if (enumAt < 0) return makeLoc(-1, -1);
	const enumEnd = enumAt + "enum ".length + containerName.byteLength;
	const memberAt = findWord(src, memberName, enumEnd, src.byteLength);
	const brace = src.byteIndexOf("}", enumEnd);
	const found = memberAt >= 0 && (brace < 0 || memberAt < brace) ? memberAt : enumAt;
	return locationAt(src, found);
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
			defCol = lspCharacter(defSrc, defLine + 1, defCol + 1);
			if (suggest.kind == SymbolKind.EnumMember && suggest.containerName != "") {
				// Enum member: search for "enum ContainerName" then member within block
				const enumLoc = lspFindEnumMemberLine(defSrc, suggest.containerName, suggest.name);
				if (enumLoc.line >= 0) {
					defLine = enumLoc.line;
					defCol = enumLoc.column;
				}
			} else if (suggest.kind == SymbolKind.Property) {
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
	const src = dbGetSource(db, path);
	const identName = sgGetPrefix(src, pos.line, pos.col);
	if (identName == "") return lspResponse(id, "null");

	const importSpec = sgFindImportSource(program, identName);
	if (importSpec == "") return lspResponse(id, "null");

	const targetPath = dbResolveImport(db, path, importSpec);
	if (targetPath == "") return lspResponse(id, "null");

	lspEnsureFileLoaded(db, targetPath);

	const targetProgram = dbParse(db, targetPath);
	if (targetProgram == null) return lspResponse(id, "null");

	const declLoc = sgFindExportedDecl(targetProgram, identName);
	if (declLoc.line == 0) return lspResponse(id, "null");

	const targetUri = lspPathToUri(targetPath);
	const tLine = declLoc.line - 1;
	let tCol = declLoc.column - 1;
	const targetSrc = dbGetSource(db, targetPath);
	if (targetSrc != "") {
		tCol = lspCharacter(targetSrc, tLine + 1, tCol + 1);
		const tNameCol = lspFindNameCol(targetSrc, tLine, identName);
		if (tNameCol >= 0) tCol = tNameCol;
	}
	return lspResponse(id, "[" + lspFmtLocation(targetUri, tLine, tCol, tLine, tCol + identName.length) + "]");
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

test "lspFindNameCol reports the LSP character after multibyte text" {
	const src = "let é = name;\nname";
	assert lspFindNameCol(src, 0, "name") == 8;
	assert lspFindNameCol(src, 1, "name") == 0;
	assert lspFindNameCol(src, 2, "name") == -1;
	assert lspFindNameCol(src, -1, "name") == -1;
}

test "lspFindFieldLine stops at the closing brace" {
	const src = "interface A {\n\tx: int32;\n\ty?: int32;\n}\nconst y: int32 = 1;";
	assert lspFindFieldLine(src, 0, "y").line == 2;
	assert lspFindFieldLine(src, 0, "y").column == 1;
	assert lspFindFieldLine(src, 0, "z").line == -1;
}

test "lspFindEnumMemberLine falls back to the enum line" {
	const src = "enum Color {\n\tRed,\n\tBlue,\n}\nenum ColorX {\n\tGreen,\n}";
	assert lspFindEnumMemberLine(src, "Color", "Blue").line == 2;
	assert lspFindEnumMemberLine(src, "Color", "Green").line == 0;
	assert lspFindEnumMemberLine(src, "ColorX", "Green").line == 5;
	assert lspFindEnumMemberLine(src, "Nope", "Red").line == -1;
}
