// LSP Semantic Tokens — full token coloring with revision-based cache.

import { TransAmDb, dbParse, dbTypeCheck, createTransAmDb, dbSetFileText } from "../../transam/index";
import { lspJsonNumber, lspGetField, lspGetObjectField, lspUriToPath, lspResponse } from "../protocol";
import { lspFmtSemanticTokens } from "../format";
import { SgSemanticToken, sgCollectSemanticTokens, sgSortTokens } from "../../../checker/suggest";
import { dbGetSource, lspDocumentUri } from "./shared";
import { LineIndex, lineStart } from "../../../utils/sourceLines";

function encodeSemanticTokenDeltas(source: string, tokens: SgSemanticToken[]): string {
	sgSortTokens(tokens);
	let prevLine = 0;
	let prevCol = 0;
	const lines = LineIndex.build(source);
	const fields: string[] = [];
	for (const t of tokens) {
		const line = t.line - 1;
		const start = lines.lineStart(t.line);
		const col = source.byteSlice(start, start + t.col - 1).length;
		const deltaLine = line - prevLine;
		const deltaStart = deltaLine == 0 ? col - prevCol : col;
		fields.push(lspJsonNumber(deltaLine));
		fields.push(lspJsonNumber(deltaStart));
		fields.push(lspJsonNumber(t.length));
		fields.push(lspJsonNumber(t.tokenType));
		fields.push(lspJsonNumber(t.modifiers));
		prevLine = line;
		prevCol = col;
	}
	return "[" + fields.join(",") + "]";
}

struct SemanticTokenEntry {
	revision: int32;
	data: string;
}

// Revision-based cache: if Trans-Am revision unchanged, tokens are identical.
let _semTokenCache: HashMap<string, SemanticTokenEntry> = new HashMap<string, SemanticTokenEntry>();

export function handleSemanticTokensFull(id: string, params: string, db: TransAmDb): string {
	const uri = lspDocumentUri(params);
	const path = lspUriToPath(uri);

	const rev = db.revision.value;
	const cached = _semTokenCache.get(path);
	if (cached != null && cached.revision == rev) {
		return lspResponse(id, lspFmtSemanticTokens(cached.data));
	}

	const program = dbParse(db, path);
	if (program == null) return lspResponse(id, lspFmtSemanticTokens("[]"));

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, lspFmtSemanticTokens("[]"));

	const tokens = sgCollectSemanticTokens(ctx, program);
	const data = encodeSemanticTokenDeltas(dbGetSource(db, path), tokens);

	_semTokenCache.set(path, { revision: rev, data });

	return lspResponse(id, lspFmtSemanticTokens(data));
}

const TOKEN_TYPES = ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method"];
const TOKEN_MODIFIERS = ["declaration", "definition", "readonly", "static", "defaultLibrary"];

function tokenRows(source: string): string {
	const db = createTransAmDb(100);
	dbSetFileText(db, "tokens.ms", source);
	const program = dbParse(db, "tokens.ms");
	const ctx = dbTypeCheck(db, "tokens.ms");
	if (program == null || ctx == null) return "unchecked";
	const tokens = sgCollectSemanticTokens(ctx, program);
	sgSortTokens(tokens);
	const rows: string[] = [];
	for (const t of tokens) {
		const mods: string[] = [];
		for (let bit = 0; bit < TOKEN_MODIFIERS.length; bit += 1) {
			if ((t.modifiers & (1 << bit)) != 0) mods.push(TOKEN_MODIFIERS[bit]);
		}
		rows.push(`${t.line - 1}:${t.col - 1}+${t.length} ${TOKEN_TYPES[t.tokenType]}${mods.length > 0 ? " " + mods.join("+") : ""}`);
	}
	return rows.join(", ");
}

test "a read of a parameter or a local takes the token of the symbol the checker bound it to" {
	const rows = tokenRows("class Box {\n\tv: int32;\n\tconstructor(v: int32) {\n\t\tthis.v = v;\n\t}\n}\nfunction add(a: int32): int32 {\n\tconst k = 2;\n\treturn a + k;\n}\n");
	assert rows == "0:6+3 class declaration, 1:1+1 property declaration, 2:13+1 parameter declaration, 3:7+1 property, 3:11+1 parameter, 6:9+3 function declaration, 6:13+1 parameter declaration, 7:7+1 variable declaration+readonly, 8:8+1 parameter, 8:12+1 variable readonly", rows;
}

test "a read inside a nested function or a loop block takes the token of its own binding" {
	const rows = tokenRows("function outer(a: int32): int32 {\n\tlet s = a;\n\tconst twice = (n: int32): int32 => n + n;\n\tfor (let i = 0; i < 2; i += 1) s = s + twice(i);\n\treturn s;\n}\n");
	assert rows == "0:9+5 function declaration, 0:15+1 parameter declaration, 1:5+1 variable declaration, 1:9+1 parameter, 2:7+5 variable declaration+readonly, 2:16+1 parameter declaration, 2:36+1 parameter, 2:40+1 parameter, 3:10+1 variable declaration, 3:17+1 variable, 3:24+1 variable, 3:32+1 variable, 3:36+1 variable, 3:40+5 variable readonly, 3:46+1 variable, 4:8+1 variable", rows;
}

test "a field declaration takes a property token whatever its modifiers or initializer" {
	const rows = tokenRows("class C {\n\tstatic readonly s = 1;\n\tprivate w: int32 = 0;\n\tq?: string;\n}\n");
	assert rows == "0:6+1 class declaration, 1:17+1 property declaration, 2:9+1 property declaration, 3:1+1 property declaration", rows;
}
