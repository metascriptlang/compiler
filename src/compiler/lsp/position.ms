// LSP positions: a character counts UTF-16 code units, a checker column counts bytes from 1.
// A function taking a LineIndex serves a handler that converts many positions of one source;
// the one taking only the source builds the index for a single conversion.

import { LineIndex, lineStart, lineOf } from "../../utils/sourceLines";
import { SourceLocation, makeLoc } from "../../ast/node";

export interface LspPosition {
	line: int32;
	character: int32;
}

function clientLineText(lines: LineIndex, source: string, line: int32): string {
	const text = source.byteSlice(lines.lineStart(line), lines.lineStart(line + 1));
	const terminator = text.endsWith("\r\n") ? 2 : text.endsWith("\n") || text.endsWith("\r") ? 1 : 0;
	return text.byteSlice(0, text.byteLength - terminator);
}

export function lspByteColumnIn(lines: LineIndex, source: string, line: int32, character: int32): int32 {
	const text = clientLineText(lines, source, line);
	const unit = character < 0 ? 0 : character < text.length ? character : text.length;
	const previous = text.charCodeAt(unit - 1);
	const current = text.charCodeAt(unit);
	const inside = previous >= 0xD800 && previous <= 0xDBFF && current >= 0xDC00 && current <= 0xDFFF;
	return text.slice(0, inside ? unit - 1 : unit).byteLength + 1;
}

export function lspByteColumn(source: string, line: int32, character: int32): int32 {
	return lspByteColumnIn(LineIndex.buildLsp(source), source, line, character);
}

export function lspCharacterIn(lines: LineIndex, source: string, line: int32, column: int32): int32 {
	const text = clientLineText(lines, source, line);
	const end = column > 0 ? column - 1 : 0;
	return text.byteSlice(0, end < text.byteLength ? end : text.byteLength).length;
}

export function lspCharacter(source: string, line: int32, column: int32): int32 {
	return lspCharacterIn(LineIndex.buildLsp(source), source, line, column);
}

export function lspPositionAt(lines: LineIndex, source: string, offset: int32): LspPosition {
	const at = offset < 0 ? 0 : offset > source.byteLength ? source.byteLength : offset;
	const line = lines.lineOf(at);
	return { line: line - 1, character: lspCharacterIn(lines, source, line, at - lines.lineStart(line) + 1) };
}

export function lspPositionIn(lines: LineIndex, clientLines: LineIndex, source: string, line: int32, column: int32): LspPosition {
	return lspPositionAt(clientLines, source, lines.lineStart(line) + (column > 0 ? column - 1 : 0));
}

export function lspPosition(source: string, line: int32, column: int32): LspPosition {
	return lspPositionIn(LineIndex.build(source), LineIndex.buildLsp(source), source, line, column);
}

export function lspSourcePosition(source: string, line: int32, character: int32): SourceLocation {
	const clientLines = LineIndex.buildLsp(source);
	const offset = clientLines.lineStart(line) + lspByteColumnIn(clientLines, source, line, character) - 1;
	const lines = LineIndex.build(source);
	const compilerLine = lines.lineOf(offset);
	return makeLoc(compilerLine, offset - lines.lineStart(compilerLine) + 1);
}

test "compiler and LSP positions project through the same UTF-8 offset" {
	for (const separator of ["\n", "\r", "\r\n", "\u2028", "\u2029"]) {
		const source = "é😀" + separator + "target";
		const unicode = separator == "\u2028" || separator == "\u2029";
		const client = lspPosition(source, 2, 1);
		assert client.line == (unicode ? 0 : 1);
		assert client.character == (unicode ? 4 : 0);
		const compiler = lspSourcePosition(source, client.line + 1, client.character);
		assert compiler.line == 2 && compiler.column == 1;
	}
}
