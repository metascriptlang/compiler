// Literal Printers — number, string, boolean, identifier

import { Node, NumberLiteralData, StringLiteralData, BooleanLiteralData, IdentifierData, BigIntLiteralData, RegexLiteralData } from "../../../ast/node";
import { FormatOptions } from "../options";
import { Doc, docText } from "../doc";

export function printNumberLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as NumberLiteralData;
	const raw = rawNumberAt(node, options.source);
	return docText(raw != "" ? raw : d.value.toString());
}

function isDigitByte(ch: int32): boolean {
	return ch >= "0".code && ch <= "9".code;
}

function rawNumberAt(node: Node, source: string): string {
	const start = sourceOffset(source, node.location.line, node.location.column - 1);
	if (start < 0 || !isDigitByte(source.byteAt(start))) return "";
	const hex = source.byteAt(start) == "0".code && start + 1 < source.byteLength
		&& (source.byteAt(start + 1) == "x".code || source.byteAt(start + 1) == "X".code);
	let end = start;
	while (end < source.byteLength) {
		const ch = source.byteAt(end);
		const prev = end > start ? source.byteAt(end - 1) : 0;
		const exponentSign = !hex && (ch == "+".code || ch == "-".code) && (prev == "e".code || prev == "E".code);
		const fraction = ch == ".".code && end + 1 < source.byteLength && isDigitByte(source.byteAt(end + 1));
		if (!(isDigitByte(ch) || (ch >= "a".code && ch <= "z".code) || (ch >= "A".code && ch <= "Z".code)
			|| ch == "_".code || fraction || exponentSign)) break;
		end = end + 1;
	}
	return source.byteSlice(start, end);
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
		const isEsc = ch == "\\".code || ch == "\n".code || ch == "\t".code || ch == "\r".code
			|| (ch == "\"".code && quote == "\"".code) || (ch == "'".code && quote == "'".code);
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
	const pos = sourceOffset(source, line, col);
	if (pos < 0) return "";
	// Expect a quote character at this position
	const quote = source.byteAt(pos);
	if (quote != "\"".code && quote != "'".code) return "";
	// Reject if the preceding char would mean we're inside a template
	// literal (between text/interpolation pieces in `\`...${x}'...\``).
	if (pos > 0) {
		const prev = source.byteAt(pos - 1);
		if (prev == "}".code || prev == "`".code) return "";
	}
	// Scan forward to find the matching closing quote (respecting escapes)
	let end = pos + 1;
	while (end < source.byteLength) {
		const ch = source.byteAt(end);
		if (ch == "\\".code) { end = end + 2; continue; } // skip escaped char
		if (ch == quote) { end = end + 1; break; }
		end = end + 1;
	}
	return source.byteSlice(pos, end);
}

let lineStarts: int32[] = [];

export function indexSourceLines(source: string): void {
	lineStarts = [0];
	for (let i = 0; i < source.byteLength; i += 1) {
		if (source.byteAt(i) == "\n".code) lineStarts.push(i + 1);
	}
}

function sourceOffset(source: string, line: int32, col: int32): int32 {
	if (source == "" || line < 1 || line > lineStarts.length) return -1;
	const pos = lineStarts[line - 1] + col;
	return pos < source.byteLength ? pos : -1;
}

export function sourceSpan(source: string, line: int32, column: int32, endLine: int32, endColumn: int32): string {
	const start = sourceOffset(source, line, column - 1);
	let end = sourceOffset(source, endLine, endColumn - 1);
	if (end < 0) end = source.byteLength;
	return start < 0 || end < start ? "" : source.byteSlice(start, end);
}

export function sourceByteAt(source: string, line: int32, column: int32): int32 {
	const pos = sourceOffset(source, line, column - 1);
	return pos >= 0 ? source.byteAt(pos) : -1;
}

function skipQuoted(source: string, pos: int32): int32 {
	const quote = source.byteAt(pos);
	let end = pos + 1;
	while (end < source.byteLength) {
		const ch = source.byteAt(end);
		if (ch == "\\".code) { end = end + 2; continue; }
		end = end + 1;
		if (ch == quote) break;
	}
	return end;
}

function skipInterpolation(source: string, pos: int32): int32 {
	let depth = 1;
	let end = pos;
	while (end < source.byteLength) {
		const ch = source.byteAt(end);
		if (ch == "\"".code || ch == "'".code) { end = skipQuoted(source, end); continue; }
		if (ch == "`".code) { end = skipTemplate(source, end); continue; }
		if (ch == "{".code) depth = depth + 1;
		if (ch == "}".code) {
			depth = depth - 1;
			if (depth == 0) return end + 1;
		}
		end = end + 1;
	}
	return end;
}

function skipTemplate(source: string, pos: int32): int32 {
	let end = pos + 1;
	while (end < source.byteLength) {
		const ch = source.byteAt(end);
		if (ch == "\\".code) { end = end + 2; continue; }
		if (ch == "`".code) return end + 1;
		if (ch == "$".code && end + 1 < source.byteLength && source.byteAt(end + 1) == "{".code) {
			end = skipInterpolation(source, end + 2);
			continue;
		}
		end = end + 1;
	}
	return end;
}

function skipBlanks(source: string, from: int32): int32 {
	let pos = from;
	while (pos < source.byteLength && (source.byteAt(pos) == " ".code || source.byteAt(pos) == "\t".code)) pos = pos + 1;
	return pos;
}

export function writtenInitializer(source: string, line: int32, column: int32, name: string): string {
	const start = sourceOffset(source, line, column - 1);
	if (start < 0) return "";
	const eq = skipBlanks(source, start + name.byteLength);
	if (eq >= source.byteLength || source.byteAt(eq) != "=".code) return "";
	let end = eq + 1;
	let depth = 0;
	while (end < source.byteLength) {
		const ch = source.byteAt(end);
		if (ch == "\"".code || ch == "'".code) { end = skipQuoted(source, end); continue; }
		if (ch == "`".code) { end = skipTemplate(source, end); continue; }
		if (ch == "/".code && end + 1 < source.byteLength && (source.byteAt(end + 1) == "/".code || source.byteAt(end + 1) == "*".code)) break;
		if (ch == "(".code || ch == "[".code || ch == "{".code) depth = depth + 1;
		if (ch == ")".code || ch == "]".code || ch == "}".code) {
			if (depth == 0) break;
			depth = depth - 1;
		}
		if (depth == 0 && (ch == ",".code || ch == "\n".code || ch == "\r".code)) break;
		end = end + 1;
	}
	return source.byteSlice(eq + 1, end).trim();
}

export function writtenOptional(source: string, line: int32, column: int32, name: string): boolean {
	const start = sourceOffset(source, line, column - 1);
	if (start < 0) return false;
	const pos = skipBlanks(source, start + name.byteLength);
	return pos < source.byteLength && source.byteAt(pos) == "?".code;
}

export function writtenTypeAfterOptional(source: string, line: int32, column: int32, name: string, type: string): boolean {
	const start = sourceOffset(source, line, column - 1);
	if (start < 0) return false;
	let pos = skipBlanks(source, start + name.byteLength);
	if (pos >= source.byteLength || source.byteAt(pos) != "?".code) return false;
	pos = skipBlanks(source, pos + 1);
	if (pos >= source.byteLength || source.byteAt(pos) != ":".code) return false;
	pos = skipBlanks(source, pos + 1);
	return source.byteSlice(pos, pos + type.byteLength) == type;
}

export function rawObjectKeyAt(source: string, line: int32, column: int32): string {
	const pos = sourceOffset(source, line, column - 1);
	if (pos < 0) return "";
	const ch = source.byteAt(pos);
	if (ch == "\"".code || ch == "'".code) return source.byteSlice(pos, skipQuoted(source, pos));
	if (ch != "[".code) return "";
	let depth = 0;
	let end = pos;
	while (end < source.byteLength) {
		const c = source.byteAt(end);
		if (c == "\"".code || c == "'".code) { end = skipQuoted(source, end); continue; }
		if (c == "`".code) { end = skipTemplate(source, end); continue; }
		if (c == "[".code) depth = depth + 1;
		if (c == "]".code) {
			depth = depth - 1;
			if (depth == 0) return source.byteSlice(pos, end + 1);
		}
		end = end + 1;
	}
	return "";
}

export function rawTemplateAt(node: Node, options: FormatOptions): string {
	const pos = sourceOffset(options.source, node.location.line, node.location.column - 1);
	if (pos < 0 || options.source.byteAt(pos) != "`".code) return "";
	return options.source.byteSlice(pos, skipTemplate(options.source, pos));
}

export function printStringLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as StringLiteralData;
	const template = rawTemplateAt(node, options);
	if (template != "") return docText(template);
	let q = "\"";
	if (options.singleQuote) { q = "'"; }
	// Prettier pattern: extract raw token from source (preserves original escapes exactly).
	// Only works for real parsed nodes with valid source positions, not synthetic nodes.
	if (options.source != "" && node.location.line > 0) {
		const raw = extractRawStringToken(options.source, node.location.line, node.location.column - 1);
		if (raw != "") return docText(raw);
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
