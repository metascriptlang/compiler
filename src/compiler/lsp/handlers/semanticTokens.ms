// LSP Semantic Tokens — full token coloring with revision-based cache.

import { TransAmDb, dbParse, dbTypeCheck } from "../../transam/index";
import { lspJsonNumber, lspGetField, lspGetObjectField, lspUriToPath, lspResponse } from "../protocol";
import { SgSemanticToken, sgCollectSemanticTokens, sgSortTokens } from "../../../checker/suggest";

function encodeSemanticTokenDeltas(tokens: SgSemanticToken[]): string {
	sgSortTokens(tokens);
	let prevLine = 0;
	let prevCol = 0;
	let arr = "[";
	let i = 0;
	while (i < tokens.length) {
		const t = tokens[i];
		const line = t.line - 1;
		const col = t.col - 1;
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

// Revision-based cache: if Trans-Am revision unchanged, tokens are identical.
let _semTokenCache: HashMap<string, string> = new HashMap<string, string>();
let _semTokenRevision: HashMap<string, number> = new HashMap<string, number>();

export function handleSemanticTokensFull(id: string, params: string, db: TransAmDb): string {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const path = lspUriToPath(uri);

	const rev = db.revision.value;
	if (_semTokenRevision.has(path) && _semTokenRevision.get(path) === rev) {
		return lspResponse(id, "{\"data\":" + _semTokenCache.get(path) + "}");
	}

	const program = dbParse(db, path);
	if (program === null) return lspResponse(id, "{\"data\":[]}");

	const ctx = dbTypeCheck(db, path);
	if (ctx === null) return lspResponse(id, "{\"data\":[]}");

	const tokens = sgCollectSemanticTokens(ctx, program);
	const data = encodeSemanticTokenDeltas(tokens);

	_semTokenCache.set(path, data);
	_semTokenRevision.set(path, rev);

	return lspResponse(id, "{\"data\":" + data + "}");
}
