// LSP Semantic Tokens — full token coloring with revision-based cache.

import { TransAmDb, dbParse, dbTypeCheck } from "../../transam/index";
import { lspJsonNumber, lspGetField, lspGetObjectField, lspUriToPath, lspResponse } from "../protocol";
import { SgSemanticToken, sgCollectSemanticTokens, sgSortTokens } from "../../../checker/suggest";
import { dbGetSource } from "./shared";

function encodeSemanticTokenDeltas(source: string, tokens: SgSemanticToken[]): string {
	sgSortTokens(tokens);
	let prevLine = 0;
	let prevCol = 0;
	let lineStart = 0;
	let lineNumber = 1;
	let arr = "[";
	let i = 0;
	while (i < tokens.length) {
		const t = tokens[i];
		while (lineNumber < t.line && lineStart < source.byteLength) {
			if (source.byteAt(lineStart) == "\n".code) lineNumber = lineNumber + 1;
			lineStart = lineStart + 1;
		}
		const line = t.line - 1;
		const col = source.byteSlice(lineStart, lineStart + t.col - 1).length;
		const deltaLine = line - prevLine;
		let deltaStart = col;
		if (deltaLine == 0) deltaStart = col - prevCol;
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

// Revision-based cache: if Trans-Am revision unchanged, tokens are identical.
let _semTokenCache: HashMap<string, string> = new HashMap<string, string>();
let _semTokenRevision: HashMap<string, number> = new HashMap<string, number>();

export function handleSemanticTokensFull(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);

	const rev = db.revision.value;
	const cachedRev = _semTokenRevision.get(path);
	if (cachedRev != null && cachedRev == rev) {
		return lspResponse(id, "{\"data\":" + (_semTokenCache.get(path) ?? "") + "}");
	}

	const program = dbParse(db, path);
	if (program == null) return lspResponse(id, "{\"data\":[]}");

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "{\"data\":[]}");

	const tokens = sgCollectSemanticTokens(ctx, program);
	const data = encodeSemanticTokenDeltas(dbGetSource(db, path), tokens);

	_semTokenCache.set(path, data);
	_semTokenRevision.set(path, rev);

	return lspResponse(id, "{\"data\":" + data + "}");
}
