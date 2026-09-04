// Literal Printers — number, string, boolean, identifier

import { Node, NumberLiteralData, StringLiteralData, BooleanLiteralData, IdentifierData, BigIntLiteralData, RegexLiteralData } from "../../../ast/node";
import { FormatOptions } from "../options";
import { Doc, docText } from "../doc";

export function printNumberLiteral(node: Node): Doc {
	const d = node.data as NumberLiteralData;
	return docText(d.value.toString());
}

// Re-escape string content for emission. The lexer unescapes \n, \t, \r, \\, \", \'.
// We must reverse that to produce valid source.
function escapeString(s: string, quote: number): string {
	let out = "";
	// Plain bytes are copied in runs, not one at a time. Escape-relevant bytes
	// are all ASCII, so runs break on character boundaries and multi-byte
	// UTF-8 sequences are never split.
	let runStart = 0;
	let i = 0;
	while (i < s.byteLength) {
		const ch = s.byteAt(i);
		const isEsc = ch === "\\".code || ch === "\n".code || ch === "\t".code || ch === "\r".code
			|| (ch === "\"".code && quote === "\"".code) || (ch === "'".code && quote === "'".code);
		if (isEsc) {
			if (runStart < i) out = out + s.byteSlice(runStart, i);
			out = out + match (ch) {
				"\\".code => "\\\\",
				"\n".code => "\\n",
				"\t".code => "\\t",
				"\r".code => "\\r",
				"\"".code => "\\\"",
				_ => "\\'",
			};
			runStart = i + 1;
		}
		i = i + 1;
	}
	if (runStart < s.byteLength) out = out + s.byteSlice(runStart, s.byteLength);
	return out;
}

// Extract the raw string token from source text using node position.
// Prettier pattern: work from raw source, never re-escape parsed values.
// Returns the full token including quotes (e.g., `"hello \"world\""`), or "" if unavailable.
//
// Defensive: bails out for synthetic StringLiteral nodes whose position
// points INSIDE a backtick template literal — there, an embedded `'` or
// `"` is part of the content, not a token delimiter, and a naive scan
// would scoop up the rest of the source. Heuristic: a real string-token
// boundary is preceded by whitespace, punctuation, or start-of-file.
// If the preceding character is `}` (close of `${...}` interpolation) or
// `\`` itself, we're inside a template — fall through to re-escape.
function extractRawStringToken(source: string, line: int32, col: int32): string {
	if (source === "") return "";
	// Find the byte offset of the target line:col in source
	let currentLine = 1;
	let pos = 0;
	while (pos < source.byteLength && currentLine < line) {
		if (source.byteAt(pos) === "\n".code) currentLine = currentLine + 1;
		pos = pos + 1;
	}
	// pos is now at the start of the target line; advance by column (0-based)
	pos = pos + col;
	if (pos >= source.byteLength) return "";
	// Expect a quote character at this position
	const quote = source.byteAt(pos);
	if (quote !== "\"".code && quote !== "'".code) return "";
	// Reject if the preceding char would mean we're inside a template
	// literal (between text/interpolation pieces in `\`...${x}'...\``).
	if (pos > 0) {
		const prev = source.byteAt(pos - 1);
		if (prev === "}".code || prev === "`".code) return "";
	}
	// Scan forward to find the matching closing quote (respecting escapes)
	let end = pos + 1;
	while (end < source.byteLength) {
		const ch = source.byteAt(end);
		if (ch === "\\".code) { end = end + 2; continue; } // skip escaped char
		if (ch === quote) { end = end + 1; break; }
		end = end + 1;
	}
	return source.byteSlice(pos, end);
}

export function printStringLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as StringLiteralData;
	let q = "\"";
	if (options.singleQuote) { q = "'"; }
	// Prettier pattern: extract raw token from source (preserves original escapes exactly).
	// Only works for real parsed nodes with valid source positions, not synthetic nodes.
	if (options.source !== "" && node.location.line > 0) {
		const raw = extractRawStringToken(options.source, node.location.line, node.location.column - 1);
		if (raw !== "") return docText(raw);
	}
	// Fall back to re-escaping (synthetic nodes from transforms, template desugaring)
	return docText(q + escapeString(d.value, q.byteAt(0)) + q);
}

export function printBooleanLiteral(node: Node): Doc {
	const d = node.data as BooleanLiteralData;
	if (d.boolValue) return docText("true");
	return docText("false");
}

export function printIdentifier(node: Node): Doc {
	const d = node.data as IdentifierData;
	return docText(d.name);
}

export function printBigIntLiteral(node: Node): Doc {
	const d = node.data as BigIntLiteralData;
	return docText(d.bigintValue);
}

export function printRegexLiteral(node: Node): Doc {
	const d = node.data as RegexLiteralData;
	return docText(d.regexPattern);
}
