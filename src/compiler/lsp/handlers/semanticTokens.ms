// LSP Semantic Tokens — full token coloring with revision-based cache.

import { TransAmDb, dbParse, dbTypeCheck } from "../../transam/index";
import { lspJsonNumber, lspGetField, lspGetObjectField, lspUriToPath, lspResponse } from "../protocol";
import { SgSemanticToken, sgCollectSemanticTokens, sgSortTokens } from "../../../checker/suggest";
import { dbGetSource, lspDocumentUri } from "./shared";

function encodeSemanticTokenDeltas(source: string, tokens: SgSemanticToken[]): string {
	sgSortTokens(tokens);
	let prevLine = 0;
	let prevCol = 0;
	let lineStart = 0;
	let lineNumber = 1;
	const fields: string[] = [];
	for (const t of tokens) {
		while (lineNumber < t.line && lineStart < source.byteLength) {
			if (source.byteAt(lineStart) == "\n".code) lineNumber = lineNumber + 1;
			lineStart = lineStart + 1;
		}
		const line = t.line - 1;
		const col = source.byteSlice(lineStart, lineStart + t.col - 1).length;
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
		return lspResponse(id, "{\"data\":" + cached.data + "}");
	}

	const program = dbParse(db, path);
	if (program == null) return lspResponse(id, "{\"data\":[]}");

	const ctx = dbTypeCheck(db, path);
	if (ctx == null) return lspResponse(id, "{\"data\":[]}");

	const tokens = sgCollectSemanticTokens(ctx, program);
	const data = encodeSemanticTokenDeltas(dbGetSource(db, path), tokens);

	_semTokenCache.set(path, { revision: rev, data });

	return lspResponse(id, "{\"data\":" + data + "}");
}
