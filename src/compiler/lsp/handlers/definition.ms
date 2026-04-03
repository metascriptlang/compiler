// LSP Handlers — Go to Definition, source navigation helpers.

import { TransAmDb, dbParse, dbTypeCheck } from "../../transam/index";
import { readFile } from "std/process";
import { writeStderr } from "std/io";
import {
	lspUriToPath, lspPathToUri, lspDirname,
	lspResponse
} from "../protocol";
import {
	lspFmtLocation,
} from "../format";
import { sgGetPrefix, sgFindImportSource, sgFindExportedDecl, sgQueryAtPosition } from "../../../checker/suggest";
import { SymbolFlag, hasFlag } from "../../../checker/symbol";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData, SourceLocation, makeLoc, SymbolKind } from "../../../ast/node";
import { lspExtractPosition, dbGetSource, resolveImportForLsp, lspEnsureFileLoaded } from "./shared";


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

// ===== Extern -> Native Header Navigation =====

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
		// Extern function -> navigate to C definition in module's .h file
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
